//! The human-facing subcommands: `hands jobs` and `hands doctor`.

use crate::serve::{PROTOCOL, VERSION, now_ms};
use crate::{install, jobs, state, supervisor};
use serde_json::{Value, json};
use std::path::Path;
use std::process::Command;

/// `45s`, `12m`, `3h4m`, `2d3h`.
fn duration(ms: u64) -> String {
    let seconds = ms / 1000;
    match seconds {
        0..60 => format!("{seconds}s"),
        60..3600 => format!("{}m", seconds / 60),
        3600..86_400 => format!("{}h{}m", seconds / 3600, seconds % 3600 / 60),
        _ => format!("{}d{}h", seconds / 86_400, seconds % 86_400 / 3600),
    }
}

fn bytes(count: u64) -> String {
    match count {
        0..1024 => format!("{count}B"),
        1024..1_048_576 => format!("{:.1}K", count as f64 / 1024.0),
        _ => format!("{:.1}M", count as f64 / 1_048_576.0),
    }
}

fn command_text(job: &Value) -> String {
    let text = match job["command"].as_str() {
        Some(command) => command.to_string(),
        None => job["argv"]
            .as_array()
            .map(|argv| {
                argv.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default(),
    };
    let text = text.replace('\n', " ");
    match text.char_indices().nth(60) {
        Some((cut, _)) => format!("{}...", &text[..cut]),
        None => text,
    }
}

/// `hands jobs [--json]`: the supervisor's jobs, or the records on disk when no supervisor runs.
pub fn jobs(args: &[String]) -> i32 {
    let as_json = args.iter().any(|arg| arg == "--json");
    let (jobs, from_disk) = match supervisor::call_running(&json!({ "op": "job.list" })) {
        Ok((list, _)) => (list["jobs"].as_array().cloned().unwrap_or_default(), false),
        Err(_) => (jobs::read_all(&state::jobs_dir()), true),
    };
    if as_json {
        println!("{}", json!({ "jobs": jobs }));
        return 0;
    }
    if from_disk {
        println!("(supervisor not running; showing the records on disk)");
    }
    if jobs.is_empty() {
        println!("no jobs");
        return 0;
    }
    let now = now_ms();
    println!(
        "{:<10} {:>5} {:>7} {:>9} {:>8} {:>8}  {:<24} COMMAND",
        "STATE", "EXIT", "PID", "STARTED", "RAN", "OUTPUT", "KEY"
    );
    for job in &jobs {
        let started = job["startedAt"].as_u64().unwrap_or(0);
        let ended = job["endedAt"].as_u64().unwrap_or(now);
        println!(
            "{:<10} {:>5} {:>7} {:>9} {:>8} {:>8}  {:<24} {}",
            job["state"].as_str().unwrap_or("?"),
            job["exitCode"].as_i64().map(|code| code.to_string()).unwrap_or("-".into()),
            job["pid"].as_u64().map(|pid| pid.to_string()).unwrap_or("-".into()),
            format!("{} ago", duration(now.saturating_sub(started))),
            duration(ended.saturating_sub(started)),
            bytes(job["outputBytes"].as_u64().unwrap_or(0)),
            job["key"].as_str().unwrap_or("?"),
            command_text(job),
        );
    }
    0
}

fn present(path: &Path) -> String {
    let mark = if path.exists() { "present" } else { "missing" };
    format!("{} ({mark})", path.display())
}

/// `hands doctor`: what is installed and running, for humans and bug reports.
pub fn doctor() -> i32 {
    let row = |name: &str, value: String| println!("{name:<12} {value}");
    row("hands", format!("{VERSION} (pi-env protocol {PROTOCOL})"));
    row(
        "binary",
        std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|error| format!("unknown ({error})")),
    );
    row(
        "os/arch",
        format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH),
    );
    let dir = state::dir();
    row(
        "state dir",
        format!(
            "{}{}",
            dir.display(),
            if dir.is_dir() { "" } else { " (not created yet)" }
        ),
    );
    match supervisor::call_running(&json!({ "op": "hello" })) {
        Ok((hello, _)) => {
            let version = hello["version"].as_str().unwrap_or("?");
            let mismatch = if version == VERSION {
                ""
            } else {
                " (differs from this binary; `hands install` restarts it)"
            };
            row(
                "supervisor",
                format!("running, pid {}, version {version}{mismatch}", hello["pid"]),
            );
            row(
                "jobs",
                format!("{} ({} running)", hello["jobs"], hello["running"]),
            );
        }
        Err(_) => {
            row(
                "supervisor",
                "not running (`hands serve` starts one on demand)".into(),
            );
            let jobs = jobs::read_all(&state::jobs_dir());
            let running = jobs.iter().filter(|job| job["state"] == "running").count();
            row("jobs", format!("{} on disk ({running} marked running)", jobs.len()));
        }
    }
    row("installed", present(&install::binary_path()));
    row("service", present(&install::service_path()));
    if cfg!(target_os = "linux") {
        let linger = Command::new("loginctl")
            .args(["show-user", &std::env::var("USER").unwrap_or_default(), "-p", "Linger", "--value"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string());
        row(
            "linger",
            match linger.as_deref() {
                Some("yes") => "yes".into(),
                Some(other) => format!("{other} (the supervisor stops at logout; run `loginctl enable-linger`)"),
                None => "unknown (no loginctl)".into(),
            },
        );
    }
    row("ui", "not supported yet (ui.observe and ui.act arrive in M6)".into());
    0
}
