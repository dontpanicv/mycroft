//! `ui.observe`, `ui.act` and `ui.screenshot` through `hands serve`, against a fake desktop helper listening on
//! `desktop.sock` in a temporary state dir. Nothing here touches the real desktop, prompts, or the real helper.

mod common;

use base64::Engine;
use common::{Serve, StateDir};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const UI_OPS: [&str; 3] = ["ui.observe", "ui.act", "ui.screenshot"];

/// A fake helper: each connection gets its own thread, and every request line is answered by `reply`.
struct FakeHelper {
    requests: Arc<Mutex<Vec<Value>>>,
    connections: Arc<AtomicUsize>,
}

impl FakeHelper {
    fn start(state: &Path, reply: impl Fn(&Value) -> Option<String> + Send + Sync + 'static) -> FakeHelper {
        let listener = UnixListener::bind(state.join("desktop.sock")).unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let connections = Arc::new(AtomicUsize::new(0));
        let reply = Arc::new(reply);
        let (seen, count) = (requests.clone(), connections.clone());
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                count.fetch_add(1, Ordering::SeqCst);
                let (seen, reply) = (seen.clone(), reply.clone());
                thread::spawn(move || {
                    let mut reader = BufReader::new(&stream);
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        let request: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        seen.lock().unwrap().push(request.clone());
                        match reply(&request) {
                            Some(answer) => (&stream).write_all(format!("{answer}\n").as_bytes()).unwrap(),
                            None => return,
                        }
                    }
                });
            }
        });
        FakeHelper { requests, connections }
    }

    fn requests(&self, op: &str) -> Vec<Value> {
        self.requests.lock().unwrap().iter().filter(|request| request["op"] == op).cloned().collect()
    }
}

fn ok(id: &Value, fields: Value) -> String {
    let mut answer = json!({ "id": id, "ok": true });
    answer.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    answer.to_string()
}

fn error(id: &Value, code: &str, message: &str) -> String {
    json!({ "id": id, "ok": false, "error": { "code": code, "message": message } }).to_string()
}

fn ui_features(serve: &mut Serve) -> Vec<String> {
    let hello = serve.ok(json!({ "op": "hello", "protocol": 1 }));
    hello["features"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|feature| feature.as_str())
        .filter(|feature| feature.starts_with("ui."))
        .map(String::from)
        .collect()
}

/// A PNG-like payload with every byte value, so nothing assumes text.
fn png_bytes() -> Vec<u8> {
    let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    png.extend((0..300_000u32).map(|index| (index.wrapping_mul(2654435761) >> 13) as u8));
    png
}

fn fake_desktop(state: &Path) -> FakeHelper {
    let png = base64::engine::general_purpose::STANDARD.encode(png_bytes());
    FakeHelper::start(state, move |request| {
        let id = &request["id"];
        Some(match request["op"].as_str().unwrap() {
            "ping" => ok(id, json!({ "trusted": true, "screenRecording": true, "version": "9.9.9" })),
            "ui.observe" if request["app"] == "Nope" => error(id, "not_found", "No running app matches “Nope”."),
            "ui.observe" => ok(id, json!({
                "observation": "o-5",
                "application": "Notes",
                "bundleId": "com.apple.Notes",
                "window": null,
                "otherWindows": 0,
                "elements": [{ "ref": "e1", "index": 1, "role": "button", "label": "New Note", "value": null,
                               "place": "toolbar", "operations": ["press"] }],
                "available": { "apps": ["Notes"], "folders": [], "sites": [], "menus": [] },
                "secureInputActive": false,
            })),
            "ui.act" if request["observation"] != "o-5" => error(id, "stale", "Observation o-1 is outdated."),
            "ui.act" => ok(id, json!({ "result": "Pressed “New Note” in Notes", "screenChanged": true })),
            "ui.screenshot" if request["maxWidth"] == 1 => error(id, "not_permitted", "Grant Screen Recording."),
            "ui.screenshot" => ok(id, json!({ "png": png, "width": 1600, "height": 1000 })),
            other => error(id, "invalid", &format!("Unknown op {other}")),
        })
    })
}

#[test]
fn proxies_observe_act_and_screenshot_to_the_helper() {
    let state = StateDir::new();
    let helper = fake_desktop(&state.path);
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        assert!(ui_features(&mut serve).is_empty());
        for op in UI_OPS {
            assert_eq!(serve.error(json!({ "op": op }))["code"], "not_supported");
        }
        return;
    }
    assert_eq!(ui_features(&mut serve), UI_OPS);

    let observation = serve.ok(json!({ "op": "ui.observe", "app": "Notes", "maxElements": 20 }));
    assert_eq!(observation["observation"], "o-5");
    assert_eq!(observation["elements"][0]["label"], "New Note");
    assert_eq!(observation["window"], Value::Null);
    assert!(observation.get("id").is_none() && observation.get("ok").is_none(), "{observation}");
    let sent = &helper.requests("ui.observe")[0];
    assert_eq!((&sent["app"], &sent["maxElements"]), (&json!("Notes"), &json!(20)));
    assert!(sent["id"].is_number(), "{sent}");

    let act = json!({ "op": "ui.act", "observation": "o-5", "operation": "PRESS", "ref": "e1" });
    let result = serve.ok(act.clone());
    assert_eq!(result, json!({ "result": "Pressed “New Note” in Notes", "screenChanged": true }));
    let sent = &helper.requests("ui.act")[0];
    for field in ["observation", "operation", "ref"] {
        assert_eq!(sent[field], act[field], "{field}");
    }

    let (shot, payload) = serve.request(json!({ "op": "ui.screenshot", "display": "main", "maxWidth": 1600 })).unwrap();
    assert_eq!(shot, json!({ "width": 1600, "height": 1000 }));
    assert_eq!(payload, png_bytes());
    let sent = &helper.requests("ui.screenshot")[0];
    assert_eq!((&sent["display"], &sent["maxWidth"]), (&json!("main"), &json!(1600)));
}

#[test]
fn helper_errors_keep_their_codes() {
    let state = StateDir::new();
    let _helper = fake_desktop(&state.path);
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        return;
    }
    let stale = serve.error(json!({ "op": "ui.act", "observation": "o-1", "operation": "PRESS", "ref": "e1" }));
    assert_eq!(stale, json!({ "code": "stale", "message": "Observation o-1 is outdated." }));
    let missing = serve.error(json!({ "op": "ui.observe", "app": "Nope" }));
    assert_eq!(missing["code"], "not_found");
    let refused = serve.error(json!({ "op": "ui.screenshot", "maxWidth": 1 }));
    assert_eq!(refused, json!({ "code": "not_permitted", "message": "Grant Screen Recording." }));
}

#[test]
fn not_supported_without_a_helper() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    assert!(ui_features(&mut serve).is_empty());
    for op in UI_OPS {
        let error = serve.error(json!({ "op": op }));
        assert_eq!(error["code"], "not_supported", "{op}");
    }
    // A socket file nobody listens on: a helper that died.
    drop(UnixListener::bind(state.path.join("desktop.sock")).unwrap());
    let mut serve = Serve::start(&state.path);
    assert!(ui_features(&mut serve).is_empty());
    assert_eq!(serve.error(json!({ "op": "ui.observe" }))["code"], "not_supported");
}

#[test]
fn features_need_a_ping_answer() {
    let state = StateDir::new();
    // Accepts connections but never answers ping properly.
    let helper = FakeHelper::start(&state.path, |request| match request["op"].as_str() {
        Some("ping") => Some(error(&request["id"], "invalid", "no ping here")),
        _ => Some(ok(&request["id"], json!({ "result": "done", "screenChanged": false }))),
    });
    let mut serve = Serve::start(&state.path);
    assert!(ui_features(&mut serve).is_empty());
    if cfg!(target_os = "macos") {
        // Requests are still forwarded: features are a hint, and the helper decides.
        assert_eq!(serve.ok(json!({ "op": "ui.act", "operation": "OPEN_APP", "app": "Notes" }))["result"], "done");
        assert!(!helper.requests("ping").is_empty());
    }
}

#[test]
fn concurrent_requests_use_their_own_connections() {
    let state = StateDir::new();
    let helper = FakeHelper::start(&state.path, |request| {
        if request["op"] == "ui.act" {
            thread::sleep(Duration::from_millis(400));
        }
        let fields = json!({ "result": request["app"], "screenChanged": false, "trusted": true, "version": "1" });
        Some(ok(&request["id"], fields))
    });
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        return;
    }
    let before = helper.connections.load(Ordering::SeqCst);
    let started = Instant::now();
    let ids: Vec<(u32, String)> = (0..6)
        .map(|index| {
            let app = format!("App {index}");
            (serve.send(json!({ "op": "ui.act", "operation": "OPEN_APP", "app": app })), app)
        })
        .collect();
    let replies = serve.replies(&ids.iter().map(|(id, _)| *id).collect::<Vec<_>>());
    for (id, app) in &ids {
        let (result, _) = replies[id].as_ref().unwrap();
        assert_eq!(result["result"], app.as_str());
    }
    // Six 400 ms requests in parallel, not one after another.
    assert!(started.elapsed() < Duration::from_millis(2000), "{:?}", started.elapsed());
    assert_eq!(helper.connections.load(Ordering::SeqCst) - before, 6);
}

#[test]
fn a_helper_that_hangs_up_is_a_failure() {
    let state = StateDir::new();
    let _helper = FakeHelper::start(&state.path, |request| match request["op"].as_str() {
        Some("ping") => Some(ok(&request["id"], json!({ "trusted": false, "version": "0.1.0" }))),
        _ => None,
    });
    let mut serve = Serve::start(&state.path);
    if !cfg!(target_os = "macos") {
        return;
    }
    // A 0.1.0 helper (no screenRecording in its ping) still counts as reachable.
    assert_eq!(ui_features(&mut serve), UI_OPS);
    let error = serve.error(json!({ "op": "ui.observe" }));
    assert_eq!(error["code"], "failed");
    assert!(error["message"].as_str().unwrap().contains("closed the connection"), "{error}");
}

#[test]
fn desktop_permissions_reports_the_helper() {
    let state = StateDir::new();
    let none = state.hands(&["desktop", "permissions", "--json"]);
    if !cfg!(target_os = "macos") {
        assert_eq!(none.status.code(), Some(1));
        return;
    }
    assert_eq!(none.status.code(), Some(1));
    let report: Value = serde_json::from_slice(&none.stdout).unwrap();
    assert_eq!(report, json!({ "helper": false, "accessibility": null, "screenRecording": null }));

    let _helper = FakeHelper::start(&state.path, |request| {
        Some(ok(&request["id"], json!({ "trusted": true, "screenRecording": false, "version": "0.2.0" })))
    });
    let partial = state.hands(&["desktop", "permissions", "--json"]);
    assert_eq!(partial.status.code(), Some(1));
    let report: Value = serde_json::from_slice(&partial.stdout).unwrap();
    assert_eq!(
        report,
        json!({ "helper": true, "version": "0.2.0", "accessibility": true, "screenRecording": false })
    );
    let text = String::from_utf8(state.hands(&["desktop", "permissions"]).stdout).unwrap();
    assert!(text.contains("accessibility:     granted\nscreen recording:  NOT granted\n"), "{text}");
    assert_eq!(state.hands(&["desktop", "frobnicate"]).status.code(), Some(2));
}

/// A stub MycroftHands.zip (unsigned: a dry run only reads its version).
fn stub_zip(dir: &Path, version: &str) -> std::path::PathBuf {
    let app = dir.join("stub/Mycroft Hands.app/Contents");
    std::fs::create_dir_all(&app).unwrap();
    std::fs::write(
        app.join("Info.plist"),
        format!(
            "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.mycroft.hands-desktop</string>\
             <key>CFBundleShortVersionString</key><string>{version}</string></dict></plist>"
        ),
    )
    .unwrap();
    let zip = dir.join("MycroftHands.zip");
    let status = std::process::Command::new("ditto")
        .args(["-c", "-k", "--keepParent"])
        .arg(app.parent().unwrap())
        .arg(&zip)
        .status()
        .unwrap();
    assert!(status.success());
    zip
}

#[test]
fn install_dry_run_with_the_desktop_helper() {
    if !cfg!(target_os = "macos") {
        return;
    }
    let state = StateDir::new();
    let work = state.work();
    let home = work.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let zip = stub_zip(&work, "0.9.1");
    let dry_run = |binary: &Path, args: &[&str]| {
        let output = std::process::Command::new(binary)
            .args(args)
            .env("HOME", &home)
            .env("HANDS_STATE_DIR", &state.path)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(output.status.success(), "{text}{}", String::from_utf8_lossy(&output.stderr));
        assert!(text.lines().all(|line| line.starts_with("would ") || line.starts_with("    | ")), "{text}");
        text
    };
    let hands = Path::new(common::HANDS);

    let text = dry_run(hands, &["install", "--dry-run", "--desktop-zip", zip.to_str().unwrap()]);
    let app = home.join("Applications/Mycroft Hands.app");
    assert!(text.contains(&format!("would install Mycroft Hands.app 0.9.1 from {}", zip.canonicalize().unwrap().display())), "{text}");
    assert!(text.contains(&format!("to {} (installed: none;", app.display())), "{text}");
    assert!(text.contains("would write ") && text.contains("Library/LaunchAgents/dev.mycroft.hands-desktop.plist\n"), "{text}");
    assert!(text.contains(&format!("    | \t\t<string>{}/Contents/MacOS/hands-desktop</string>\n    | \t\t<string>serve</string>", app.display())), "{text}");
    assert!(text.contains(&format!("<key>HANDS_STATE_DIR</key>\n    | \t\t<string>{}</string>", state.path.display())), "{text}");
    assert!(text.contains("dev.mycroft.hands-desktop.plist\nwould ask for Accessibility and Screen Recording"), "{text}");
    assert!(text.contains("--args --request-permissions --wait 600"), "{text}");

    // MycroftHands.zip next to the binary is picked up without --desktop-zip.
    let bin = work.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::copy(hands, bin.join("hands")).unwrap();
    std::fs::copy(&zip, bin.join("MycroftHands.zip")).unwrap();
    assert!(dry_run(&bin.join("hands"), &["install", "--dry-run"]).contains("would install Mycroft Hands.app 0.9.1"));
    assert!(!dry_run(hands, &["install", "--dry-run"]).contains("Mycroft Hands"));

    let uninstall = dry_run(hands, &["install", "--dry-run", "--uninstall"]);
    assert!(uninstall.contains("would run launchctl bootout gui/"), "{uninstall}");
    assert!(uninstall.contains(&format!("would remove {}\n", app.display())), "{uninstall}");
    assert!(uninstall.contains("dev.mycroft.hands-desktop.plist\n"), "{uninstall}");

    let missing = state.hands(&["install", "--dry-run", "--desktop-zip", "/nonexistent/MycroftHands.zip"]);
    assert_eq!(missing.status.code(), Some(2));
    assert_eq!(std::fs::read_dir(&home).unwrap().count(), 0, "dry run wrote into HOME");
}
