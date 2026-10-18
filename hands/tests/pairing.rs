//! Pairing and the listener (docs/pairing.md), end to end: a fake phone's HTTPS pairing server, `hands pair`, and a
//! WebSocket client with the phone's key talking pi-env through the listener. Every test uses its own temporary
//! state dir and binds the listener to 127.0.0.1 only.

mod common;

use common::phone::{
    FakePhone, PhoneKey, Socket, authenticate, base64, closes, connect, hex, listener_identity, paired_reply, sha256,
};
use common::{HANDS, StateDir, eventually, read_frame, write_frame};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use tungstenite::Message;

const REQUEST: u8 = 1;
const RESULT: u8 = 2;
const ERROR: u8 = 3;

fn auth_message(cert_sha256: &str, nonce: &str) -> String {
    format!("mycroft-auth:{cert_sha256}:{nonce}")
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Send a pi-env request as one binary message and wait for its result or error, checking that every binary
/// message carries exactly one frame.
fn call(socket: &mut Socket, id: u32, request: Value) -> Result<(Value, Vec<u8>), Value> {
    let mut frame = Vec::new();
    write_frame(&mut frame, REQUEST, id, &request, &[]);
    socket.send(Message::binary(frame)).unwrap();
    loop {
        let Message::Binary(message) = socket.read().unwrap() else { continue };
        let length = u32::from_be_bytes(message[..4].try_into().unwrap()) as usize;
        assert_eq!(length, message.len() - 4, "one frame per binary message");
        let (kind, reply_id, json, payload) = read_frame(&mut &message[..]).unwrap();
        match (kind, reply_id == id) {
            (RESULT, true) => return Ok((json, payload)),
            (ERROR, true) => return Err(json),
            _ => {}
        }
    }
}

fn ok(socket: &mut Socket, id: u32, request: Value) -> Value {
    call(socket, id, request).unwrap_or_else(|error| panic!("request {id} failed: {error}")).0
}

fn pair(state: &StateDir, base: &str, pin: &str) -> std::process::Output {
    Command::new(HANDS)
        .args(["pair", "--with", base, "--pin", pin, "--bind", "127.0.0.1"])
        .env("HANDS_STATE_DIR", &state.path)
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[test]
fn pair_then_authenticate_and_use_pi_env_through_the_listener() {
    let state = StateDir::new();
    let key = PhoneKey::from_seed(7);
    let reply = paired_reply("Test iPhone", &key);
    let phone = FakePhone::start(move |request| match (request.method.as_str(), request.path.as_str()) {
        ("POST", "/abcd2345/pair") => reply.clone(),
        _ => (404, "text/plain", b"not found".to_vec()),
    });

    let output = pair(&state, &phone.base("abcd2345"), &phone.pin);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "pair failed: {stderr}");
    let kind = if cfg!(target_os = "macos") { "Mac" } else { "machine" };
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        format!("Paired with Test iPhone. Mycroft can use this {kind} now.\n")
    );

    // What the phone received.
    let received = phone.received();
    assert_eq!(received.len(), 1);
    let body: Value = serde_json::from_slice(&received[0].body).unwrap();
    let (port, cert_sha256) = listener_identity(&state.path);
    assert_eq!(body["port"], port);
    assert_eq!(body["certSha256"], cert_sha256);
    assert_eq!(body["os"], std::env::consts::OS);
    assert_eq!(body["arch"], std::env::consts::ARCH);
    assert_eq!(body["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(body["addresses"], json!(["127.0.0.1"]));
    assert!(!body["name"].as_str().unwrap().is_empty());
    assert!(!body["hostname"].as_str().unwrap().is_empty());

    // What hands stored.
    for file in ["paired.json", "listener-cert.pem", "listener-key.pem"] {
        assert_eq!(mode(&state.path.join(file)), 0o600, "{file}");
    }
    let paired: Value = serde_json::from_slice(&fs::read(state.path.join("paired.json")).unwrap()).unwrap();
    assert_eq!(paired.as_array().unwrap().len(), 1);
    assert_eq!(paired[0]["name"], "Test iPhone");
    assert_eq!(paired[0]["publicKey"], base64(&key.public()));
    assert!(paired[0]["pairedAt"].as_u64().unwrap() > 0);
    let listed = state.hands(&["paired", "--json"]);
    let listed: Value = serde_json::from_slice(&listed.stdout).unwrap();
    assert_eq!(listed["phones"][0]["name"], "Test iPhone");

    // The phone connects with its key.
    let mut socket = connect(port, &cert_sha256, "/v1").unwrap();
    assert_eq!(
        socket.get_ref().conn.protocol_version(),
        Some(rustls::ProtocolVersion::TLSv1_3)
    );
    let answer = authenticate(&mut socket, &key, |nonce| auth_message(&cert_sha256, nonce));
    assert_eq!(answer, json!({ "type": "ready" }));

    // pi-env through the listener.
    let hello = ok(&mut socket, 1, json!({ "op": "hello", "protocol": 1 }));
    assert_eq!(hello["protocol"], 1);
    assert_eq!(hello["version"], env!("CARGO_PKG_VERSION"));
    assert!(hello["features"].as_array().unwrap().contains(&json!("job.start")));
    let started = ok(
        &mut socket,
        2,
        json!({ "op": "job.start", "key": "ws-job", "command": "echo through the listener; sleep 0.2; exit 5" }),
    );
    assert_eq!(started["created"], true);
    let ended = ok(&mut socket, 3, json!({ "op": "job.wait", "key": "ws-job", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "exited");
    assert_eq!(ended["exitCode"], 5);
    let (output, bytes) = call(&mut socket, 4, json!({ "op": "job.output", "key": "ws-job" })).unwrap();
    assert_eq!(String::from_utf8(bytes).unwrap(), "through the listener\n");
    assert_eq!(output["eof"], true);
    // A payload bigger than one TLS record and the socket buffers, in both directions.
    let file = state.work().join("big.bin");
    let big: Vec<u8> = (0..3_000_000u32).map(|index| (index % 251) as u8).collect();
    let mut frame = Vec::new();
    write_frame(&mut frame, REQUEST, 5, &json!({ "op": "write", "path": file, "append": false }), &big);
    socket.send(Message::binary(frame)).unwrap();
    loop {
        let Message::Binary(message) = socket.read().unwrap() else { continue };
        let (kind, id, json, _) = read_frame(&mut &message[..]).unwrap();
        if id == 5 {
            assert_eq!(kind, RESULT, "{json}");
            break;
        }
    }
    assert_eq!(fs::read(&file).unwrap(), big);
    let opened = ok(&mut socket, 6, json!({ "op": "open", "path": file }));
    let read = json!({ "op": "pread", "handle": opened["handle"], "offset": 0, "length": big.len() });
    let (_, read) = call(&mut socket, 8, read).unwrap();
    assert!(read == big, "pread through the listener returned {} bytes", read.len());
    let missing = call(&mut socket, 7, json!({ "op": "lstat", "path": "/nonexistent/x" })).unwrap_err();
    assert_eq!(missing["code"], "ENOENT");
    socket.close(None).unwrap();

    // The job belongs to the supervisor, so a second connection sees it.
    let mut again = connect(port, &cert_sha256, "/v1").unwrap();
    assert_eq!(
        authenticate(&mut again, &key, |nonce| auth_message(&cert_sha256, nonce)),
        json!({ "type": "ready" })
    );
    ok(&mut again, 1, json!({ "op": "hello", "protocol": 1 }));
    let status = ok(&mut again, 2, json!({ "op": "job.status", "key": "ws-job" }));
    assert_eq!(status["exitCode"], 5);

    // Unpairing takes effect for the next connection.
    let unpaired = state.hands(&["unpair", "Test iPhone"]);
    assert!(unpaired.status.success());
    let mut refused = connect(port, &cert_sha256, "/v1").unwrap();
    let answer = authenticate(&mut refused, &key, |nonce| auth_message(&cert_sha256, nonce));
    assert_eq!(answer, json!({ "type": "error", "code": "unauthorized" }));
}

/// A `hands supervise --listen` for one test, with `paired` written first.
struct Listener {
    child: Child,
    port: u16,
    cert_sha256: String,
}

impl Listener {
    fn start(state: &StateDir, paired: &[(&str, &PhoneKey)]) -> Listener {
        let phones: Vec<Value> = paired
            .iter()
            .map(|(name, key)| json!({ "name": name, "publicKey": base64(&key.public()), "pairedAt": 1 }))
            .collect();
        fs::write(state.path.join("paired.json"), serde_json::to_vec(&phones).unwrap()).unwrap();
        let child = Command::new(HANDS)
            .args(["supervise", "--listen", "--bind", "127.0.0.1"])
            .env("HANDS_STATE_DIR", &state.path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        eventually("the listener", || {
            fs::read_to_string(state.path.join("listener.lock")).is_ok_and(|pid| pid.ends_with('\n'))
        });
        let (port, cert_sha256) = listener_identity(&state.path);
        Listener { child, port, cert_sha256 }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn a_wrong_signature_is_unauthorized() {
    let state = StateDir::new();
    let key = PhoneKey::from_seed(1);
    let listener = Listener::start(&state, &[("Phone", &key)]);
    let mut socket = connect(listener.port, &listener.cert_sha256, "/v1").unwrap();
    // Signed over another certificate hash: what a relaying man in the middle would get.
    let other = hex(&sha256(b"another certificate"));
    let answer = authenticate(&mut socket, &key, |nonce| auth_message(&other, nonce));
    assert_eq!(answer, json!({ "type": "error", "code": "unauthorized" }));
    assert!(closes(&mut socket));

    // Signed over a stale nonce.
    let mut socket = connect(listener.port, &listener.cert_sha256, "/v1").unwrap();
    let stale = base64(&[0u8; 32]);
    let answer = authenticate(&mut socket, &key, |_| auth_message(&listener.cert_sha256, &stale));
    assert_eq!(answer, json!({ "type": "error", "code": "unauthorized" }));
    assert!(closes(&mut socket));

    // The right signature still works.
    let mut socket = connect(listener.port, &listener.cert_sha256, "/v1").unwrap();
    let cert = listener.cert_sha256.clone();
    let answer = authenticate(&mut socket, &key, |nonce| auth_message(&cert, nonce));
    assert_eq!(answer, json!({ "type": "ready" }));
}

#[test]
fn an_unknown_key_is_unauthorized() {
    let state = StateDir::new();
    let (paired, stranger) = (PhoneKey::from_seed(1), PhoneKey::from_seed(2));
    let listener = Listener::start(&state, &[("Phone", &paired)]);
    let cert = listener.cert_sha256.clone();
    let mut socket = connect(listener.port, &cert, "/v1").unwrap();
    let answer = authenticate(&mut socket, &stranger, |nonce| auth_message(&cert, nonce));
    assert_eq!(answer, json!({ "type": "error", "code": "unauthorized" }));
    assert!(closes(&mut socket));

    // Nothing but auth is accepted before ready: a pi-env frame is refused too.
    let mut socket = connect(listener.port, &cert, "/v1").unwrap();
    let hello = common::phone::read_json(&mut socket);
    assert_eq!(hello["type"], "hello");
    assert_eq!(hello["version"], env!("CARGO_PKG_VERSION"));
    let mut frame = Vec::new();
    write_frame(&mut frame, REQUEST, 1, &json!({ "op": "hello", "protocol": 1 }), &[]);
    socket.send(Message::binary(frame)).unwrap();
    assert_eq!(
        common::phone::read_json(&mut socket),
        json!({ "type": "error", "code": "unauthorized" })
    );
    assert!(closes(&mut socket));

    // An unauthenticated peer cannot make the listener buffer much: a huge upgrade request is cut off.
    let mut tcp = std::net::TcpStream::connect(("127.0.0.1", listener.port)).unwrap();
    let config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(common::phone::AnyCert::new())
        .with_no_client_auth();
    let connection = rustls::ClientConnection::new(
        std::sync::Arc::new(config),
        rustls::pki_types::ServerName::try_from("hands").unwrap(),
    )
    .unwrap();
    let mut stream = rustls::StreamOwned::new(connection, &mut tcp);
    let header = format!("GET /v1 HTTP/1.1\r\nX-Padding: {}", "a".repeat(16 * 1024));
    let started = std::time::Instant::now();
    let mut sent = 0;
    while sent < 4 << 20 && stream.write_all(header.as_bytes()).is_ok() {
        sent += header.len();
    }
    assert!(sent < 4 << 20, "the listener kept reading an endless upgrade request");
    assert!(started.elapsed() < std::time::Duration::from_secs(9), "cut by the budget, not the 10 s limit");

    // Only /v1 upgrades.
    let refused = connect(listener.port, &cert, "/v2").err().expect("upgrade on /v2");
    match refused {
        tungstenite::Error::Http(response) => assert_eq!(response.status(), 404),
        other => panic!("expected HTTP 404, got {other}"),
    }
}

#[test]
fn a_wrong_pin_fails_pairing_without_sending_the_request() {
    let state = StateDir::new();
    let key = PhoneKey::from_seed(3);
    let reply = paired_reply("Phone", &key);
    let phone = FakePhone::start(move |_| reply.clone());
    let wrong = base64(&sha256(b"some other key"));
    let output = pair(&state, &phone.base("abcd2345"), &wrong);
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("does not match the pin"), "{stderr}");
    assert!(output.stdout.is_empty());
    assert!(phone.connections.load(std::sync::atomic::Ordering::SeqCst) >= 1, "hands never connected");
    assert_eq!(phone.bytes.load(std::sync::atomic::Ordering::SeqCst), 0, "request bytes reached the phone");
    assert!(phone.received().is_empty());
    assert!(!state.path.join("paired.json").exists());
}

#[test]
fn a_used_setup_id_fails_pairing() {
    let state = StateDir::new();
    let phone = FakePhone::start(|_| (410, "text/plain", b"gone".to_vec()));
    let output = pair(&state, &phone.base("abcd2345"), &phone.pin);
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("already used or has expired"), "{stderr}");
    assert!(!state.path.join("paired.json").exists());
}

/// The phone's install script, served and piped to each available shell. The binary is a stub that records its
/// arguments, so nothing is installed.
#[test]
fn phone_install_script_downloads_verifies_and_runs_hands() {
    if Command::new("curl").arg("--version").output().is_err() {
        eprintln!("skipped: no curl");
        return;
    }
    let state = StateDir::new();
    let work = state.work();
    let stub = b"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$STUB_OUT\"\necho \"Paired with Stub.\"\n".to_vec();
    let template = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/phone-install.sh")).unwrap();
    for (label, digest) in [("good", hex(&sha256(&stub))), ("tampered", hex(&sha256(b"other")))] {
        let script = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let served = (script.clone(), stub.clone());
        let phone = FakePhone::start(move |request| {
            match (request.method.as_str(), request.path.as_str()) {
                ("GET", "/s3tup234") => (200, "text/x-shellscript", served.0.lock().unwrap().clone().into_bytes()),
                ("GET", path) if path.starts_with("/s3tup234/hands-") => (200, "application/octet-stream", served.1.clone()),
                _ => (404, "text/plain", Vec::new()),
            }
        });
        let base = phone.base("s3tup234");
        let mut filled = template.replace("@BASE@", &base).replace("@PIN@", &phone.pin);
        for target in ["darwin_arm64", "darwin_x86_64", "linux_x86_64", "linux_aarch64"] {
            filled = filled.replace(&format!("@SHA256_{target}@"), &digest);
        }
        for placeholder in ["@BASE@", "@PIN@", "@SHA256_"] {
            assert!(!filled.contains(placeholder), "{placeholder} left in {filled}");
        }
        *script.lock().unwrap() = filled;
        for shell in ["/bin/sh", "/bin/dash", "/bin/zsh", "/bin/bash"] {
            if !Path::new(shell).exists() {
                continue;
            }
            let temporary = work.join(format!("tmp-{label}-{}", shell.replace('/', "")));
            fs::create_dir_all(&temporary).unwrap();
            let marker = work.join("args");
            let _ = fs::remove_file(&marker);
            let command = format!("curl -fsSLk --pinnedpubkey sha256//{} {base} | {shell}", phone.pin);
            let output = Command::new("/bin/sh")
                .args(["-c", &command])
                .env("TMPDIR", &temporary)
                .env("STUB_OUT", &marker)
                .stdin(Stdio::null())
                .output()
                .unwrap();
            let (stdout, stderr) = (
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
            );
            if label == "good" {
                assert!(output.status.success(), "{shell}: {stderr}");
                assert_eq!(stdout, "Paired with Stub.\n", "{shell}");
                assert_eq!(stderr, "", "{shell}");
                let args = fs::read_to_string(&marker).unwrap();
                assert_eq!(args, format!("install\n--pair\n{base}\n--pin\n{}\n", phone.pin), "{shell}");
            } else {
                assert!(!output.status.success(), "{shell} ran a tampered binary");
                assert!(stderr.contains("does not match its SHA-256"), "{shell}: {stderr}");
                assert!(!marker.exists(), "{shell} ran the stub");
            }
            assert_eq!(fs::read_dir(&temporary).unwrap().count(), 0, "{shell} left its temp dir");
        }
    }
}
