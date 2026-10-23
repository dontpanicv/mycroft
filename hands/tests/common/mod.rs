//! A minimal protocol client for the integration tests: it starts `hands __serve`, as the listener does for each
//! connection, with a temporary state dir (`HANDS_STATE_DIR`, never the real one) and speaks the framed protocol of
//! docs/protocol.md.

#![allow(dead_code)]

pub mod phone;

use serde_json::{Value, json};
use std::io::{BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

pub const HANDS: &str = env!("CARGO_BIN_EXE_hands");
const REQUEST: u8 = 1;
const RESULT: u8 = 2;
const ERROR: u8 = 3;
const CANCEL: u8 = 5;

pub fn write_frame(output: &mut impl Write, kind: u8, id: u32, json: &Value, payload: &[u8]) {
    let json = serde_json::to_vec(json).unwrap();
    let length = 9 + json.len() + payload.len();
    let mut frame = Vec::with_capacity(4 + length);
    frame.extend_from_slice(&(length as u32).to_be_bytes());
    frame.push(kind);
    frame.extend_from_slice(&id.to_be_bytes());
    frame.extend_from_slice(&(json.len() as u32).to_be_bytes());
    frame.extend_from_slice(&json);
    frame.extend_from_slice(payload);
    output.write_all(&frame).unwrap();
    output.flush().unwrap();
}

/// `(kind, id, json, payload)`, or `None` at the end of input.
pub fn read_frame(input: &mut impl Read) -> Option<(u8, u32, Value, Vec<u8>)> {
    let mut length = [0u8; 4];
    input.read_exact(&mut length).ok()?;
    let mut body = vec![0u8; u32::from_be_bytes(length) as usize];
    input.read_exact(&mut body).ok()?;
    let id = u32::from_be_bytes(body[1..5].try_into().unwrap());
    let json_length = u32::from_be_bytes(body[5..9].try_into().unwrap()) as usize;
    let json = serde_json::from_slice(&body[9..9 + json_length]).unwrap();
    Some((body[0], id, json, body[9 + json_length..].to_vec()))
}

/// A temporary state dir; dropping it cancels its jobs, stops its supervisor and listener, and deletes it.
pub struct StateDir {
    pub path: PathBuf,
}

impl StateDir {
    pub fn new() -> StateDir {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        // Short, under /tmp: a Unix socket path must stay below 104 bytes on macOS.
        let path = PathBuf::from(format!(
            "/tmp/hands-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        StateDir { path }
    }

    /// A scratch directory for job files, outside the state dir.
    pub fn work(&self) -> PathBuf {
        let work = self.path.with_extension("work");
        std::fs::create_dir_all(&work).unwrap();
        work
    }

    /// One request straight to the supervisor's socket, as `serve` sends it.
    pub fn supervisor(&self, request: Value) -> Option<Value> {
        let mut stream = UnixStream::connect(self.path.join("supervisor.sock")).ok()?;
        write_frame(&mut stream, REQUEST, 1, &request, &[]);
        read_frame(&mut stream).map(|(_, _, json, _)| json)
    }

    pub fn hands(&self, args: &[&str]) -> std::process::Output {
        Command::new(HANDS)
            .args(args)
            .env("HANDS_STATE_DIR", &self.path)
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }
}

impl Drop for StateDir {
    fn drop(&mut self) {
        if let Some(list) = self.supervisor(json!({ "op": "job.list" })) {
            for job in list["jobs"].as_array().into_iter().flatten() {
                if job["state"] == "running" {
                    self.supervisor(json!({ "op": "job.cancel", "key": job["key"], "signal": "SIGKILL" }));
                }
            }
            self.supervisor(json!({ "op": "shutdown" }));
        }
        // A listener `hands pair` started detached outlives the test otherwise, when its supervisor was not up yet
        // to take the shutdown (a pairing that failed at once). Only while it still holds its lock: the pid may be
        // gone, and reused.
        if let Ok(lock) = std::fs::File::open(self.path.join("listener.lock")) {
            use std::os::fd::AsRawFd;
            let held = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0;
            let pid = std::fs::read_to_string(self.path.join("listener.lock")).ok();
            if let Some(pid) = pid.and_then(|pid| pid.trim().parse::<i32>().ok()).filter(|_| held) {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
        let _ = std::fs::remove_dir_all(&self.path);
        let _ = std::fs::remove_dir_all(self.path.with_extension("work"));
    }
}

/// A `hands __serve` process and its connection.
pub struct Serve {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: Option<BufReader<ChildStdout>>,
    next_id: u32,
}

impl Serve {
    pub fn start(state: &Path) -> Serve {
        let mut child = Command::new(HANDS)
            .arg("__serve")
            .env("HANDS_STATE_DIR", state)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let mut serve = Serve {
            child,
            stdin,
            stdout: Some(stdout),
            next_id: 1,
        };
        let hello = serve.ok(json!({ "op": "hello", "protocol": 1 }));
        assert_eq!(hello["protocol"], 1);
        serve
    }

    pub fn send(&mut self, json: Value) -> u32 {
        self.send_payload(json, &[])
    }

    pub fn send_payload(&mut self, json: Value, payload: &[u8]) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        write_frame(self.stdin.as_mut().unwrap(), REQUEST, id, &json, payload);
        id
    }

    pub fn cancel(&mut self, id: u32) {
        write_frame(self.stdin.as_mut().unwrap(), CANCEL, id, &json!({}), &[]);
    }

    /// The reply to request `id`, skipping pings and events.
    pub fn reply(&mut self, id: u32) -> Result<(Value, Vec<u8>), Value> {
        loop {
            let (kind, reply_id, json, payload) = read_frame(self.stdout.as_mut().unwrap()).expect("serve ended");
            if reply_id != id {
                continue;
            }
            match kind {
                RESULT => return Ok((json, payload)),
                ERROR => return Err(json),
                _ => {}
            }
        }
    }

    /// The replies to all of `ids`, in whatever order they arrive.
    pub fn replies(&mut self, ids: &[u32]) -> std::collections::HashMap<u32, Result<(Value, Vec<u8>), Value>> {
        let mut replies = std::collections::HashMap::new();
        while replies.len() < ids.len() {
            let (kind, id, json, payload) = read_frame(self.stdout.as_mut().unwrap()).expect("serve ended");
            if !ids.contains(&id) {
                continue;
            }
            match kind {
                RESULT => replies.insert(id, Ok((json, payload))),
                ERROR => replies.insert(id, Err(json)),
                _ => None,
            };
        }
        replies
    }

    pub fn request(&mut self, json: Value) -> Result<(Value, Vec<u8>), Value> {
        let id = self.send(json);
        self.reply(id)
    }

    pub fn ok(&mut self, json: Value) -> Value {
        let op = json["op"].clone();
        match self.request(json) {
            Ok((value, _)) => value,
            Err(error) => panic!("{op} failed: {error}"),
        }
    }

    pub fn error(&mut self, json: Value) -> Value {
        match self.request(json) {
            Ok((value, _)) => panic!("expected an error, got {value}"),
            Err(error) => error,
        }
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// End the connection as the listener does when the phone goes: stdin closes, and serve exits after killing
    /// what it ran. Its stdout must then end too: a supervisor or job holding it open would keep the listener's
    /// reader waiting.
    pub fn disconnect(mut self) {
        self.stdin.take();
        let deadline = Instant::now() + Duration::from_secs(10);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "serve did not exit");
            std::thread::sleep(Duration::from_millis(20));
        }
        let mut stdout = self.stdout.take().unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut rest = Vec::new();
            let _ = stdout.read_to_end(&mut rest);
            let _ = sender.send(());
        });
        receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("serve's stdout stayed open after it exited");
    }
}

impl Drop for Serve {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Wait until `check` holds, for up to ten seconds.
pub fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Whether a process exists (and is not a zombie we could still signal).
pub fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}
