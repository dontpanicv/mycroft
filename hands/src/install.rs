//! `hands install [--pair BASE --pin PIN] [--desktop-zip PATH] [--no-service] [--bind ADDR] [--dry-run]
//! [--uninstall]`: put this binary at `~/.local/bin/hands` and run `hands supervise --listen` as a user service, a
//! systemd user unit on Linux or a LaunchAgent on macOS, so jobs have a supervisor and the phone a listener that
//! start with the user and survive SSH sessions. Running it again converges to the same state. `--dry-run` only
//! prints the steps; `--uninstall` reverses them but keeps the state dir (job records and output, the certificate
//! and the paired phones).
//!
//! With `--pair` (what the phone's install script runs) it then pairs with the phone (pairing.rs) and prints only
//! the result. If the service cannot start (no GUI login on a Mac, no user systemd), or with `--no-service`, the
//! listener runs detached until the machine restarts.
//!
//! On macOS, given `--desktop-zip` (or with `MycroftHands.zip` next to this binary), it also installs the desktop
//! helper (ui/app.rs): `~/Applications/Mycroft Hands.app`, replaced only when the version differs, and its
//! LaunchAgent `dev.mycroft.hands-desktop`. A failure there never fails the install.
//!
//! Then, on macOS, it walks through the permissions Mycroft needs, one at a time, when it has a terminal to talk to
//! (permissions.rs); otherwise it prints how to get to that walkthrough.

use crate::ui::app;
use crate::{listener, pairing, state, supervisor, sys};
use std::net::IpAddr;
use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub const LABEL: &str = "dev.mycroft.hands";
const UNIT: &str = "hands.service";

enum Step {
    StateDir,
    Copy { from: PathBuf, to: PathBuf },
    Write { path: PathBuf, contents: String },
    Remove(PathBuf),
    /// A command; a failure of an optional one is a warning. `starts` marks the ones the service needs to start:
    /// when pairing, their failure only means the listener runs detached instead.
    Run {
        argv: Vec<String>,
        optional: bool,
        starts: bool,
    },
    /// Ask a running supervisor (perhaps one `serve` started) to exit, so the service's own takes over. Jobs keep
    /// running and are adopted.
    StopSupervisor,
    /// Stop a running listener (perhaps one `hands pair` started detached), so the service's own takes over.
    StopListener,
    /// Unpack Mycroft Hands.app from the zip, unless the installed copy has the same version.
    InstallApp { zip: PathBuf, to: PathBuf },
    RemoveDir(PathBuf),
    /// `launchctl bootstrap`, retried briefly: right after `bootout`, launchd may still be removing the old job.
    Bootstrap { domain: String, plist: PathBuf },
    /// A step of the desktop helper's: its failure is a warning, and skips the desktop steps after it.
    Desktop(Box<Step>),
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
            Step::StopListener => "stop a running listener".into(),
            Step::InstallApp { zip, to } => {
                let offered = match app::zip_info(zip) {
                    Ok((version, _)) => version,
                    Err(_) => "?".into(),
                };
                let current = app::installed_version(to).unwrap_or_else(|| "none".into());
                format!(
                    "install {} {offered} from {} to {} (installed: {current}; replaced only when the version differs)",
                    app::APP_NAME,
                    zip.display(),
                    to.display()
                )
            }
            Step::RemoveDir(path) => format!("remove {}", path.display()),
            Step::Bootstrap { domain, plist } => format!("run launchctl bootstrap {domain} {}", plist.display()),
            Step::Desktop(step) => step.describe(),
        }
    }

    /// A desktop step's own step.
    fn inner(&self) -> &Step {
        match self {
            Step::Desktop(step) => step,
            step => step,
        }
    }

    fn optional(&self) -> bool {
        matches!(self, Step::Run { optional: true, .. } | Step::Desktop(_))
    }

    /// Apply the step; `Ok` carries a note on what happened. `quiet` captures the output of commands, which is
    /// then only shown in the error.
    fn apply(&self, quiet: bool) -> Result<String, String> {
        let text = |error: std::io::Error| error.to_string();
        match self {
            Step::StateDir => state::ensure().map(|_| "ok".into()).map_err(text),
            Step::Copy { from, to } => copy_binary(from, to).map(Into::into).map_err(text),
            Step::Write { path, contents } => {
                if fs::read_to_string(path).is_ok_and(|current| current == *contents) {
                    return Ok("unchanged".into());
                }
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(text)?;
                }
                fs::write(path, contents).map(|()| "written".into()).map_err(text)
            }
            Step::Remove(path) => match fs::remove_file(path) {
                Ok(()) => Ok("removed".into()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok("not present".into()),
                Err(error) => Err(error.to_string()),
            },
            Step::RemoveDir(path) => match fs::remove_dir_all(path) {
                Ok(()) => Ok("removed".into()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok("not present".into()),
                Err(error) => Err(error.to_string()),
            },
            Step::InstallApp { zip, to } => app::install(zip, to),
            Step::Bootstrap { domain, plist } => {
                let mut tries = 0;
                loop {
                    let argv = ["launchctl", "bootstrap", domain, &plist.to_string_lossy()].map(String::from);
                    let result = Step::Run { argv: argv.to_vec(), optional: false, starts: false }.apply(true);
                    tries += 1;
                    if result.is_ok() || tries == 4 {
                        return result;
                    }
                    thread::sleep(Duration::from_millis(500));
                }
            }
            Step::Desktop(step) => step.apply(quiet),
            Step::Run { argv, .. } => {
                let mut command = Command::new(&argv[0]);
                command.args(&argv[1..]);
                let (status, said) = if quiet {
                    let output = command.stdin(Stdio::null()).output().map_err(text)?;
                    let said = String::from_utf8_lossy(&output.stderr).trim().to_string();
                    (output.status, said)
                } else {
                    (command.status().map_err(text)?, String::new())
                };
                match (status.success(), said.is_empty()) {
                    (true, _) => Ok("ok".into()),
                    (false, true) => Err(format!("exited with {status}")),
                    (false, false) => Err(format!("exited with {status}: {said}")),
                }
            }
            Step::StopListener => listener::stop().map(Into::into),
            Step::StopSupervisor => {
                if supervisor::call_running(&json!({ "op": "shutdown" })).is_err() {
                    return Ok("none running".into());
                }
                let deadline = Instant::now() + Duration::from_secs(3);
                while supervisor::call_running(&json!({ "op": "hello" })).is_ok() {
                    if Instant::now() >= deadline {
                        return Err("the supervisor did not exit".into());
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                Ok("stopped".into())
            }
        }
    }
}

fn copy_binary(from: &Path, to: &Path) -> std::io::Result<&'static str> {
    if fs::canonicalize(from).ok() == fs::canonicalize(to).ok() {
        return Ok("already in place");
    }
    // Never replace a newer hands with an older one (an outdated phone app serving an old binary, say).
    if let Some(installed) = installed_version(to) {
        if newer(&installed, env!("CARGO_PKG_VERSION")) {
            return Ok("kept the newer hands that is already installed");
        }
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

/// The version an installed `hands` reports (`hands version` prints "hands X.Y.Z").
fn installed_version(binary: &Path) -> Option<String> {
    let output = std::process::Command::new(binary).arg("version").output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.split_whitespace().nth(1).map(str::to_owned)
}

/// Whether version `a` is newer than `b` (numeric dotted versions; missing parts count as 0).
fn newer(a: &str, b: &str) -> bool {
    let parse = |v: &str| v.split('.').map(|part| part.trim().parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (a, b) = (parse(a), parse(b));
    for index in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(index).copied().unwrap_or(0), b.get(index).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

#[cfg(test)]
mod version_tests {
    use super::newer;

    #[test]
    fn compares_versions() {
        assert!(newer("0.3.0", "0.2.0"));
        assert!(newer("0.10.0", "0.9.9"));
        assert!(!newer("0.2.0", "0.2.0"));
        assert!(!newer("0.2.0", "0.3.0"));
        assert!(newer("1.0", "0.99.1"));
    }
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

/// The service's command line after the binary: `supervise --listen [--bind ADDR]`.
fn service_args(bind: Option<IpAddr>) -> Vec<String> {
    let mut args = vec!["supervise".to_string(), "--listen".to_string()];
    if let Some(bind) = bind {
        args.extend(["--bind".to_string(), bind.to_string()]);
    }
    args
}

pub fn launch_agent(binary: &Path, bind: Option<IpAddr>) -> String {
    let arguments: String = service_args(bind)
        .iter()
        .map(|arg| format!("\t\t<string>{}</string>\n", xml(arg)))
        .collect();
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
{arguments}	</array>
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

pub fn systemd_unit(binary: &Path, bind: Option<IpAddr>) -> String {
    let quote = |text: &str| format!("\"{}\"", text.replace('%', "%%").replace('"', "\\\""));
    let environment = match state_override() {
        Some(dir) => format!("Environment={}\n", quote(&format!("HANDS_STATE_DIR={dir}"))),
        None => String::new(),
    };
    format!(
        "[Unit]
Description=hands for Mycroft: the supervisor of jobs and the paired phone's listener
Documentation=https://github.com/kurkavojtech/mycroft/tree/main/hands

[Service]
ExecStart={binary} {arguments}
{environment}Restart=always
RestartSec=2
# Jobs run in their own sessions and outlive the supervisor: stopping or upgrading it must not kill them.
KillMode=process

[Install]
WantedBy=default.target
",
        binary = quote(&binary.to_string_lossy()),
        arguments = service_args(bind).join(" "),
    )
}

fn run(argv: &[&str], optional: bool) -> Step {
    Step::Run {
        argv: argv.iter().map(|arg| arg.to_string()).collect(),
        optional,
        starts: false,
    }
}

/// A command the service needs to start.
fn start(argv: &[&str], optional: bool) -> Step {
    Step::Run {
        argv: argv.iter().map(|arg| arg.to_string()).collect(),
        optional,
        starts: true,
    }
}

/// The desktop helper's steps: the app and its LaunchAgent (with the service).
fn desktop_steps(zip: &Path, with_service: bool) -> Vec<Step> {
    let app_path = app::app_path();
    let agent = app::agent_path();
    // SAFETY: getuid cannot fail.
    let domain = format!("gui/{}", unsafe { libc::getuid() });
    let mut steps = vec![Step::InstallApp {
        zip: zip.to_path_buf(),
        to: app_path.clone(),
    }];
    if with_service {
        steps.push(Step::Write {
            path: agent.clone(),
            contents: app::launch_agent(&app::app_binary(&app_path), &state::dir()),
        });
        steps.push(run(&["launchctl", "bootout", &format!("{domain}/{}", app::LABEL)], true));
        // Fails without a GUI login session (SSH only); the agent then loads at the next login.
        steps.push(Step::Bootstrap { domain, plist: agent });
    }
    steps.into_iter().map(|step| Step::Desktop(Box::new(step))).collect()
}

fn install_steps(with_service: bool, bind: Option<IpAddr>, desktop_zip: Option<&Path>) -> Result<Vec<Step>, String> {
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
    if !with_service {
        steps.push(Step::StopSupervisor);
        steps.push(Step::StopListener);
    } else if cfg!(target_os = "macos") {
        // SAFETY: getuid cannot fail.
        let domain = format!("gui/{}", unsafe { libc::getuid() });
        steps.push(Step::Write {
            path: service.clone(),
            contents: launch_agent(&binary, bind),
        });
        steps.push(run(
            &["launchctl", "bootout", &format!("{domain}/{LABEL}")],
            true,
        ));
        steps.push(Step::StopSupervisor);
        steps.push(Step::StopListener);
        // Fails without a GUI login session (SSH only); the agent then loads at the next login.
        steps.push(start(
            &["launchctl", "bootstrap", &domain, &service.to_string_lossy()],
            true,
        ));
    } else {
        steps.push(Step::Write {
            path: service,
            contents: systemd_unit(&binary, bind),
        });
        // Fails without a user systemd (containers, some SSH sessions); pairing then runs the listener detached.
        steps.push(start(&["systemctl", "--user", "daemon-reload"], false));
        steps.push(run(&["systemctl", "--user", "stop", UNIT], true));
        steps.push(Step::StopSupervisor);
        steps.push(Step::StopListener);
        steps.push(start(&["systemctl", "--user", "enable", "--now", UNIT], false));
        // Keeps the user's service manager, and so the supervisor, running without a login session.
        steps.push(run(&["loginctl", "enable-linger"], true));
    }
    if let Some(zip) = desktop_zip {
        steps.extend(desktop_steps(zip, with_service));
    }
    Ok(steps)
}

fn uninstall_steps() -> Vec<Step> {
    let mut steps = Vec::new();
    if cfg!(target_os = "macos") {
        // SAFETY: getuid cannot fail.
        let domain = format!("gui/{}", unsafe { libc::getuid() });
        steps.push(run(&["launchctl", "bootout", &format!("{domain}/{}", app::LABEL)], true));
        steps.push(Step::Remove(app::agent_path()));
        steps.push(Step::RemoveDir(app::app_path()));
        let target = format!("{domain}/{LABEL}");
        steps.push(run(&["launchctl", "bootout", &target], true));
        steps.push(Step::Remove(service_path()));
    } else {
        steps.push(run(&["systemctl", "--user", "disable", "--now", UNIT], true));
        steps.push(Step::Remove(service_path()));
        steps.push(run(&["systemctl", "--user", "daemon-reload"], true));
    }
    steps.push(Step::StopSupervisor);
    steps.push(Step::StopListener);
    steps.push(Step::Remove(binary_path()));
    steps
}

const USAGE: &str = "usage: hands install [--pair <BASE> --pin <PIN>] [--desktop-zip <PATH>] [--no-service] [--bind <ADDR>] \
                     [--dry-run] [--uninstall]";

struct Options {
    dry_run: bool,
    uninstall: bool,
    service: bool,
    bind: Option<IpAddr>,
    pair: Option<(pairing::Base, [u8; 32])>,
    desktop_zip: Option<PathBuf>,
}

fn options(args: &[String]) -> Result<Options, String> {
    let mut options = Options {
        dry_run: false,
        uninstall: false,
        service: true,
        bind: None,
        pair: None,
        desktop_zip: None,
    };
    let (mut base, mut pin) = (None, None);
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let value = args.as_slice().first();
        match (arg.as_str(), value) {
            ("--dry-run" | "-n", _) => options.dry_run = true,
            ("--uninstall", _) => options.uninstall = true,
            ("--no-service", _) => options.service = false,
            ("--pair", Some(value)) => base = Some(pairing::parse_base(value)?),
            ("--pin", Some(value)) => pin = Some(pairing::parse_pin(value)?),
            ("--bind", Some(value)) => options.bind = Some(pairing::parse_bind(value)?),
            ("--desktop-zip", Some(value)) => {
                let path = PathBuf::from(value);
                if !path.is_file() {
                    return Err(format!("--desktop-zip: no file at {value}"));
                }
                options.desktop_zip = Some(fs::canonicalize(&path).unwrap_or(path));
            }
            _ => return Err(String::new()),
        }
        if matches!(arg.as_str(), "--pair" | "--pin" | "--bind" | "--desktop-zip") {
            args.next();
        }
    }
    match (base, pin) {
        (Some(base), Some(pin)) if !options.uninstall => options.pair = Some((base, pin)),
        (None, None) => {}
        _ => return Err(String::new()),
    }
    Ok(options)
}

pub fn main(args: &[String]) -> i32 {
    let options = match options(args) {
        Ok(options) => options,
        Err(error) => {
            if !error.is_empty() {
                eprintln!("hands install: {error}");
            }
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let dry_run = options.dry_run;
    // The phone's install script prints one line: pairing prints only the result, and failures.
    let quiet = options.pair.is_some() && !dry_run;
    let desktop_zip = match (&options.desktop_zip, cfg!(target_os = "macos")) {
        (Some(_), false) => {
            eprintln!("hands install: --desktop-zip ignored; desktop control needs macOS");
            None
        }
        (Some(zip), true) => Some(zip.clone()),
        // MycroftHands.zip shipped next to this binary.
        (None, true) => std::env::current_exe()
            .ok()
            .and_then(|exe| Some(exe.parent()?.join(app::ZIP_NAME)))
            .filter(|zip| zip.is_file()),
        (None, false) => None,
    };
    let steps = if options.uninstall {
        uninstall_steps()
    } else {
        match install_steps(options.service, options.bind, desktop_zip.as_deref()) {
            Ok(steps) => steps,
            Err(error) => {
                eprintln!("hands install: {error}");
                return 1;
            }
        }
    };
    // Whether the service started, so pairing can wait for its listener instead of starting one.
    let mut service_started = options.service;
    let mut service_failure = None;
    let mut desktop_failed = false;
    for step in &steps {
        let desktop = matches!(step, Step::Desktop(_));
        if desktop && desktop_failed {
            if !quiet {
                println!("{}: skipped", step.describe());
            }
            continue;
        }
        if dry_run {
            println!("would {}", step.describe());
            if let Step::Write { contents, .. } = step.inner() {
                for line in contents.lines() {
                    println!("    | {line}");
                }
            }
            continue;
        }
        let starts = matches!(step, Step::Run { starts: true, .. });
        match step.apply(quiet) {
            Ok(note) => {
                if !quiet {
                    println!("{}: {note}", step.describe());
                }
            }
            Err(error) if desktop && !step.inner().optional() => {
                // The desktop helper is optional: hands itself is installed either way.
                desktop_failed = true;
                eprintln!("hands: desktop control is not set up: {}: {error}", step.describe());
            }
            Err(error) if starts && quiet => {
                // Pairing does not need the service: the listener then runs detached.
                service_started = false;
                service_failure.get_or_insert(format!("{}: {error}", step.describe()));
            }
            Err(error) if step.optional() => {
                service_started &= !starts;
                if !quiet {
                    println!("{}: failed ({error}), continuing", step.describe());
                }
            }
            Err(error) => {
                eprintln!("hands install: {}: {error}", step.describe());
                return 1;
            }
        }
    }
    if options.uninstall {
        println!(
            "{} {} (job records and output, the certificate and paired phones); jobs still running keep running",
            if dry_run { "would keep" } else { "kept" },
            state::dir().display()
        );
        return 0;
    }
    if let Some((base, pin)) = &options.pair {
        let host = &base.host;
        if dry_run {
            println!("would start the listener if the service has not, and pair with the phone at {host}");
            return 0;
        }
        // launchd and systemd start the service at once; its listener only has to load its certificate.
        let grace = if service_started { Duration::from_secs(10) } else { Duration::ZERO };
        let result = pairing::pair(base, *pin, &binary_path(), options.bind, grace);
        if let (Ok(_), Some(failure)) = (&result, &service_failure) {
            eprintln!("hands: the service did not start ({failure}); the listener runs until this machine restarts");
        }
        return match result {
            Ok(line) => {
                println!("{line}");
                crate::permissions::after_install();
                0
            }
            Err(error) => {
                eprintln!("hands install: {error}");
                1
            }
        };
    }
    if !dry_run {
        println!("installed; check with: {} doctor", binary_path().display());
        crate::permissions::after_install();
    } else if cfg!(target_os = "macos") {
        println!("would walk through the permissions Mycroft needs on this Mac, one at a time (hands permissions)");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_agent_is_a_valid_plist() {
        let plist = launch_agent(Path::new("/Users/a & b/.local/bin/hands"), "10.0.0.2".parse().ok());
        assert!(plist.contains("<string>dev.mycroft.hands</string>"));
        assert!(plist.contains("<string>/Users/a &amp; b/.local/bin/hands</string>"));
        assert!(plist.contains("<key>AbandonProcessGroup</key>"));
        assert!(plist.contains(
            "<string>supervise</string>\n\t\t<string>--listen</string>\n\t\t<string>--bind</string>\n\t\t<string>10.0.0.2</string>\n\t</array>"
        ));
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
        let unit = systemd_unit(Path::new("/home/a b/.local/bin/hands%1"), None);
        assert!(unit.contains("ExecStart=\"/home/a b/.local/bin/hands%%1\" supervise --listen\n"));
        assert!(unit.contains("KillMode=process\n"));
        assert!(unit.contains("WantedBy=default.target\n"));
    }
}
