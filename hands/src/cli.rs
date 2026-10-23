//! The human-facing subcommands: `hands jobs`, `hands paired`, `hands unpair` and `hands doctor`.

use crate::serve::{PROTOCOL, VERSION, now_ms};
use crate::{install, jobs, listener, pairing, state, supervisor};
use serde_json::{Value, json};
use std::path::Path;

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

/// `hands paired [--json]`: the phones that may connect to the listener.
pub fn paired(args: &[String]) -> i32 {
    let as_json = match args {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => {
            eprintln!("usage: hands paired [--json]");
            return 2;
        }
    };
    let phones = pairing::load();
    if as_json {
        println!("{}", json!({ "phones": phones }));
        return 0;
    }
    if phones.is_empty() {
        println!("no paired phones; pair with the command from Mycroft's Add machine");
        return 0;
    }
    let now = now_ms();
    println!("{:<28} {:>10}  PUBLIC KEY", "NAME", "PAIRED");
    for phone in &phones {
        let paired = phone["pairedAt"].as_u64().unwrap_or(now);
        println!(
            "{:<28} {:>10}  {}",
            phone["name"].as_str().unwrap_or("?"),
            format!("{} ago", duration(now.saturating_sub(paired))),
            phone["publicKey"].as_str().unwrap_or("?"),
        );
    }
    0
}

/// `hands unpair <name>`: remove the phones with this name (or this public key).
pub fn unpair(args: &[String]) -> i32 {
    let [name] = args else {
        eprintln!("usage: hands unpair <name>");
        return 2;
    };
    match pairing::remove(name) {
        Ok(0) => {
            eprintln!("hands unpair: no paired phone named {name}; see `hands paired`");
            1
        }
        Ok(count) => {
            let what = if count == 1 { "phone".to_string() } else { format!("{count} phones") };
            println!("unpaired {what} named {name}; connections already open stay until they end");
            0
        }
        Err(error) => {
            eprintln!("hands unpair: {error}");
            1
        }
    }
}

fn present(path: &Path) -> String {
    let mark = if path.exists() { "present" } else { "missing" };
    format!("{} ({mark})", path.display())
}

/// `hands doctor`: what is installed and running, for humans and bug reports.
pub fn doctor() -> i32 {
    let row = |name: &str, value: String| println!("{name:<12} {value}");
    row("hands", format!("{VERSION} (protocol {PROTOCOL})"));
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
    let listening = listener::running();
    let port = std::fs::read(state::listener_json())
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value["port"].as_u64());
    row(
        "listener",
        match (listening, port) {
            (Some(pid), Some(port)) => format!("running, pid {pid}, port {port}"),
            (Some(pid), None) => format!("running, pid {pid}"),
            (None, _) => "not running (the service runs `hands supervise --listen`)".into(),
        },
    );
    let cert = state::dir().join("listener-cert.pem");
    if let Ok(der) = rustls::pki_types::pem::PemObject::from_pem_file(&cert)
        .map(|der: rustls::pki_types::CertificateDer| der)
    {
        row("certificate", format!("sha256 {}", crate::tls::hex(&crate::tls::sha256(&der))));
    }
    let phones = pairing::load();
    let names: Vec<&str> = phones.iter().filter_map(|phone| phone["name"].as_str()).collect();
    row(
        "paired",
        if names.is_empty() { "no phones".into() } else { names.join(", ") },
    );
    row("installed", present(&install::binary_path()));
    row("service", present(&install::service_path()));
    if cfg!(target_os = "linux") {
        let linger = crate::permissions::linger();
        row(
            "linger",
            match linger.as_deref() {
                Some("yes") => "yes".into(),
                Some(other) => format!("{other} (the supervisor stops at logout; run `loginctl enable-linger`)"),
                None => "unknown (no loginctl)".into(),
            },
        );
    }
    row("desktop", crate::cua::describe());
    0
}
