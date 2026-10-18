//! Desktop control on macOS: `ui.observe`, `ui.act` and `ui.screenshot` (docs/desktop-protocol.md).
//!
//! A process started over SSH, or by the listener, cannot hold the Accessibility or Screen Recording permission, so
//! `hands` does not touch the desktop itself. It forwards these requests to the Mycroft Hands helper (desktop/),
//! which runs in the user's GUI session as the LaunchAgent `dev.mycroft.hands-desktop` and holds both permissions.
//! The helper listens on `desktop.sock` in the state dir (user-only), speaking newline-delimited JSON: one request
//! line `{ "id", "op", ...fields }`, one response line `{ "id", "ok": true, ...result }` or
//! `{ "id", "ok": false, "error": { "code", "message" } }`.
//!
//! - Each request opens its own connection, so concurrent requests never interleave on one socket. The helper
//!   serializes them itself.
//! - The helper's error codes (`not_trusted`, `not_permitted`, `stale`, `not_found`, `invalid`, `failed`) become the
//!   pi-env error frame's `code`, with its message.
//! - `ui.screenshot`'s base64 `png` becomes the raw payload of the result frame; the JSON keeps `width` and `height`.
//! - `not_supported` is `hands`' own: on Linux, or when no helper answers.
//! - `hello.features` lists the three ops only while the helper answers `ping`. The answer is cached for a few
//!   seconds.
//!
//! [`app`] installs the helper (`hands install --desktop-zip`) and asks for its permissions (`hands desktop`).

pub mod app;

use crate::errors::Failure;
use crate::exec::Control;
use crate::frame;
use crate::state;
use base64::Engine;
use serde_json::{Value, json};
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

/// The operations forwarded to the helper, in `hello.features` order.
pub const OPS: &[&str] = &["ui.observe", "ui.act", "ui.screenshot"];
const PING_TIMEOUT: Duration = Duration::from_millis(1500);
/// How long a `ping` answer (or its absence) is reused for `hello.features`.
const PING_CACHE: Duration = Duration::from_secs(3);
/// The longest a forwarded request may take. Acting waits ~250 ms for the screen to settle; capture is ~1 s.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
/// Reads are sliced, so a cancelled request stops waiting at once.
const READ_SLICE: Duration = Duration::from_millis(200);
/// The largest response line accepted: a screenshot as large as a frame's payload, in base64, plus its JSON.
const MAX_LINE: usize = frame::MAX_PAYLOAD / 3 * 4 + 64 * 1024;

pub fn socket() -> PathBuf {
    state::dir().join("desktop.sock")
}

/// What the helper's `ping` reports.
#[derive(Clone, Debug, PartialEq)]
pub struct Helper {
    pub version: String,
    /// Accessibility is granted.
    pub trusted: bool,
    pub screen_recording: bool,
}

/// Ask the helper now. `None` on Linux or when nothing answers.
pub fn ping() -> Option<Helper> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let reply = call(&socket(), &json!({ "id": 0, "op": "ping" }), PING_TIMEOUT, None).ok()?;
    Some(Helper {
        version: reply["version"].as_str().unwrap_or("?").to_string(),
        trusted: reply["trusted"].as_bool()?,
        // Helpers before 0.2.0 do not report it, and cannot take screenshots.
        screen_recording: reply["screenRecording"].as_bool().unwrap_or(false),
    })
}

/// [`ping`], cached for [`PING_CACHE`].
pub fn helper() -> Option<Helper> {
    static CACHE: Mutex<Option<(Instant, Option<Helper>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some((at, helper)) = cache.as_ref()
        && at.elapsed() < PING_CACHE
    {
        return helper.clone();
    }
    let helper = ping();
    *cache = Some((Instant::now(), helper.clone()));
    helper
}

/// Forward one `ui.*` request. The result is `(json, payload)`, as for every pi-env operation.
pub fn dispatch(op: &str, json: &Value, control: &Control) -> Result<(Value, Vec<u8>), Failure> {
    if !cfg!(target_os = "macos") {
        return Err(Failure::new(
            "not_supported",
            format!("{op} needs macOS; desktop control is not available on {}", std::env::consts::OS),
        ));
    }
    let mut request = match json {
        Value::Object(fields) => fields.clone(),
        _ => Default::default(),
    };
    request.insert("id".into(), json!(1));
    request.insert("op".into(), json!(op));
    let mut result = call(&socket(), &Value::Object(request), REQUEST_TIMEOUT, Some(control))?;
    if op != "ui.screenshot" {
        return Ok((result, Vec::new()));
    }
    let png = match result.as_object_mut().and_then(|fields| fields.remove("png")) {
        Some(Value::String(png)) => base64::engine::general_purpose::STANDARD
            .decode(png)
            .map_err(|error| Failure::new("failed", format!("the helper sent an invalid PNG: {error}")))?,
        _ => return Err(Failure::new("failed", "the helper's screenshot has no `png`")),
    };
    if png.len() > frame::MAX_PAYLOAD {
        return Err(Failure::new(
            "failed",
            format!("the screenshot is {} bytes, more than a frame carries; ask for a smaller maxWidth", png.len()),
        ));
    }
    Ok((result, png))
}

fn unavailable(socket: &Path, error: &io::Error) -> Failure {
    Failure::new(
        "not_supported",
        format!(
            "no desktop helper answers on {} ({error}). Install Mycroft Hands with `hands install --desktop-zip \
             MycroftHands.zip`; it runs in the logged-in GUI session",
            socket.display()
        ),
    )
}

/// One request line to the helper at `socket` and its response, as `Ok(result fields)` or the helper's error.
fn call(socket: &Path, request: &Value, timeout: Duration, control: Option<&Control>) -> Result<Value, Failure> {
    let deadline = Instant::now() + timeout;
    let mut stream = UnixStream::connect(socket).map_err(|error| unavailable(socket, &error))?;
    let broken = |error: io::Error| Failure::new("failed", format!("the desktop helper connection failed: {error}"));
    let mut line = serde_json::to_vec(request).map_err(|error| Failure::new("EINVAL", error.to_string()))?;
    line.push(b'\n');
    stream.set_write_timeout(Some(timeout)).map_err(broken)?;
    stream.write_all(&line).map_err(broken)?;
    stream.set_read_timeout(Some(READ_SLICE)).map_err(broken)?;
    let mut response = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    let end = loop {
        if let Some(control) = control
            && (control.aborted.load(Ordering::SeqCst) || control.killed.load(Ordering::SeqCst))
        {
            return Err(Failure::new("aborted", "aborted"));
        }
        match stream.read(&mut chunk) {
            Ok(0) => {
                return Err(Failure::new("failed", "the desktop helper closed the connection without answering"));
            }
            Ok(count) => {
                let start = response.len();
                response.extend_from_slice(&chunk[..count]);
                if let Some(at) = response[start..].iter().position(|&byte| byte == b'\n') {
                    break start + at;
                }
                if response.len() > MAX_LINE {
                    return Err(Failure::new("failed", "the desktop helper's answer is too large"));
                }
            }
            Err(error) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(broken(error)),
        }
        if Instant::now() >= deadline {
            return Err(Failure::new(
                "failed",
                format!("the desktop helper did not answer within {} s", timeout.as_secs()),
            ));
        }
    };
    let mut reply: Value = serde_json::from_slice(&response[..end])
        .map_err(|error| Failure::new("failed", format!("the desktop helper sent invalid JSON: {error}")))?;
    let Some(fields) = reply.as_object_mut() else {
        return Err(Failure::new("failed", "the desktop helper's answer is not a JSON object"));
    };
    if fields.remove("ok") == Some(Value::Bool(true)) {
        fields.remove("id");
        return Ok(reply);
    }
    let error = &reply["error"];
    match (error["code"].as_str(), error["message"].as_str()) {
        (Some(code), message) if !code.is_empty() => Err(Failure::new(code, message.unwrap_or(code))),
        _ => Err(Failure::new("failed", format!("the desktop helper failed: {reply}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixListener;
    use std::thread;

    /// A helper that answers each connection's first line with `reply(request)`.
    fn fake(reply: impl Fn(Value) -> String + Send + 'static) -> PathBuf {
        let path = std::env::temp_dir().join(format!("hands-ui-{}-{:?}.sock", std::process::id(), thread::current().id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut line = String::new();
                BufReader::new(&stream).read_line(&mut line).unwrap();
                let answer = reply(serde_json::from_str(&line).unwrap());
                let _ = (&stream).write_all(answer.as_bytes());
            }
        });
        path
    }

    #[test]
    fn maps_results_and_errors() {
        let path = fake(|request| match request["op"].as_str() {
            Some("ok") => format!("{{\"id\":{},\"ok\":true,\"a\":1}}\n", request["id"]),
            Some("err") => r#"{"id":1,"ok":false,"error":{"code":"stale","message":"old"}}"#.to_string() + "\n",
            Some("bad") => "not json\n".into(),
            _ => String::new(),
        });
        let timeout = Duration::from_secs(5);
        assert_eq!(call(&path, &json!({ "id": 1, "op": "ok" }), timeout, None).unwrap(), json!({ "a": 1 }));
        let error = call(&path, &json!({ "id": 1, "op": "err" }), timeout, None).unwrap_err();
        assert_eq!((error.code.as_str(), error.message.as_str()), ("stale", "old"));
        assert_eq!(call(&path, &json!({ "id": 1, "op": "bad" }), timeout, None).unwrap_err().code, "failed");
        assert_eq!(call(&path, &json!({ "id": 1, "op": "eof" }), timeout, None).unwrap_err().code, "failed");
        let _ = std::fs::remove_file(&path);
        assert_eq!(call(&path, &json!({}), timeout, None).unwrap_err().code, "not_supported");
    }

    #[test]
    fn a_cancelled_request_stops_waiting() {
        let path = fake(|_| {
            thread::sleep(Duration::from_secs(3));
            String::new()
        });
        let control = Control::default();
        control.aborted.store(true, Ordering::SeqCst);
        let started = Instant::now();
        let error = call(&path, &json!({ "id": 1, "op": "x" }), Duration::from_secs(10), Some(&control)).unwrap_err();
        assert_eq!(error.code, "aborted");
        assert!(started.elapsed() < Duration::from_secs(2));
        let _ = std::fs::remove_file(&path);
    }
}
