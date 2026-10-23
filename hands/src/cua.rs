//! Desktop control on macOS: Cua Driver (github.com/trycua/cua, MIT), linked in. `cua.tools` and `cua.call` carry
//! Cua's own MCP tool list and tool results unchanged (docs/jobs.md), so Mycroft offers Cua's tools as Cua describes
//! them.
//!
//! macOS grants Accessibility and Screen Recording to the responsible process. Started by launchd, the supervisor is
//! its own (permissions.rs), so the driver runs there, created once at startup ([`start`]), and its agent cursor
//! takes the main thread's AppKit loop ([`run_main_loop`]). `serve`, one process per connection, forwards both
//! operations over the supervisor socket, as it does `job.*`.
//!
//! - One Cua session per client: the paired phone's name (`HANDS_PEER`, set by the listener), or `local`. It outlives
//!   the connection, so element tokens stay valid while the phone reconnects. Cua's runtime ends a session after five
//!   minutes without a call, for good: hands replaces it before then, under a new label, and retries a call Cua
//!   refused because its session had ended.
//! - Cua's perception model (`parse_visual_regions`) is not linked and Computer History is off, so their tools, and
//!   the instructions' sentence about history, are left out.
//! - A cancelled `cua.call` cancels the driver call (`cua.cancel`).

use crate::errors::Failure;
use crate::exec::Control;
use crate::{supervisor, tls};
use serde_json::{Value, json};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

/// How often a forwarded call checks for a cancel.
const CANCEL_SLICE: Duration = Duration::from_millis(200);

/// The linked driver's release, for `hello`.
pub fn version() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        cua_driver_core::protocol::initialize_result()["serverInfo"]["version"].as_str().map(String::from)
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// The supervisor's desktop control for its `hello`: `{ version }` while Cua Driver runs, `{ off: why }` otherwise.
pub fn status() -> Value {
    #[cfg(target_os = "macos")]
    {
        match host::get() {
            Ok(_) => json!({ "version": version() }),
            Err(failure) => json!({ "off": failure.message }),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        json!({ "off": "desktop control needs macOS" })
    }
}

/// `hands doctor`'s line, from the running supervisor.
pub fn describe() -> String {
    if !cfg!(target_os = "macos") {
        return "not supported on this OS (cua.* answer not_supported)".into();
    }
    match supervisor::call_running(&json!({ "op": "hello" })) {
        Ok((hello, _)) => match (hello["desktop"]["version"].as_str(), hello["desktop"]["off"].as_str()) {
            (Some(version), _) => format!("Cua Driver {version}, in the supervisor"),
            (None, Some(why)) => format!("off: {why}"),
            _ => "unknown (the running supervisor is older; `hands install` restarts it)".into(),
        },
        Err(_) => "off: the supervisor isn't running (the service runs it)".into(),
    }
}

/// The client a `serve` process acts for.
fn client() -> String {
    std::env::var("HANDS_PEER").ok().filter(|peer| !peer.is_empty()).unwrap_or_else(|| "local".into())
}

/// `serve`'s side: forward one `cua.*` request to the supervisor.
pub fn dispatch(op: &str, json: &Value, control: &Control) -> Result<(Value, Vec<u8>), Failure> {
    if !cfg!(target_os = "macos") {
        return Err(Failure::new(
            "not_supported",
            format!("{op} needs macOS; desktop control is not available on {}", std::env::consts::OS),
        ));
    }
    if op == "cua.tools" {
        return supervisor::call(&json!({ "op": "cua.tools" }));
    }
    let name = json["name"].as_str().ok_or_else(|| Failure::new("EINVAL", "missing field name"))?;
    let arguments = match &json["arguments"] {
        Value::Null => json!({}),
        Value::Object(fields) => Value::Object(fields.clone()),
        _ => return Err(Failure::new("EINVAL", "arguments must be an object")),
    };
    let call = tls::hex(&tls::random::<8>());
    let request = json!({ "op": "cua.call", "name": name, "arguments": arguments, "client": client(), "call": call });
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(supervisor::call(&request));
    });
    loop {
        match receiver.recv_timeout(CANCEL_SLICE) {
            Ok(reply) => return reply,
            Err(RecvTimeoutError::Timeout)
                if control.aborted.load(Ordering::SeqCst) || control.killed.load(Ordering::SeqCst) =>
            {
                let _ = supervisor::call_running(&json!({ "op": "cua.cancel", "call": call }));
                return Err(Failure::new("aborted", "aborted"));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Err(Failure::new("failed", "the supervisor call ended")),
        }
    }
}

/// The supervisor's side of `cua.tools`, `cua.call` and `cua.cancel`.
pub fn supervise(op: &str, json: &Value) -> Result<Value, Failure> {
    #[cfg(target_os = "macos")]
    {
        let host = host::get()?;
        match op {
            "cua.tools" => host.tools(),
            "cua.call" => host.call(json),
            _ => {
                host.cancel(json["call"].as_str().unwrap_or_default());
                Ok(json!({}))
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = json;
        Err(Failure::new("not_supported", format!("{op} needs macOS")))
    }
}

/// Create the driver in the supervisor launchd started. Returns whether its agent cursor needs [`run_main_loop`].
pub fn start() -> bool {
    #[cfg(target_os = "macos")]
    {
        host::start()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Run AppKit's loop for the agent cursor on this thread, the main one. Never returns.
pub fn run_main_loop() -> ! {
    #[cfg(target_os = "macos")]
    platform_macos::cursor::overlay::run_on_main_thread();
    #[allow(unreachable_code)]
    loop {
        thread::park();
    }
}

#[cfg(target_os = "macos")]
mod host {
    use crate::errors::Failure;
    use crate::permissions;
    use cua_driver_sdk::{
        CuaDriver, CuaDriverSession, DriverError, DriverHostOptions, SessionPermissionMode, TrustedSessionOptions,
    };
    use serde_json::{Value, json};
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    use tokio::task::AbortHandle;

    /// Cua ends a session after this long, or after [`SESSION_IDLE`] without a call; hands starts a new one a minute
    /// before either. The idle limit is the runtime's own (`CUA_DRIVER_RS_SESSION_IDLE_TTL_SECS`, default 300 s,
    /// checked every 30 s), whatever a session asks for.
    const SESSION_TTL: Duration = Duration::from_secs(24 * 60 * 60);
    const SESSION_IDLE: Duration = Duration::from_secs(5 * 60);
    const SESSION_MARGIN: Duration = Duration::from_secs(60);
    /// What Cua answers on a session that ended (idle) or was ended (`end_session`): the call was refused before it
    /// did anything.
    const ENDED: [&str; 2] = ["has ended; call start_session", "session authorization context has been revoked"];

    pub struct Host {
        runtime: tokio::runtime::Runtime,
        driver: Arc<CuaDriver>,
        sessions: Mutex<HashMap<String, Session>>,
        calls: Mutex<HashMap<String, AbortHandle>>,
        /// Numbers the sessions' labels: Cua never takes back a label it ended.
        started: AtomicU64,
    }

    struct Session {
        session: Arc<CuaDriverSession>,
        started: Instant,
        used: Instant,
    }

    static HOST: OnceLock<Result<Host, Failure>> = OnceLock::new();

    /// Whether hands offers a Cua tool: not those of the perception model, which isn't linked, nor of Computer
    /// History, which is off.
    pub fn offered(name: &str) -> bool {
        name != "parse_visual_regions" && !name.starts_with("history_")
    }

    /// Cua's MCP server instructions without the sentences about tools hands does not offer.
    pub fn instructions(text: &str) -> String {
        text.lines()
            .map(|line| {
                line.split_inclusive(". ")
                    .filter(|sentence| !sentence.contains("history_"))
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn start() -> bool {
        match HOST.get_or_init(create) {
            Ok(_) => true,
            Err(failure) => {
                eprintln!("hands: desktop control is off: {}", failure.message);
                false
            }
        }
    }

    pub fn get() -> Result<&'static Host, Failure> {
        match HOST.get() {
            Some(Ok(host)) => Ok(host),
            Some(Err(failure)) => Err(Failure::new(&failure.code, failure.message.clone())),
            None => Err(Failure::new(
                "not_service",
                "desktop control runs in the hands service, the process macOS lets use the screen; `hands install` \
                 sets it up",
            )),
        }
    }

    fn create() -> Result<Host, Failure> {
        if !permissions::in_service() {
            return Err(Failure::new("not_service", "this supervisor was not started by launchd"));
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("hands-cua")
            .enable_all()
            .build()
            .map_err(|error| Failure::new("unavailable", format!("starting the desktop runtime: {error}")))?;
        let context = runtime.enter();
        // As Cua's own service creates it; hands asks for the permissions itself (`hands permissions`).
        let driver = CuaDriver::try_create_service_for_host(DriverHostOptions {
            cursor: cursor_overlay::CursorConfig::default(),
            host_owns_permission_ux: true,
            host_bundle_id: Some(crate::install::LABEL.into()),
            claude_code_compatibility: false,
            prepare_desktop_environment: true,
            register_host_tools: None,
            authorization_host: None,
            activity_observer: None,
        })
        .map_err(|error| Failure::new("unavailable", format!("starting Cua Driver: {error}")))?;
        drop(context);
        Ok(Host {
            runtime,
            driver,
            sessions: Mutex::new(HashMap::new()),
            calls: Mutex::new(HashMap::new()),
            started: AtomicU64::new(0),
        })
    }

    impl Host {
        /// Cua's MCP tool list and server instructions, without the tools hands does not offer.
        pub fn tools(&self) -> Result<Value, Failure> {
            let listed = self.runtime.block_on(self.driver.list_tools_json()).map_err(failure)?;
            let listed: Value = serde_json::from_str(&listed)
                .map_err(|error| Failure::new("failed", format!("Cua's tool list is not JSON: {error}")))?;
            let tools: Vec<Value> = listed["tools"]
                .as_array()
                .or_else(|| listed.as_array())
                .into_iter()
                .flatten()
                .filter(|tool| tool["name"].as_str().is_some_and(offered))
                .cloned()
                .collect();
            let server = cua_driver_core::protocol::initialize_result();
            Ok(json!({
                "version": server["serverInfo"]["version"],
                "instructions": instructions(server["instructions"].as_str().unwrap_or_default()),
                "tools": tools,
            }))
        }

        /// One tool call in the client's session: Cua's MCP result (`content`, `structuredContent`, `isError`).
        pub fn call(&self, json: &Value) -> Result<Value, Failure> {
            let name = json["name"].as_str().unwrap_or_default().to_string();
            if !offered(&name) {
                return Err(Failure::new("EINVAL", format!("unknown tool {name}")));
            }
            let client = json["client"].as_str().unwrap_or("local");
            let call = json["call"].as_str().unwrap_or_default();
            let result = self.call_in(self.session(client)?, &name, &json["arguments"], call)?;
            if !ended(&result) {
                return Ok(result);
            }
            // Ended under hands (the Mac slept through the idle limit, say): a new session, and the call once more.
            self.sessions.lock().unwrap().remove(client);
            self.call_in(self.session(client)?, &name, &json["arguments"], call)
        }

        fn call_in(&self, session: Arc<CuaDriverSession>, name: &str, arguments: &Value, call: &str) -> Result<Value, Failure> {
            let (name, arguments) = (name.to_string(), arguments.to_string());
            let task = self.runtime.spawn(async move { session.call_tool(name, arguments).await });
            self.calls.lock().unwrap().insert(call.to_string(), task.abort_handle());
            let joined = self.runtime.block_on(task);
            self.calls.lock().unwrap().remove(call);
            let result = match joined {
                Ok(result) => result.map_err(failure)?,
                Err(error) if error.is_cancelled() => return Err(Failure::new("aborted", "aborted")),
                Err(error) => return Err(Failure::new("failed", format!("the desktop call failed: {error}"))),
            };
            serde_json::from_str(&result.raw_json)
                .map_err(|error| Failure::new("failed", format!("Cua's result is not JSON: {error}")))
        }

        pub fn cancel(&self, call: &str) {
            if let Some(task) = self.calls.lock().unwrap().remove(call) {
                task.abort();
            }
        }

        fn session(&self, client: &str) -> Result<Arc<CuaDriverSession>, Failure> {
            let mut sessions = self.sessions.lock().unwrap();
            let now = Instant::now();
            if let Some(entry) = sessions.get_mut(client) {
                let fresh = now.duration_since(entry.started) < SESSION_TTL - SESSION_MARGIN
                    && now.duration_since(entry.used) < SESSION_IDLE - SESSION_MARGIN;
                if fresh {
                    entry.used = now;
                    return Ok(entry.session.clone());
                }
                entry.session.close();
            }
            let _context = self.runtime.enter();
            let session = self
                .driver
                .create_trusted_session(TrustedSessionOptions {
                    public_session: format!("mycroft-{client}-{}", self.started.fetch_add(1, Ordering::Relaxed) + 1),
                    mode: SessionPermissionMode::Standard,
                    ttl_seconds: SESSION_TTL.as_secs(),
                    idle_ttl_seconds: SESSION_IDLE.as_secs(),
                    capability_manifest_path: None,
                    bounded_manifest_path: None,
                })
                .map_err(failure)?;
            sessions.insert(client.to_string(), Session { session: session.clone(), started: now, used: now });
            Ok(session)
        }
    }

    /// Whether Cua refused the call because its session had ended.
    pub fn ended(result: &Value) -> bool {
        result["isError"] == true
            && result["content"].as_array().into_iter().flatten().any(|block| {
                block["text"].as_str().is_some_and(|text| ENDED.iter().any(|marker| text.contains(marker)))
            })
    }

    /// A driver error as a protocol failure: Cua's own code for a refused tool call.
    fn failure(error: DriverError) -> Failure {
        let code = match &error {
            DriverError::InvalidArguments { .. } => "EINVAL",
            DriverError::Tool { error_code, .. } if !error_code.is_empty() => error_code,
            DriverError::ActionInterrupted { .. } => "interrupted",
            DriverError::Configuration { .. } | DriverError::Shutdown | DriverError::RuntimeAlreadyExists => {
                "unavailable"
            }
            _ => "failed",
        };
        Failure::new(code, error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    use host::{ended, instructions, offered};

    #[cfg(target_os = "macos")]
    #[test]
    fn knows_a_call_refused_on_an_ended_session() {
        let refused = json!({ "isError": true, "content": [{ "type": "text", "text":
            "session 'mycroft-iPhone-1' has ended; call start_session with session 'mycroft-iPhone-1' to start it again, \
             or use a new session label" }] });
        assert!(ended(&refused));
        let revoked = json!({ "isError": true, "content": [{ "type": "text", "text":
            "this session authorization context has been revoked" }] });
        assert!(ended(&revoked));
        let failed = json!({ "isError": true, "content": [{ "type": "text", "text": "element not found" }] });
        assert!(!ended(&failed));
        let mentioned = json!({ "content": [{ "type": "text", "text": "The note says: has ended; call start_session" }] });
        assert!(!ended(&mentioned));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn leaves_out_perception_and_history() {
        assert!(offered("get_window_state"));
        assert!(offered("run_steps"));
        assert!(!offered("parse_visual_regions"));
        assert!(!offered("history_status"));
        assert!(!offered("history_query"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn instructions_leave_out_history() {
        let text = "1. Read narrowly.\n\n`start_session` is optional. On continuation, call `history_status`; then `history_query`.\nGuides: `get_guide`.";
        assert_eq!(instructions(text), "1. Read narrowly.\n\n`start_session` is optional.\nGuides: `get_guide`.");
        let cua = cua_driver_core::protocol::initialize_result()["instructions"].as_str().unwrap().to_string();
        let kept = instructions(&cua);
        assert!(cua.contains("history_status") && !kept.contains("history_"), "{kept}");
        assert!(kept.contains("run_steps") && kept.contains("get_guide"), "{kept}");
    }

    #[test]
    fn calls_need_a_name_and_object_arguments() {
        if !cfg!(target_os = "macos") {
            let error = dispatch("cua.call", &json!({ "name": "click" }), &Control::default()).unwrap_err();
            assert_eq!(error.code, "not_supported");
            return;
        }
        let control = Control::default();
        assert_eq!(dispatch("cua.call", &json!({}), &control).unwrap_err().code, "EINVAL");
        let error = dispatch("cua.call", &json!({ "name": "click", "arguments": [1] }), &control).unwrap_err();
        assert_eq!(error.code, "EINVAL");
    }
}
