//! `cua.tools` and `cua.call` through `hands __serve`, which forwards them to the supervisor, against a fake supervisor
//! listening on `supervisor.sock` in a temporary state dir; and a real supervisor that launchd did not start, which
//! has no desktop. Nothing here touches the real desktop or Cua Driver.

mod common;

use common::{Serve, StateDir, read_frame, write_frame};
use serde_json::{Value, json};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const RESULT: u8 = 2;
const ERROR: u8 = 3;

/// A fake supervisor: one request frame per connection, answered by `reply` with `Ok(result)` or `Err(error)`, or
/// left unanswered with `None`.
struct FakeSupervisor {
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeSupervisor {
    fn start(state: &Path, reply: impl Fn(&Value) -> Option<Result<Value, Value>> + Send + Sync + 'static) -> Self {
        let listener = UnixListener::bind(state.join("supervisor.sock")).unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let (seen, reply) = (requests.clone(), Arc::new(reply));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let (seen, reply) = (seen.clone(), reply.clone());
                thread::spawn(move || {
                    let Some((_, id, request, _)) = read_frame(&mut stream) else { return };
                    seen.lock().unwrap().push(request.clone());
                    match reply(&request) {
                        Some(Ok(result)) => write_frame(&mut stream, RESULT, id, &result, &[]),
                        Some(Err(error)) => write_frame(&mut stream, ERROR, id, &error, &[]),
                        None => thread::sleep(Duration::from_secs(5)),
                    }
                });
            }
        });
        FakeSupervisor { requests }
    }

    fn requests(&self, op: &str) -> Vec<Value> {
        self.requests.lock().unwrap().iter().filter(|request| request["op"] == op).cloned().collect()
    }
}

fn tools() -> Value {
    json!({
        "version": "0.38.0",
        "instructions": "cua-driver: background GUI automation.",
        "tools": [{ "name": "click", "description": "Click.", "inputSchema": { "type": "object" },
                    "annotations": { "readOnlyHint": false } }],
    })
}

fn clicked() -> Value {
    json!({
        "content": [{ "type": "text", "text": "Clicked [11] AXButton \"New Note\"." }],
        "structuredContent": { "effect": "confirmed", "verified": true },
    })
}

#[test]
fn forwards_tools_and_calls_unchanged() {
    let state = StateDir::new();
    let supervisor = FakeSupervisor::start(&state.path, |request| {
        Some(match request["op"].as_str() {
            Some("cua.tools") => Ok(tools()),
            Some("cua.call") if request["name"] == "click" => Ok(clicked()),
            Some("cua.call") => Err(json!({ "code": "EINVAL", "message": "unknown tool nope" })),
            _ => Ok(json!({})),
        })
    });
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        for op in ["cua.tools", "cua.call"] {
            assert_eq!(serve.error(json!({ "op": op, "name": "click" }))["code"], "not_supported");
        }
        return;
    }
    assert_eq!(serve.ok(json!({ "op": "cua.tools" })), tools());

    let arguments = json!({ "element_token": "s0000002a:11", "pid": 501, "window_id": 7 });
    let result = serve.ok(json!({ "op": "cua.call", "name": "click", "arguments": arguments }));
    assert_eq!(result, clicked());
    let sent = &supervisor.requests("cua.call")[0];
    assert_eq!((&sent["name"], &sent["arguments"]), (&json!("click"), &arguments));
    // Started without the listener there is no paired phone: the session is `local`.
    assert_eq!(sent["client"], "local");
    assert!(sent["call"].as_str().is_some_and(|call| call.len() == 16), "{sent}");

    let error = serve.error(json!({ "op": "cua.call", "name": "nope" }));
    assert_eq!(error, json!({ "code": "EINVAL", "message": "unknown tool nope" }));
    assert_eq!(supervisor.requests("cua.call")[1]["arguments"], json!({}));
}

#[test]
fn a_cancelled_call_cancels_the_driver_call() {
    let state = StateDir::new();
    let supervisor = FakeSupervisor::start(&state.path, |request| match request["op"].as_str() {
        Some("cua.call") => None,
        _ => Some(Ok(json!({}))),
    });
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        return;
    }
    let id = serve.send(json!({ "op": "cua.call", "name": "run_steps", "arguments": { "steps": [] } }));
    common::eventually("the call reaches the supervisor", || !supervisor.requests("cua.call").is_empty());
    let started = Instant::now();
    serve.cancel(id);
    assert_eq!(serve.reply(id).unwrap_err()["code"], "aborted");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    let call = supervisor.requests("cua.call")[0]["call"].clone();
    common::eventually("the supervisor is told to cancel", || {
        supervisor.requests("cua.cancel").first().is_some_and(|cancel| cancel["call"] == call)
    });
}

#[test]
fn malformed_calls_stop_in_serve() {
    let state = StateDir::new();
    let supervisor = FakeSupervisor::start(&state.path, |_| Some(Ok(json!({}))));
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        return;
    }
    assert_eq!(serve.error(json!({ "op": "cua.call" }))["code"], "EINVAL");
    let error = serve.error(json!({ "op": "cua.call", "name": "click", "arguments": [1, 2] }));
    assert_eq!(error["code"], "EINVAL");
    assert!(supervisor.requests("cua.call").is_empty());
}

#[test]
fn a_supervisor_launchd_did_not_start_has_no_desktop() {
    let state = StateDir::new();
    // `serve` starts its own supervisor on demand; macOS would attribute the desktop permissions to the terminal.
    let mut serve = Serve::start(&state.path);
    let error = serve.error(json!({ "op": "cua.tools" }));
    let expected = if cfg!(target_os = "macos") { "not_service" } else { "not_supported" };
    assert_eq!(error["code"], expected, "{error}");
    if cfg!(target_os = "macos") {
        let hello = state.supervisor(json!({ "op": "hello" })).unwrap();
        assert!(hello["desktop"]["off"].as_str().is_some(), "{hello}");
        let doctor = String::from_utf8(state.hands(&["doctor"]).stdout).unwrap();
        assert!(doctor.lines().any(|line| line.starts_with("desktop") && line.contains("off:")), "{doctor}");
    }
}
