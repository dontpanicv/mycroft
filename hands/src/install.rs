//! `hands install [--dry-run] [--uninstall]`: put this binary at `~/.local/bin/hands` and run `hands supervise` as a
//! user service, a systemd user unit on Linux or a LaunchAgent on macOS, so jobs have a supervisor that starts with
//! the user and survives SSH sessions. Running it again converges to the same state. `--dry-run` only prints the
//! steps; `--uninstall` reverses them but keeps the state dir (job records and output).

use crate::{state, supervisor, sys};
use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

pub const LABEL: &str = "dev.mycroft.hands";
const UNIT: &str = "hands.service";

enum Step {
    StateDir,
    Copy { from: PathBuf, to: PathBuf },
    Write { path: PathBuf, contents: String },
    Remove(PathBuf),
    /// A command; a failure of an optional one is a warning.
    Run { argv: Vec<String>, optional: bool },
    /// Ask a running supervisor (perhaps one `serve` started) to exit, so the service's own takes over. Jobs keep
    /// running and are adopted.
    StopSupervisor,
}

impl Step {
    fn describe(&self) -> String {
        match self {
            Step::StateDir => format!("create the state dir {}", state::dir().display()),
            Step::Copy { from, to } => format!("copy {} to {}", from.display(), to.display()),
            Step::Write { path, .. } => format!("write {}", path.display()),
            Step::Remove(path) => format!("remove {}", path.display()),
            Step::Run { argv, .. } => format!("run {}", argv.join(" ")),
            Step::StopSupervisor => "stop a running supervisor (jobs keep running)".into(),
        }
    }

    fn optional(&self) -> bool {
        matches!(self, Step::Run { optional: true, .. })
    }

    /// Apply the step; `Ok` carries a note on what happened.
    fn apply(&self) -> Result<&'static str, String> {
        let text = |error: std::io::Error| error.to_string();
        match self {
            Step::StateDir => state::ensure().map(|_| "ok").map_err(text),
            Step::Copy { from, to } => copy_binary(from, to).map_err(text),
            Step::Write { path, contents } => {
                if fs::read_to_string(path).is_ok_and(|current| current == *contents) {
                    return Ok("unchanged");
                }
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(text)?;
                }
                fs::write(path, contents).map(|()| "written").map_err(text)
            }
            Step::Remove(path) => match fs::remove_file(path) {
                Ok(()) => Ok("removed"),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok("not present"),
                Err(error) => Err(error.to_string()),
            },
            Step::Run { argv, .. } => {
                let status = Command::new(&argv[0])
                    .args(&argv[1..])
                    .status()
                    .map_err(text)?;
                if status.success() {
                    Ok("ok")
                } else {
                    Err(format!("exited with {status}"))
                }
            }
            Step::StopSupervisor => {
                if supervisor::call_running(&json!({ "op": "shutdown" })).is_err() {
                    return Ok("none running");
                }
                let deadline = Instant::now() + Duration::from_secs(3);
                while supervisor::call_running(&json!({ "op": "hello" })).is_ok() {
                    if Instant::now() >= deadline {
                        return Err("the supervisor did not exit".into());
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                Ok("stopped")
            }
        }
    }
}

fn copy_binary(from: &Path, to: &Path) -> std::io::Result<&'static str> {
    if fs::canonicalize(from).ok() == fs::canonicalize(to).ok() {
        return Ok("already in place");
    }
    let bytes = fs::read(from)?;
    if fs::read(to).is_ok_and(|current| current == bytes) {
        return Ok("unchanged");
    }
    fs::create_dir_all(to.parent().unwrap_or(Path::new("/")))?;
    // Write beside it and rename, so a running `hands` keeps its old file and nobody sees half a binary.
    let temporary = to.with_extension("new");
    fs::write(&temporary, &bytes)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))?;
    fs::rename(&temporary, to)?;
    Ok("copied")
}

fn home() -> PathBuf {
    PathBuf::from(sys::home())
}

pub fn binary_path() -> PathBuf {
    home().join(".local/bin/hands")
}

/// The service definition `install` writes.
pub fn service_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        return home().join(format!("Library/LaunchAgents/{LABEL}.plist"));
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home().join(".config"));
    config.join("systemd/user").join(UNIT)
}

/// A state dir chosen with `HANDS_STATE_DIR` must reach the service too.
fn state_override() -> Option<String> {
    std::env::var("HANDS_STATE_DIR")
        .ok()
        .filter(|dir| !dir.is_empty())
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

pub fn launch_agent(binary: &Path) -> String {
    let log = xml(&state::log().to_string_lossy());
    let environment = match state_override() {
        Some(dir) => format!(
            "\t<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>HANDS_STATE_DIR</key>\n\t\t\
             <string>{}</string>\n\t</dict>\n",
            xml(&dir)
        ),
        None => String::new(),
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{binary}</string>
		<string>supervise</string>
	</array>
{environment}	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Standard</string>
	<key>AbandonProcessGroup</key>
	<true/>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#,
        binary = xml(&binary.to_string_lossy()),
    )
}

pub fn systemd_unit(binary: &Path) -> String {
    let quote = |text: &str| format!("\"{}\"", text.replace('%', "%%").replace('"', "\\\""));
    let environment = match state_override() {
        Some(dir) => format!("Environment={}\n", quote(&format!("HANDS_STATE_DIR={dir}"))),
        None => String::new(),
    };
    format!(
        "[Unit]
Description=hands supervisor for Mycroft: jobs that outlive SSH sessions
Documentation=https://github.com/kurkavojtech/mycroft/tree/main/hands

[Service]
ExecStart={binary} supervise
{environment}Restart=always
RestartSec=2
# Jobs run in their own sessions and outlive the supervisor: stopping or upgrading it must not kill them.
KillMode=process

[Install]
WantedBy=default.target
",
        binary = quote(&binary.to_string_lossy()),
    )
}

fn run(argv: &[&str], optional: bool) -> Step {
    Step::Run {
        argv: argv.iter().map(|arg| arg.to_string()).collect(),
        optional,
    }
}

fn install_steps() -> Result<Vec<Step>, String> {
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let binary = binary_path();
    let service = service_path();
    let mut steps = vec![
        Step::StateDir,
        Step::Copy {
            from: executable,
            to: binary.clone(),
        },
    ];
    if cfg!(target_os = "macos") {
        // SAFETY: getuid cannot fail.
        let domain = format!("gui/{}", unsafe { libc::getuid() });
        steps.push(Step::Write {
            path: service.clone(),
            contents: launch_agent(&binary),
        });
        steps.push(run(
            &["launchctl", "bootout", &format!("{domain}/{LABEL}")],
            true,
        ));
        steps.push(Step::StopSupervisor);
        // Fails without a GUI login session (SSH only); the agent then loads at the next login.
        steps.push(run(
            &["launchctl", "bootstrap", &domain, &service.to_string_lossy()],
            true,
        ));
    } else {
        steps.push(Step::Write {
            path: service,
            contents: systemd_unit(&binary),
        });
        steps.push(run(&["systemctl", "--user", "daemon-reload"], false));
        steps.push(run(&["systemctl", "--user", "stop", UNIT], true));
        steps.push(Step::StopSupervisor);
        steps.push(run(&["systemctl", "--user", "enable", "--now", UNIT], false));
        // Keeps the user's service manager, and so the supervisor, running without a login session.
        steps.push(run(&["loginctl", "enable-linger"], true));
    }
    Ok(steps)
}

fn uninstall_steps() -> Vec<Step> {
    let mut steps = Vec::new();
    if cfg!(target_os = "macos") {
        // SAFETY: getuid cannot fail.
        let target = format!("gui/{}/{LABEL}", unsafe { libc::getuid() });
        steps.push(run(&["launchctl", "bootout", &target], true));
        steps.push(Step::Remove(service_path()));
    } else {
        steps.push(run(&["systemctl", "--user", "disable", "--now", UNIT], true));
        steps.push(Step::Remove(service_path()));
        steps.push(run(&["systemctl", "--user", "daemon-reload"], true));
    }
    steps.push(Step::StopSupervisor);
    steps.push(Step::Remove(binary_path()));
    steps
}

pub fn main(args: &[String]) -> i32 {
    let mut dry_run = false;
    let mut uninstall = false;
    for arg in args {
        match arg.as_str() {
            "--dry-run" | "-n" => dry_run = true,
            "--uninstall" => uninstall = true,
            _ => {
                eprintln!("usage: hands install [--dry-run] [--uninstall]");
                return 2;
            }
        }
    }
    let steps = if uninstall {
        uninstall_steps()
    } else {
        match install_steps() {
            Ok(steps) => steps,
            Err(error) => {
                eprintln!("hands install: {error}");
                return 1;
            }
        }
    };
    for step in &steps {
        if dry_run {
            println!("would {}", step.describe());
            if let Step::Write { contents, .. } = step {
                for line in contents.lines() {
                    println!("    | {line}");
                }
            }
            continue;
        }
        match step.apply() {
            Ok(note) => println!("{}: {note}", step.describe()),
            Err(error) if step.optional() => {
                println!("{}: failed ({error}), continuing", step.describe())
            }
            Err(error) => {
                eprintln!("hands install: {}: {error}", step.describe());
                return 1;
            }
        }
    }
    if uninstall {
        println!(
            "{} {} (job records and output); jobs still running keep running",
            if dry_run { "would keep" } else { "kept" },
            state::dir().display()
        );
    } else if !dry_run {
        println!("installed; check with: {} doctor", binary_path().display());
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_agent_is_a_valid_plist() {
        let plist = launch_agent(Path::new("/Users/a & b/.local/bin/hands"));
        assert!(plist.contains("<string>dev.mycroft.hands</string>"));
        assert!(plist.contains("<string>/Users/a &amp; b/.local/bin/hands</string>"));
        assert!(plist.contains("<key>AbandonProcessGroup</key>"));
        // Lint only: the file goes to a temporary directory and is never loaded.
        if Path::new("/usr/bin/plutil").exists() {
            let file = std::env::temp_dir().join(format!("hands-test-{}.plist", std::process::id()));
            fs::write(&file, &plist).unwrap();
            let lint = Command::new("/usr/bin/plutil").arg("-lint").arg(&file).output().unwrap();
            let _ = fs::remove_file(&file);
            assert!(lint.status.success(), "{}", String::from_utf8_lossy(&lint.stdout));
        }
    }

    #[test]
    fn systemd_unit_quotes_the_binary_and_spares_jobs() {
        let unit = systemd_unit(Path::new("/home/a b/.local/bin/hands%1"));
        assert!(unit.contains("ExecStart=\"/home/a b/.local/bin/hands%%1\" supervise\n"));
        assert!(unit.contains("KillMode=process\n"));
        assert!(unit.contains("WantedBy=default.target\n"));
    }
}
