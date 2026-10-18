//! pi-env compatibility of `hands serve`, and the reserved and command-line surfaces.

mod common;

use common::{HANDS, Serve, StateDir, alive, eventually};
use serde_json::json;
use std::fs;
use std::process::{Command, Stdio};

#[test]
fn speaks_pi_env_protocol_1() {
    let state = StateDir::new();
    // Exactly what pi-env's `Connection` runs, without --stdio.
    let mut serve = Serve::start_with(&state.path, &["serve", "--token", "abc123"], "abc123");
    let hello = serve.ok(json!({ "op": "hello", "protocol": 1 }));
    assert_eq!(hello["os"], std::env::consts::OS);
    assert_eq!(hello["arch"], std::env::consts::ARCH);
    let features: Vec<&str> = hello["features"]
        .as_array()
        .unwrap()
        .iter()
        .map(|feature| feature.as_str().unwrap())
        .collect();
    for feature in [
        "listFiles", "job.start", "job.status", "job.output", "job.wait", "job.cancel", "job.list",
    ] {
        assert!(features.contains(&feature), "{feature} missing from {features:?}");
    }
    assert!(!features.contains(&"ui.observe"));

    let work = state.work();
    let file = work.join("a.txt");
    let file = file.to_str().unwrap();
    let id = serve.send_payload(json!({ "op": "write", "path": file, "append": false }), b"hello");
    serve.reply(id).unwrap();
    let info = serve.ok(json!({ "op": "lstat", "path": file }));
    assert_eq!(info["kind"], "file");
    assert_eq!(info["size"], 5);

    let exec = serve.request(json!({
        "op": "exec",
        "command": "echo out; echo err >&2; exit 4",
        "cwd": work,
        "env": {},
    }));
    assert_eq!(exec.unwrap().0["exitCode"], 4);
    let missing = serve.error(json!({ "op": "lstat", "path": "/nonexistent/x" }));
    assert_eq!(missing["code"], "ENOENT");
    let unknown = serve.error(json!({ "op": "nope" }));
    assert_eq!(unknown["code"], "EINVAL");
}

#[test]
fn exec_still_dies_with_the_connection() {
    let state = StateDir::new();
    let work = state.work();
    let mut serve = Serve::start(&state.path);
    serve.send(json!({
        "op": "exec",
        "command": "echo $$ > exec.pid; sleep 300",
        "cwd": work,
        "env": {},
    }));
    let pid_file = work.join("exec.pid");
    eventually("the exec pid", || {
        fs::read_to_string(&pid_file).is_ok_and(|text| text.ends_with('\n'))
    });
    let pid: i32 = fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    serve.disconnect();
    eventually("exec to die with its connection", || !alive(pid));
}

#[test]
fn ui_operations_are_reserved() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    for op in ["ui.observe", "ui.act"] {
        assert_eq!(serve.error(json!({ "op": op }))["code"], "not_supported");
    }
}

#[test]
fn serves_on_stdin_without_arguments() {
    let state = StateDir::new();
    let serve = Serve::start_with(&state.path, &[], "hands");
    serve.disconnect();
}

#[test]
fn version_and_usage() {
    let version = Command::new(HANDS).arg("version").output().unwrap();
    assert_eq!(
        String::from_utf8(version.stdout).unwrap(),
        format!("hands {}\n", env!("CARGO_PKG_VERSION"))
    );
    let unknown = Command::new(HANDS)
        .arg("frobnicate")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(unknown.status.code(), Some(2));
}

#[test]
fn install_dry_run_changes_nothing() {
    let state = StateDir::new();
    let home = state.work();
    let pin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    let pair = ["install", "--dry-run", "--pair", "https://127.0.0.1:9/abcd2345", "--pin", pin];
    for args in [&["install", "--dry-run"][..], &["install", "--dry-run", "--uninstall"][..], &pair[..]] {
        let output = Command::new(HANDS)
            .args(args)
            .env("HOME", &home)
            .env("HANDS_STATE_DIR", &state.path)
            .env_remove("XDG_CONFIG_HOME")
            .output()
            .unwrap();
        assert!(output.status.success());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.lines().all(|line| line.starts_with("would ") || line.starts_with("    | ")), "{text}");
        assert!(text.contains(".local/bin/hands"), "{text}");
        if args.contains(&"--uninstall") {
            continue;
        }
        // The service runs the listener.
        assert!(text.contains("supervise") && text.contains("--listen"), "{text}");
        if args.contains(&"--pair") {
            assert!(text.contains("would start the listener if the service has not, and pair"), "{text}");
        }
    }
    assert!(!state.path.join("paired.json").exists());
    assert_eq!(fs::read_dir(&home).unwrap().count(), 0, "dry run wrote into HOME");
}
