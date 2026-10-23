//! The operations of `hands __serve` that the phone sends, and the command-line surfaces. Desktop control is in
//! desktop.rs, jobs in jobs.rs.

mod common;

use common::{HANDS, Serve, StateDir, alive, eventually};
use serde_json::json;
use std::fs;
use std::process::{Command, Stdio};

#[test]
fn answers_what_the_phone_sends() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    let hello = serve.ok(json!({ "op": "hello", "protocol": 1 }));
    assert_eq!(hello["os"], std::env::consts::OS);
    assert_eq!(hello["arch"], std::env::consts::ARCH);
    assert_eq!(hello["version"], env!("CARGO_PKG_VERSION"));
    assert!(hello["home"].as_str().is_some_and(|home| !home.is_empty()));
    let features: Vec<&str> = hello["features"]
        .as_array()
        .unwrap()
        .iter()
        .map(|feature| feature.as_str().unwrap())
        .collect();
    let mut expected = vec![
        "listFiles", "job.start", "job.status", "job.output", "job.wait", "job.cancel", "job.list",
    ];
    if cfg!(target_os = "macos") {
        expected.extend(["cua.tools", "cua.call"]);
    }
    assert_eq!(features, expected);
    assert_eq!(hello["cua"].is_object(), cfg!(target_os = "macos"));

    // write (creating parents), then open, pread and close, as the phone reads a file.
    let work = state.work();
    let file = work.join("new/dir/a.txt");
    let file = file.to_str().unwrap();
    let id = serve.send_payload(json!({ "op": "write", "path": file, "append": false }), b"hello");
    serve.reply(id).unwrap();
    let id = serve.send_payload(json!({ "op": "write", "path": file, "append": true }), b" world");
    serve.reply(id).unwrap();
    let opened = serve.ok(json!({ "op": "open", "path": file, "mode": "read" }));
    assert_eq!(opened["stat"]["kind"], "file");
    assert_eq!(opened["stat"]["size"], 11);
    let read = serve.request(json!({ "op": "pread", "handle": opened["handle"], "offset": 6, "length": 100 }));
    assert_eq!(read.unwrap().1, b"world");
    serve.ok(json!({ "op": "close", "handle": opened["handle"] }));
    let closed = serve.error(json!({ "op": "pread", "handle": opened["handle"], "offset": 0, "length": 1 }));
    assert_eq!(closed["code"], "EBADF");
    let missing = serve.error(json!({ "op": "open", "path": "/nonexistent/x", "mode": "read" }));
    assert_eq!(missing["code"], "ENOENT");

    let exec = serve.request(json!({
        "op": "exec",
        "command": "echo out; echo err >&2; exit 4",
        "cwd": work,
        "timeoutMs": 10_000,
    }));
    assert_eq!(exec.unwrap().0["exitCode"], 4);

    // What only pi-env sent is gone (decision 0019).
    for op in ["nope", "lstat", "writeChunk", "opendir", "scanLines", "watch", "pty"] {
        let unknown = serve.error(json!({ "op": op, "path": file }));
        assert_eq!(unknown["code"], "EINVAL", "{op}");
    }
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
fn version_and_usage() {
    let version = Command::new(HANDS).arg("version").output().unwrap();
    assert_eq!(
        String::from_utf8(version.stdout).unwrap(),
        format!("hands {}\n", env!("CARGO_PKG_VERSION"))
    );
    // No command, `serve` (the SSH transport that is gone) and unknown commands are usage errors.
    for args in [&[][..], &["serve"][..], &["serve", "--stdio"][..], &["frobnicate"][..]] {
        let output = Command::new(HANDS).args(args).stdin(Stdio::piped()).output().unwrap();
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
    }
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
            .env("PATH", "/usr/bin:/bin:/opt/marker/bin")
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
        // With the PATH of the shell install runs in.
        assert!(text.contains("/usr/bin:/bin:/opt/marker/bin"), "{text}");
        if args.contains(&"--pair") {
            assert!(text.contains("would start the listener if the service has not, and pair"), "{text}");
        }
    }
    assert!(!state.path.join("paired.json").exists());
    assert_eq!(fs::read_dir(&home).unwrap().count(), 0, "dry run wrote into HOME");
}
