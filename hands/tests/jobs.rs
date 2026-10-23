//! Supervised jobs through `hands __serve` (docs/jobs.md). Every test uses its own temporary state dir, so its own
//! supervisor.

mod common;

use common::{Serve, StateDir, alive, eventually};
use serde_json::json;
use std::fs;

#[test]
fn job_survives_serve_and_reattaches_with_full_output() {
    let state = StateDir::new();
    let mut first = Serve::start(&state.path);
    let started = first.ok(json!({
        "op": "job.start",
        "key": "call_1|fc_1",
        "command": "echo start; sleep 2; echo done >&2; exit 3",
    }));
    assert_eq!(started["created"], true);
    assert_eq!(started["state"], "running");
    let pid = started["pid"].as_i64().unwrap() as i32;
    // The job belongs to the supervisor, not to this serve process.
    assert_ne!(pid as u32, first.pid());
    // The listener's disconnect path: stdin ends and serve kills every command it started, then exits.
    first.disconnect();
    assert!(alive(pid), "the job died with the connection");

    let mut second = Serve::start(&state.path);
    let status = second.ok(json!({ "op": "job.status", "key": "call_1|fc_1" }));
    assert_eq!(status["state"], "running");
    assert_eq!(status["pid"], pid);
    let ended = second.ok(json!({ "op": "job.wait", "key": "call_1|fc_1", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "exited");
    assert_eq!(ended["exitCode"], 3);
    assert_eq!(ended["timedOut"], false);
    assert!(ended["endedAt"].as_u64().unwrap() >= ended["startedAt"].as_u64().unwrap());
    let (output, bytes) = second
        .request(json!({ "op": "job.output", "key": "call_1|fc_1", "offset": 0 }))
        .unwrap();
    assert_eq!(String::from_utf8(bytes).unwrap(), "start\ndone\n");
    assert_eq!(output["eof"], true);
    assert_eq!(output["outputBytes"], 11);
    assert_eq!(ended["outputBytes"], 11);
}

#[test]
fn job_wait_times_out_without_killing_the_job() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    serve.ok(json!({ "op": "job.start", "key": "slow", "command": "sleep 1; echo ok" }));
    let waited = serve.ok(json!({ "op": "job.wait", "key": "slow", "timeoutMs": 100 }));
    assert_eq!(waited["state"], "running");
    assert_eq!(waited["timedOut"], true);
    // Cancelling the wait request ends the wait, not the job.
    let id = serve.send(json!({ "op": "job.wait", "key": "slow", "timeoutMs": 60_000 }));
    serve.cancel(id);
    assert_eq!(serve.reply(id).unwrap_err()["code"], "aborted");
    let ended = serve.ok(json!({ "op": "job.wait", "key": "slow", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "exited");
    assert_eq!(ended["exitCode"], 0);
}

#[test]
fn repeated_start_with_the_same_key_is_idempotent() {
    let state = StateDir::new();
    let work = state.work();
    let counter = work.join("counter");
    let mut first = Serve::start(&state.path);
    let start = json!({
        "op": "job.start",
        "key": "toolu_01ABC",
        "command": "echo once >> counter; sleep 1",
        "cwd": work,
    });
    let created = first.ok(start.clone());
    assert_eq!(created["created"], true);
    let again = first.ok(start.clone());
    assert_eq!(again["created"], false);
    assert_eq!(again["pid"], created["pid"]);
    // Other fields do not matter: a key names one job.
    let different = first.ok(json!({
        "op": "job.start",
        "key": "toolu_01ABC",
        "command": "echo twice >> counter",
        "cwd": work,
    }));
    assert_eq!(different["created"], false);
    assert_eq!(different["command"], "echo once >> counter; sleep 1");
    first.disconnect();

    // A replayed tool call from a new connection, before and after the job ended, reattaches.
    let mut second = Serve::start(&state.path);
    assert_eq!(second.ok(start.clone())["created"], false);
    second.ok(json!({ "op": "job.wait", "key": "toolu_01ABC", "timeoutMs": 15_000 }));
    let replay = second.ok(start);
    assert_eq!(replay["created"], false);
    assert_eq!(replay["state"], "exited");
    assert_eq!(fs::read_to_string(&counter).unwrap(), "once\n");
    let list = second.ok(json!({ "op": "job.list" }));
    assert_eq!(list["jobs"].as_array().unwrap().len(), 1);
}

#[test]
fn cancel_kills_the_whole_process_group() {
    let state = StateDir::new();
    let work = state.work();
    let mut serve = Serve::start(&state.path);
    serve.ok(json!({
        "op": "job.start",
        "key": "group",
        "command": "sleep 300 & echo $! > bg.pid; sleep 300 & wait",
        "cwd": work,
    }));
    let pid_file = work.join("bg.pid");
    eventually("the background pid", || {
        fs::read_to_string(&pid_file).is_ok_and(|text| text.ends_with('\n'))
    });
    let background: i32 = fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    assert!(alive(background));
    let cancelled = serve.ok(json!({ "op": "job.cancel", "key": "group" }));
    assert_eq!(cancelled["signalled"], true);
    let ended = serve.ok(json!({ "op": "job.wait", "key": "group", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "cancelled");
    assert_eq!(ended["exitCode"], 128 + libc::SIGTERM);
    eventually("the background process to die", || !alive(background));

    // A job that ignores SIGTERM needs SIGKILL, which takes the runner too; the job still ends as cancelled.
    serve.ok(json!({
        "op": "job.start",
        "key": "stubborn",
        "command": "trap '' TERM; sleep 300 & echo $! > bg2.pid; wait",
        "cwd": work,
    }));
    let pid_file = work.join("bg2.pid");
    eventually("the second background pid", || {
        fs::read_to_string(&pid_file).is_ok_and(|text| text.ends_with('\n'))
    });
    let background: i32 = fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    serve.ok(json!({ "op": "job.cancel", "key": "stubborn" }));
    let waited = serve.ok(json!({ "op": "job.wait", "key": "stubborn", "timeoutMs": 300 }));
    assert_eq!(waited["state"], "running");
    assert!(alive(background));
    serve.ok(json!({ "op": "job.cancel", "key": "stubborn", "signal": "SIGKILL" }));
    let ended = serve.ok(json!({ "op": "job.wait", "key": "stubborn", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "cancelled");
    assert_eq!(ended["exitCode"], 128 + libc::SIGKILL);
    eventually("the second background process to die", || !alive(background));
    // Cancelling a finished job changes nothing.
    let again = serve.ok(json!({ "op": "job.cancel", "key": "stubborn" }));
    assert_eq!(again["signalled"], false);
    assert_eq!(again["state"], "cancelled");
}

#[test]
fn jobs_survive_a_supervisor_restart_with_their_exit_code() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    serve.ok(json!({ "op": "job.start", "key": "upgrade", "command": "sleep 1; echo finished; exit 7" }));
    let before = state.supervisor(json!({ "op": "hello" })).unwrap();
    state.supervisor(json!({ "op": "shutdown" }));
    eventually("the supervisor to exit", || {
        state.supervisor(json!({ "op": "hello" })).is_none()
    });
    // The next request starts a new supervisor, which adopts the running job.
    let status = serve.ok(json!({ "op": "job.status", "key": "upgrade" }));
    assert_eq!(status["state"], "running");
    let after = state.supervisor(json!({ "op": "hello" })).unwrap();
    assert_ne!(before["pid"], after["pid"]);
    let ended = serve.ok(json!({ "op": "job.wait", "key": "upgrade", "timeoutMs": 15_000 }));
    assert_eq!(ended["state"], "exited");
    assert_eq!(ended["exitCode"], 7);
    let (_, bytes) = serve
        .request(json!({ "op": "job.output", "key": "upgrade" }))
        .unwrap();
    assert_eq!(bytes, b"finished\n");
}

#[test]
fn output_ranges_argv_and_errors() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    serve.ok(json!({ "op": "job.start", "key": "argv", "argv": ["printf", "%s", "abcdefghij"] }));
    let ended = serve.ok(json!({ "op": "job.wait", "key": "argv", "timeoutMs": 15_000 }));
    assert_eq!(ended["exitCode"], 0);
    assert_eq!(ended["argv"], json!(["printf", "%s", "abcdefghij"]));
    let (range, bytes) = serve
        .request(json!({ "op": "job.output", "key": "argv", "offset": 3, "maxBytes": 4 }))
        .unwrap();
    assert_eq!(bytes, b"defg");
    assert_eq!(range["nextOffset"], 7);
    assert_eq!(range["outputBytes"], 10);
    assert_eq!(range["eof"], false);
    let (range, bytes) = serve
        .request(json!({ "op": "job.output", "key": "argv", "offset": 7 }))
        .unwrap();
    assert_eq!(bytes, b"hij");
    assert_eq!(range["eof"], true);
    let (_, bytes) = serve
        .request(json!({ "op": "job.output", "key": "argv", "offset": 99 }))
        .unwrap();
    assert!(bytes.is_empty());

    // The environment is the connection's plus `env`, as for exec.
    serve.ok(json!({
        "op": "job.start",
        "key": "env",
        "command": "echo $HANDS_TEST_VALUE",
        "env": { "HANDS_TEST_VALUE": "42" },
    }));
    serve.ok(json!({ "op": "job.wait", "key": "env", "timeoutMs": 15_000 }));
    let (_, bytes) = serve.request(json!({ "op": "job.output", "key": "env" })).unwrap();
    assert_eq!(bytes, b"42\n");

    // A program that cannot start fails the job, not the request.
    serve.ok(json!({ "op": "job.start", "key": "missing", "argv": ["/nonexistent/program"] }));
    let failed = serve.ok(json!({ "op": "job.wait", "key": "missing", "timeoutMs": 15_000 }));
    assert_eq!(failed["state"], "failed");
    assert!(failed["error"].as_str().unwrap().starts_with("spawn_error"));

    let cwd = "/nonexistent";
    for (request, code) in [
        (json!({ "op": "job.start", "key": "nocwd", "command": "true", "cwd": cwd }), "spawn_error"),
        (json!({ "op": "job.start", "key": "", "command": "true" }), "EINVAL"),
        (json!({ "op": "job.start", "key": "nothing" }), "EINVAL"),
        (json!({ "op": "job.start", "key": "bad", "argv": ["ls", 1] }), "EINVAL"),
        (json!({ "op": "job.status", "key": "unknown" }), "not_found"),
        (json!({ "op": "job.output", "key": "unknown" }), "not_found"),
        (json!({ "op": "job.cancel", "key": "argv", "signal": "SIGNOPE" }), "EINVAL"),
        // The failed start left nothing behind, so the key is still free.
        (json!({ "op": "job.status", "key": "nocwd" }), "not_found"),
    ] {
        assert_eq!(serve.error(request.clone())["code"], code, "{request}");
    }

    // `hands jobs` reads the same supervisor.
    let listed = state.hands(&["jobs", "--json"]);
    let listed: serde_json::Value = serde_json::from_slice(&listed.stdout).unwrap();
    assert_eq!(listed["jobs"].as_array().unwrap().len(), 3);
    let doctor = String::from_utf8(state.hands(&["doctor"]).stdout).unwrap();
    assert!(doctor.contains("supervisor   running"), "{doctor}");
}

#[test]
fn finished_jobs_are_reported_from_disk_without_a_supervisor() {
    let state = StateDir::new();
    let mut serve = Serve::start(&state.path);
    serve.ok(json!({ "op": "job.start", "key": "done", "command": "exit 5" }));
    serve.ok(json!({ "op": "job.wait", "key": "done", "timeoutMs": 15_000 }));
    state.supervisor(json!({ "op": "shutdown" }));
    eventually("the supervisor to exit", || {
        state.supervisor(json!({ "op": "hello" })).is_none()
    });
    let listed = state.hands(&["jobs", "--json"]);
    let listed: serde_json::Value = serde_json::from_slice(&listed.stdout).unwrap();
    let job = &listed["jobs"][0];
    assert_eq!(job["key"], "done");
    assert_eq!(job["state"], "exited");
    assert_eq!(job["exitCode"], 5);
    let table = String::from_utf8(state.hands(&["jobs"]).stdout).unwrap();
    assert!(table.contains("supervisor not running"), "{table}");
    assert!(table.contains("exited"), "{table}");
}
