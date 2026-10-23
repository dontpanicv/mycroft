//! `hands supervise --listen`: the supervisor plus a WebSocket-over-TLS-1.3 listener for the phone (docs/pairing.md
//! §2). A connection authenticates with the phone's paired Ed25519 key (`hello`, `auth`, `ready`); after that every
//! binary message is one protocol frame (docs/protocol.md), proxied to and from a `hands __serve` child of its own, so
//! a crash in one connection's requests ends only that connection.
//!
//! One thread per connection, as everywhere else in hands. One listener runs per state dir: it holds
//! `listener.lock` and writes its pid there. Started by the service it waits for the lock; started detached (by
//! `hands pair`) it exits if another listener holds it.

use crate::frame::MAX_FRAME;
use crate::serve::VERSION;
use crate::{mdns, pairing, state, supervisor, tls};
use rustls::{ServerConnection, StreamOwned};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, sync_channel};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tungstenite::protocol::WebSocketConfig;
use tungstenite::protocol::frame::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket};

/// The handshake (TLS, upgrade, `auth`) must finish within this.
const HANDSHAKE: Duration = Duration::from_secs(10);
/// An authenticated connection that sends nothing for this long is closed.
const IDLE: Duration = Duration::from_secs(60);
/// Connections still in their handshake; more are refused.
const MAX_HANDSHAKING: usize = 32;
/// Frames read from `serve` and not yet handed to the WebSocket.
const QUEUED_FRAMES: usize = 16;

/// What a peer may send before it has authenticated: the upgrade request, `auth` and some slack.
const PRE_AUTH_BYTES: usize = 64 * 1024;

type Socket = WebSocket<Budget<StreamOwned<ServerConnection, TcpStream>>>;

/// A stream that reads at most `left` bytes, then fails; `None` is unlimited. Bounds what an unauthenticated peer
/// can make the listener buffer (the WebSocket upgrade itself has no size limit).
struct Budget<S> {
    inner: S,
    left: Option<usize>,
}

impl<S: Read> Read for Budget<S> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let Some(left) = self.left else {
            return self.inner.read(buffer);
        };
        if left == 0 {
            return Err(io::Error::other("too much data before auth"));
        }
        let limit = buffer.len().min(left);
        let count = self.inner.read(&mut buffer[..limit])?;
        self.left = Some(left - count);
        Ok(count)
    }
}

impl<S: Write> Write for Budget<S> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.inner.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// The listener's port and certificate, created on first use.
pub struct Identity {
    pub port: u16,
    pub cert: tls::Certificate,
}

/// Load or create the listener's port (`listener.json`) and certificate. Serialised by a lock, so `hands pair` and
/// a starting listener agree on them.
pub fn identity() -> io::Result<Identity> {
    let dir = state::ensure()?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join("listener-identity.lock"))?;
    state::lock(&lock, true)?;
    let cert = tls::certificate(&pairing::machine().name)?;
    let saved = fs::read(state::listener_json())
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value["port"].as_u64())
        .and_then(|port| u16::try_from(port).ok())
        .filter(|port| *port != 0);
    let port = match saved {
        Some(port) => port,
        None => {
            let port = free_port()?;
            let text = format!("{}\n", json!({ "port": port }));
            tls::write_private(&state::listener_json(), text.as_bytes())?;
            port
        }
    };
    Ok(Identity { port, cert })
}

/// Ports the listener picks from: below the ranges systems hand out for "any free port" and outgoing connections
/// (32768–60999 on Linux, 49152–65535 on macOS), so another program binding port 0 cannot get this one between the
/// check and the listener's bind, or while the listener restarts.
const PORTS: std::ops::Range<u16> = 20000..32768;

/// A random port from [`PORTS`] that is free now. Checked on loopback too: a socket bound to one address does not
/// stop a bind to the wildcard address, so that check alone would miss a port another listener holds on 127.0.0.1.
fn free_port() -> io::Result<u16> {
    for _ in 0..100 {
        let [high, low] = tls::random::<2>();
        let port = PORTS.start + u16::from_be_bytes([high, low]) % (PORTS.end - PORTS.start);
        let free = |address: Ipv4Addr| TcpListener::bind((address, port)).is_ok();
        if free(Ipv4Addr::UNSPECIFIED) && free(Ipv4Addr::LOCALHOST) {
            return Ok(port);
        }
    }
    Err(io::Error::other("no free port found"))
}

/// The pid of the running listener, if one holds `listener.lock` and has written its pid.
pub fn running() -> Option<u32> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state::listener_lock())
        .ok()?;
    if state::lock(&file, false).ok()? {
        return None;
    }
    fs::read_to_string(state::listener_lock())
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// Make sure a listener runs: wait up to `grace` for one (a service just started), then start
/// `binary supervise --listen --detached` and wait for it. Returns its pid.
pub fn ensure_running(binary: &Path, bind: Option<IpAddr>, grace: Duration) -> Result<u32, String> {
    let wait = |limit: Duration| {
        let deadline = Instant::now() + limit;
        loop {
            if let Some(pid) = running() {
                return Some(pid);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(50));
        }
    };
    if let Some(pid) = wait(grace) {
        return Ok(pid);
    }
    start_detached(binary, bind).map_err(|error| format!("starting the listener: {error}"))?;
    wait(Duration::from_secs(10)).ok_or_else(|| {
        format!(
            "the listener did not start; see {}",
            state::log().display()
        )
    })
}

fn start_detached(binary: &Path, bind: Option<IpAddr>) -> io::Result<()> {
    state::ensure()?;
    let log = OpenOptions::new().create(true).append(true).open(state::log())?;
    let mut command = Command::new(binary);
    command.args(["supervise", "--listen", "--detached"]);
    if let Some(bind) = bind {
        command.args(["--bind", &bind.to_string()]);
    }
    command
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log);
    // SAFETY: only async-signal-safe calls between fork and exec.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// Stop a running listener (SIGTERM, then SIGKILL), for `hands install`. Jobs keep running.
pub fn stop() -> Result<&'static str, String> {
    let Some(pid) = running() else {
        return Ok("none running");
    };
    let pid = pid as libc::pid_t;
    // SAFETY: plain signals to the pid the lock holder wrote; it holds the lock, so it is still that process.
    unsafe { libc::kill(pid, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_secs(3);
    while running() == Some(pid as u32) {
        if Instant::now() >= deadline {
            // SAFETY: as above.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            thread::sleep(Duration::from_millis(200));
            return match running() {
                Some(_) => Err("the listener did not exit".into()),
                None => Ok("killed"),
            };
        }
        thread::sleep(Duration::from_millis(50));
    }
    Ok("stopped")
}

struct Context {
    config: Arc<rustls::ServerConfig>,
    cert_sha256: String,
    name: String,
    handshaking: AtomicUsize,
}

/// `hands supervise --listen [--bind ADDR] [--detached]`.
pub fn run(bind: Option<IpAddr>, detached: bool) -> io::Result<()> {
    state::ensure()?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state::listener_lock())?;
    if !state::lock(&lock, !detached)? {
        // Another listener runs; it also keeps a supervisor running or waiting.
        return Ok(());
    }
    let identity = identity()?;
    let bind = bind.unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let socket = TcpListener::bind((bind, identity.port))
        .map_err(|error| io::Error::new(error.kind(), format!("listening on {bind}:{}: {error}", identity.port)))?;
    write_pid(&lock)?;
    let config = rustls::ServerConfig::builder_with_provider(tls::provider())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(io::Error::other)?
        .with_no_client_auth()
        .with_single_cert(vec![identity.cert.der.clone()], identity.cert.key.clone_key())
        .map_err(io::Error::other)?;
    let name = pairing::machine().name;
    eprintln!(
        "hands {VERSION}: listener {} on {bind}:{}, certificate sha256 {}",
        std::process::id(),
        identity.port,
        identity.cert.sha256
    );
    let _advertisement = mdns::advertise(&name, identity.port, &identity.cert.sha256, bind);
    let context = Arc::new(Context {
        config: Arc::new(config),
        cert_sha256: identity.cert.sha256.clone(),
        name,
        handshaking: AtomicUsize::new(0),
    });
    thread::spawn(move || {
        for stream in socket.incoming() {
            let Ok(stream) = stream else { continue };
            if context.handshaking.load(Ordering::SeqCst) >= MAX_HANDSHAKING {
                continue;
            }
            context.handshaking.fetch_add(1, Ordering::SeqCst);
            let context = context.clone();
            thread::spawn(move || connection(&context, stream));
        }
    });
    // The supervisor in the same process. Waits while another supervisor (one `serve` started) holds its lock;
    // `hands __serve` children reach whichever runs.
    let result = supervisor::run(false);
    drop(lock);
    result
}

fn write_pid(mut lock: &File) -> io::Result<()> {
    use std::io::Seek;
    lock.set_len(0)?;
    lock.seek(io::SeekFrom::Start(0))?;
    lock.write_all(format!("{}\n", std::process::id()).as_bytes())
}

fn send_json(socket: &mut Socket, value: Value) -> tungstenite::Result<()> {
    socket.send(Message::text(value.to_string()))
}

fn connection(context: &Context, tcp: TcpStream) {
    let peer = tcp
        .peer_addr()
        .map(|address| address.to_string())
        .unwrap_or_else(|_| "?".into());
    let authenticated = Arc::new(AtomicBool::new(false));
    // The handshake watchdog holds a duplicate of the socket, so dropping the stream alone would not close it.
    let closer = tcp.try_clone();
    let result = handshake(context, tcp, &authenticated);
    context.handshaking.fetch_sub(1, Ordering::SeqCst);
    match result {
        Ok((socket, phone)) => {
            eprintln!("hands: {peer} authenticated as {phone}");
            match proxy(socket, &phone) {
                Ok(()) => eprintln!("hands: {peer} ({phone}) disconnected"),
                Err(error) => eprintln!("hands: {peer} ({phone}) disconnected: {error}"),
            }
        }
        Err(error) => eprintln!("hands: {peer} refused: {error}"),
    }
    if let Ok(closer) = closer {
        let _ = closer.shutdown(Shutdown::Both);
    }
}

/// TLS, the WebSocket upgrade on `/v1`, `hello`, `auth`, `ready`: the authenticated socket and the phone's name.
fn handshake(
    context: &Context,
    tcp: TcpStream,
    authenticated: &Arc<AtomicBool>,
) -> Result<(Socket, String), String> {
    // A connection that has not authenticated within the limit is cut, however slowly it trickles bytes.
    if let Ok(watched) = tcp.try_clone() {
        let authenticated = authenticated.clone();
        thread::spawn(move || {
            thread::sleep(HANDSHAKE);
            if !authenticated.load(Ordering::SeqCst) {
                let _ = watched.shutdown(Shutdown::Both);
            }
        });
    }
    let text = |error: &dyn std::fmt::Display| error.to_string();
    tcp.set_read_timeout(Some(HANDSHAKE)).map_err(|e| text(&e))?;
    tcp.set_write_timeout(Some(HANDSHAKE)).map_err(|e| text(&e))?;
    let _ = tcp.set_nodelay(true);
    let mut connection = ServerConnection::new(context.config.clone()).map_err(|e| text(&e))?;
    // The WebSocket bounds what it buffers, and this proxy pulls frames from `serve` only when it is flushed.
    connection.set_buffer_limit(None);
    let stream = Budget {
        inner: StreamOwned::new(connection, tcp),
        left: Some(PRE_AUTH_BYTES),
    };
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME + 4))
        .max_frame_size(Some(MAX_FRAME + 4))
        .write_buffer_size(0);
    let check_path = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        if request.uri().path() == "/v1" {
            Ok(response)
        } else {
            let mut refusal = ErrorResponse::new(Some("not found".into()));
            *refusal.status_mut() = tungstenite::http::StatusCode::NOT_FOUND;
            Err(refusal)
        }
    };
    let mut socket = tungstenite::accept_hdr_with_config(stream, check_path, Some(config))
        .map_err(|error| format!("WebSocket upgrade: {error}"))?;
    let nonce = tls::base64(&tls::random::<32>());
    send_json(
        &mut socket,
        json!({ "type": "hello", "version": VERSION, "name": context.name, "nonce": nonce }),
    )
    .map_err(|e| text(&e))?;
    let verdict = loop {
        match socket.read() {
            Ok(Message::Text(message)) => break authenticate(context, &nonce, message.as_str()),
            Ok(Message::Ping(_) | Message::Pong(_)) => continue,
            Ok(_) => break Err("a message other than auth before ready".to_string()),
            Err(error) => return Err(format!("before auth: {error}")),
        }
    };
    match verdict {
        Ok(phone) => {
            authenticated.store(true, Ordering::SeqCst);
            socket.get_mut().left = None;
            send_json(&mut socket, json!({ "type": "ready" })).map_err(|e| text(&e))?;
            Ok((socket, phone))
        }
        Err(reason) => {
            let _ = send_json(&mut socket, json!({ "type": "error", "code": "unauthorized" }));
            let _ = socket.close(Some(CloseFrame {
                code: CloseCode::Policy,
                reason: "unauthorized".into(),
            }));
            // Give the close frame a moment to reach the peer; the watchdog bounds this.
            let deadline = Instant::now() + Duration::from_secs(1);
            let _ = socket.get_mut().inner.get_mut().set_read_timeout(Some(Duration::from_millis(200)));
            while Instant::now() < deadline && socket.read().is_ok() {}
            Err(format!("unauthorized: {reason}"))
        }
    }
}

/// Check an `auth` message; the name of the paired phone it proves to be.
fn authenticate(context: &Context, nonce: &str, text: &str) -> Result<String, String> {
    let message: Value = serde_json::from_str(text).map_err(|_| "auth is not JSON".to_string())?;
    if message["type"] != "auth" {
        return Err(format!("expected auth, got {}", message["type"]));
    }
    let public_key = message["publicKey"]
        .as_str()
        .and_then(tls::unbase64)
        .filter(|key| key.len() == 32)
        .ok_or("publicKey is not base64 of 32 bytes")?;
    let signature = message["signature"]
        .as_str()
        .and_then(tls::unbase64)
        .filter(|signature| signature.len() == 64)
        .ok_or("signature is not base64 of 64 bytes")?;
    let phone = pairing::phone_with_key(&public_key).ok_or("the key is not paired")?;
    let signed = tls::auth_message(&context.cert_sha256, nonce);
    if !tls::ed25519_verify(&public_key, signed.as_bytes(), &signature) {
        return Err(format!("bad signature for {phone}"));
    }
    Ok(phone)
}

/// Start `hands __serve` for this connection, naming the phone it serves (cua.rs keys its desktop session by it).
fn start_serve(phone: &str) -> io::Result<Child> {
    Command::new(std::env::current_exe()?)
        .arg("__serve")
        .env("HANDS_PEER", phone)
        .current_dir(crate::sys::home())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
}

/// Read `serve`'s stdout: pass each frame, with its length prefix, to `frames`, and nudge `wake`. Ends at the end
/// of its output or when the receiver is gone.
fn read_frames(stdout: impl Read, frames: std::sync::mpsc::SyncSender<Vec<u8>>, mut wake: UnixStream) {
    let mut stdout = BufReader::new(stdout);
    loop {
        let mut length = [0u8; 4];
        if stdout.read_exact(&mut length).is_err() {
            break;
        }
        let size = u32::from_be_bytes(length) as usize;
        if size > MAX_FRAME {
            break;
        }
        let mut frame = Vec::with_capacity(4 + size);
        frame.extend_from_slice(&length);
        frame.resize(4 + size, 0);
        if stdout.read_exact(&mut frame[4..]).is_err() || frames.send(frame).is_err() {
            break;
        }
        let _ = wake.write(&[1]);
    }
    // Dropping `frames` and `wake` tells the proxy that serve's output ended.
}

/// Proxy frames between the authenticated socket and a `serve` child until either side ends.
fn proxy(mut socket: Socket, phone: &str) -> Result<(), String> {
    let mut child = start_serve(phone).map_err(|error| format!("starting serve: {error}"))?;
    let stdin = child.stdin.take();
    let stdout = child.stdout.take().expect("piped stdout");
    let (wake_sender, mut wake) = UnixStream::pair().map_err(|error| error.to_string())?;
    let _ = wake_sender.set_nonblocking(true);
    let _ = wake.set_nonblocking(true);
    let (sender, frames) = sync_channel(QUEUED_FRAMES);
    let reader = thread::spawn(move || read_frames(stdout, sender, wake_sender));
    let result = pump(&mut socket, stdin, &frames, &mut wake);
    // Closing stdin (pump has dropped it) ends `serve`: it kills the commands it started, not jobs, and exits. Kill
    // it if it lingers.
    drop(frames);
    let deadline = Instant::now() + Duration::from_secs(3);
    while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = reader.join();
    result
}

fn would_block(error: &tungstenite::Error) -> bool {
    matches!(error, tungstenite::Error::Io(error) if error.kind() == io::ErrorKind::WouldBlock)
}

fn closed(error: &tungstenite::Error) -> bool {
    matches!(
        error,
        tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed
    )
}

/// The event loop of one connection: the socket is nonblocking, and `poll` waits for it or for `wake`.
fn pump(
    socket: &mut Socket,
    stdin: Option<ChildStdin>,
    frames: &Receiver<Vec<u8>>,
    wake: &mut UnixStream,
) -> Result<(), String> {
    let mut stdin = stdin.ok_or("serve has no stdin")?;
    let tcp = socket.get_ref().inner.get_ref();
    tcp.set_nonblocking(true).map_err(|error| error.to_string())?;
    let _ = tcp.set_read_timeout(None);
    let _ = tcp.set_write_timeout(None);
    let fd = tcp.as_raw_fd();
    let mut last_received = Instant::now();
    let mut pending = false;
    let mut serve_ended = false;
    let mut wake_open = true;
    loop {
        // Everything that arrived.
        loop {
            match socket.read() {
                Ok(Message::Binary(frame)) => {
                    last_received = Instant::now();
                    let valid = frame.len() >= 13
                        && u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize == frame.len() - 4;
                    if !valid {
                        let _ = socket.close(Some(CloseFrame {
                            code: CloseCode::Protocol,
                            reason: "one complete frame per binary message".into(),
                        }));
                        let _ = socket.flush();
                        return Err("a binary message that is not one frame".into());
                    }
                    stdin
                        .write_all(&frame)
                        .map_err(|error| format!("writing to serve: {error}"))?;
                }
                Ok(Message::Close(_)) => {
                    let _ = socket.flush();
                    return Ok(());
                }
                Ok(_) => last_received = Instant::now(),
                Err(error) if would_block(&error) => break,
                Err(error) if closed(&error) => return Ok(()),
                Err(error) => return Err(error.to_string()),
            }
        }
        // Frames from serve, while the socket keeps up.
        if !pending {
            loop {
                match frames.try_recv() {
                    Ok(frame) => match socket.write(Message::binary(frame)) {
                        Ok(()) => {}
                        // Queued in the socket; the flush below finds it blocked too.
                        Err(error) if would_block(&error) => break,
                        Err(error) if closed(&error) => return Ok(()),
                        Err(error) => return Err(error.to_string()),
                    },
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        serve_ended = true;
                        break;
                    }
                }
            }
        }
        match socket.flush() {
            Ok(()) => pending = false,
            Err(error) if would_block(&error) => pending = true,
            Err(error) if closed(&error) => return Ok(()),
            Err(error) => return Err(error.to_string()),
        }
        if serve_ended && !pending {
            let _ = socket.close(None);
            let _ = socket.flush();
            return Err("serve exited".into());
        }
        let idle = IDLE.saturating_sub(last_received.elapsed());
        if idle.is_zero() {
            let _ = socket.close(Some(CloseFrame {
                code: CloseCode::Away,
                reason: "silent for 60 s".into(),
            }));
            let _ = socket.flush();
            return Err("silent for 60 s".into());
        }
        let wants_write = pending || socket.get_ref().inner.conn.wants_write();
        let mut fds = [
            libc::pollfd {
                fd,
                events: libc::POLLIN | if wants_write { libc::POLLOUT } else { 0 },
                revents: 0,
            },
            libc::pollfd {
                // poll skips negative descriptors: a closed wake socket would be ready forever.
                fd: if wake_open { wake.as_raw_fd() } else { -1 },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let timeout = idle.as_millis().min(i32::MAX as u128) as i32;
        // SAFETY: two valid pollfds for the duration of the call.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout.max(1)) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error.to_string());
            }
        }
        if fds[1].revents != 0 {
            let mut drain = [0u8; 256];
            loop {
                match wake.read(&mut drain) {
                    Ok(0) => {
                        wake_open = false;
                        break;
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        }
    }
}
