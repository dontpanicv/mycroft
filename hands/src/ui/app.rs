//! Mycroft Hands.app, the desktop helper, on macOS: installing it from `MycroftHands.zip` (desktop/scripts/build.sh),
//! its LaunchAgent `dev.mycroft.hands-desktop`, and asking for its two permissions.
//!
//! macOS grants Accessibility and Screen Recording to the *responsible* app of a process. Run from a terminal, a
//! prompt would name the terminal. So `hands` never prompts itself: it opens the app with `open -n`, which makes
//! launchd start it as its own responsible process, with `--request-permissions`. The app shows macOS's prompts,
//! opens the System Settings panes, waits until both are granted, and restarts the serving helper.

use crate::{sys, ui};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub const LABEL: &str = "dev.mycroft.hands-desktop";
pub const BUNDLE_ID: &str = "dev.mycroft.hands-desktop";
pub const APP_NAME: &str = "Mycroft Hands.app";
pub const ZIP_NAME: &str = "MycroftHands.zip";
/// How long the app keeps polling for the grants after `hands install` opens it.
const DEFAULT_WAIT_SECS: u64 = 300;
const TEMPLATE: &str = include_str!("../../../desktop/LaunchAgent/dev.mycroft.hands-desktop.plist.template");

fn home() -> PathBuf {
    PathBuf::from(sys::home())
}

/// `~/Applications/Mycroft Hands.app`.
pub fn app_path() -> PathBuf {
    home().join("Applications").join(APP_NAME)
}

pub fn app_binary(app: &Path) -> PathBuf {
    app.join("Contents/MacOS/hands-desktop")
}

pub fn agent_path() -> PathBuf {
    home().join(format!("Library/LaunchAgents/{LABEL}.plist"))
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The LaunchAgent: desktop/LaunchAgent's template with the binary and the state dir filled in, without its comment.
pub fn launch_agent(binary: &Path, state_dir: &Path) -> String {
    let mut plist = TEMPLATE.to_string();
    if let (Some(start), Some(end)) = (plist.find("<!--"), plist.find("-->")) {
        let end = end + "-->".len();
        let end = if plist[end..].starts_with('\n') { end + 1 } else { end };
        plist.replace_range(start..end, "");
    }
    plist
        .replace("{{HANDS_DESKTOP_BIN}}", &xml(&binary.to_string_lossy()))
        .replace("{{HANDS_STATE_DIR}}", &xml(&state_dir.to_string_lossy()))
}

/// The `<string>` after `<key>key</key>` in an XML property list.
fn plist_string(text: &str, key: &str) -> Option<String> {
    let rest = &text[text.find(&format!("<key>{key}</key>"))?..];
    let start = rest.find("<string>")? + "<string>".len();
    let end = rest[start..].find("</string>")?;
    Some(rest[start..start + end].trim().to_string())
}

/// The version of an installed app, from its Info.plist.
pub fn installed_version(app: &Path) -> Option<String> {
    let text = fs::read_to_string(app.join("Contents/Info.plist")).ok()?;
    plist_string(&text, "CFBundleShortVersionString")
}

/// The version and bundle id of the app in `zip`, read without unpacking it.
pub fn zip_info(zip: &Path) -> Result<(String, String), String> {
    let output = Command::new("unzip")
        .arg("-p")
        .arg(zip)
        .arg(format!("{APP_NAME}/Contents/Info.plist"))
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("cannot run unzip: {error}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    match (plist_string(&text, "CFBundleShortVersionString"), plist_string(&text, "CFBundleIdentifier")) {
        (Some(version), Some(id)) if output.status.success() => Ok((version, id)),
        _ => Err(format!("{} holds no {APP_NAME} with a version", zip.display())),
    }
}

fn run(program: &str, args: &[&std::ffi::OsStr]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot run {program}: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let said = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(format!("{program} exited with {}: {said}", output.status))
}

/// Unpack the app from `zip` into `to`, unless the same version is there already. The new copy is unpacked beside
/// it, its signature verified, and then swapped in, so a failure leaves the old copy as it was.
pub fn install(zip: &Path, to: &Path) -> Result<String, String> {
    let (version, id) = zip_info(zip)?;
    if id != BUNDLE_ID {
        return Err(format!("{} holds {id}, not {BUNDLE_ID}", zip.display()));
    }
    let current = installed_version(to);
    if current.as_deref() == Some(version.as_str()) {
        return Ok(format!("unchanged ({version})"));
    }
    let parent = to.parent().ok_or("no parent directory")?;
    fs::create_dir_all(parent).map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
    let staging = parent.join(format!(".mycroft-hands-{}", std::process::id()));
    let _ = fs::remove_dir_all(&staging);
    let result = (|| {
        fs::create_dir_all(&staging).map_err(|error| error.to_string())?;
        run("ditto", &["-x".as_ref(), "-k".as_ref(), zip.as_os_str(), staging.as_os_str()])?;
        let unpacked = staging.join(APP_NAME);
        if installed_version(&unpacked).as_deref() != Some(version.as_str()) {
            return Err(format!("{} did not unpack to {APP_NAME}", zip.display()));
        }
        run("codesign", &["--verify".as_ref(), "--strict".as_ref(), unpacked.as_os_str()])
            .map_err(|error| format!("{APP_NAME} from {} fails its signature check: {error}", zip.display()))?;
        if to.exists() {
            fs::rename(to, staging.join("previous.app")).map_err(|error| format!("cannot move the old copy: {error}"))?;
        }
        fs::rename(&unpacked, to).map_err(|error| format!("cannot move {APP_NAME} into place: {error}"))
    })();
    let _ = fs::remove_dir_all(&staging);
    result?;
    Ok(match current {
        Some(old) => format!("replaced {old} with {version}"),
        None => format!("installed {version}"),
    })
}

/// Open the app to ask for its permissions, each in turn, or only `only` (`accessibility`, `screen-recording`).
/// Returns at once; the app keeps asking for `wait` seconds.
pub fn request_permissions(app: &Path, only: Option<&str>, wait: u64) -> Result<(), String> {
    if !app.exists() {
        return Err(format!("{} is not installed", app.display()));
    }
    let wait = wait.to_string();
    let mut args: Vec<&std::ffi::OsStr> =
        vec!["-n".as_ref(), app.as_os_str(), "--args".as_ref(), "--request-permissions".as_ref()];
    if let Some(only) = only {
        args.extend::<[&std::ffi::OsStr; 2]>(["--only".as_ref(), only.as_ref()]);
    }
    args.extend::<[&std::ffi::OsStr; 2]>(["--wait".as_ref(), wait.as_ref()]);
    run("open", &args)
}

/// The helper's ping, waiting up to `patience` for a helper that is still starting.
pub fn ping_within(patience: Duration) -> Option<ui::Helper> {
    let deadline = Instant::now() + patience;
    loop {
        if let Some(helper) = ui::ping() {
            return Some(helper);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(250));
    }
}

pub fn granted(helper: &ui::Helper) -> bool {
    helper.trusted && helper.screen_recording
}

fn yes(value: bool) -> &'static str {
    if value { "granted" } else { "NOT granted" }
}

/// One line for `hands doctor`.
pub fn describe(helper: &Option<ui::Helper>) -> String {
    match helper {
        Some(helper) => format!(
            "Mycroft Hands {}: accessibility {}, screen recording {}",
            helper.version,
            yes(helper.trusted),
            yes(helper.screen_recording)
        ),
        None if app_path().exists() => format!(
            "not answering on {} ({} is installed; its LaunchAgent {LABEL} starts it in the GUI session)",
            ui::socket().display(),
            APP_NAME
        ),
        None => "not installed (`hands install --desktop-zip MycroftHands.zip`)".into(),
    }
}

const USAGE: &str = "usage: hands desktop permissions [--request] [--wait <SECONDS>] [--json]";

/// `hands desktop permissions [--request] [--wait N] [--json]`: what the running helper (whose permissions are the
/// ones that count) reports; with `--request`, open the app to ask, then wait until both are granted.
pub fn main(args: &[String]) -> i32 {
    let (mut request, mut json_output, mut wait) = (false, false, DEFAULT_WAIT_SECS);
    let Some((first, rest)) = args.split_first() else {
        eprintln!("{USAGE}");
        return 2;
    };
    if first != "permissions" {
        eprintln!("{USAGE}");
        return 2;
    }
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--request" => request = true,
            "--json" => json_output = true,
            "--wait" => match rest.next().and_then(|value| value.parse::<u64>().ok()).filter(|&value| value <= 3600) {
                Some(value) => wait = value,
                None => {
                    eprintln!("hands desktop: --wait needs a number of seconds (0-3600)");
                    return 2;
                }
            },
            _ => {
                eprintln!("{USAGE}");
                return 2;
            }
        }
    }
    if !cfg!(target_os = "macos") {
        eprintln!("hands desktop: desktop control needs macOS");
        return 1;
    }
    let mut helper = ui::ping();
    if request && !helper.as_ref().is_some_and(granted) {
        if let Err(error) = request_permissions(&app_path(), None, wait) {
            eprintln!("hands desktop: {error}");
            return 1;
        }
        if !json_output {
            println!("Approve \"Mycroft Hands\" for Accessibility and Screen Recording in the dialogs or System Settings.");
        }
        let deadline = Instant::now() + Duration::from_secs(wait);
        while !helper.as_ref().is_some_and(granted) && Instant::now() < deadline {
            thread::sleep(Duration::from_secs(1));
            // The app restarts the helper once both are granted, so a missed ping keeps the last answer.
            helper = ui::ping().or(helper);
        }
    }
    let ok = helper.as_ref().is_some_and(granted);
    if json_output {
        let report = match &helper {
            Some(helper) => json!({
                "helper": true,
                "version": helper.version,
                "accessibility": helper.trusted,
                "screenRecording": helper.screen_recording,
            }),
            None => json!({ "helper": false, "accessibility": null, "screenRecording": null }),
        };
        println!("{report}");
    } else {
        match &helper {
            Some(helper) => {
                println!("accessibility:     {}", yes(helper.trusted));
                println!("screen recording:  {}", yes(helper.screen_recording));
                if !ok && !request {
                    println!("Ask for them with: hands desktop permissions --request");
                }
            }
            None => println!("unknown: {}", describe(&None)),
        }
    }
    if ok { 0 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_agent_runs_the_app_binary_with_the_state_dir() {
        let plist = launch_agent(
            Path::new("/Users/a & b/Applications/Mycroft Hands.app/Contents/MacOS/hands-desktop"),
            Path::new("/Users/a & b/Library/Application Support/hands"),
        );
        assert!(!plist.contains("{{") && !plist.contains("Placeholders"), "{plist}");
        assert!(plist.contains("<string>dev.mycroft.hands-desktop</string>"));
        assert!(plist.contains(
            "<string>/Users/a &amp; b/Applications/Mycroft Hands.app/Contents/MacOS/hands-desktop</string>\n\t\t<string>serve</string>"
        ));
        assert!(plist.contains(
            "<key>HANDS_STATE_DIR</key>\n\t\t<string>/Users/a &amp; b/Library/Application Support/hands</string>"
        ));
        assert!(plist.contains("<string>Aqua</string>"));
        if Path::new("/usr/bin/plutil").exists() {
            let file = std::env::temp_dir().join(format!("hands-desktop-test-{}.plist", std::process::id()));
            fs::write(&file, &plist).unwrap();
            let lint = Command::new("/usr/bin/plutil").arg("-lint").arg(&file).output().unwrap();
            let _ = fs::remove_file(&file);
            assert!(lint.status.success(), "{}", String::from_utf8_lossy(&lint.stdout));
        }
    }

    /// A stub Mycroft Hands.app (`/usr/bin/true` as its binary), signed ad hoc and zipped as build.sh does, in a
    /// temporary directory. Nothing is installed outside it.
    fn stub_zip(dir: &Path, version: &str, id: &str, tamper: bool) -> PathBuf {
        let source = dir.join(format!("src-{version}-{id}-{tamper}"));
        let app = source.join(APP_NAME);
        fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        fs::write(
            app.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\
                 \t<key>CFBundleIdentifier</key>\n\t<string>{id}</string>\n\
                 \t<key>CFBundleExecutable</key>\n\t<string>hands-desktop</string>\n\
                 \t<key>CFBundleShortVersionString</key>\n\t<string>{version}</string>\n</dict>\n</plist>\n"
            ),
        )
        .unwrap();
        fs::copy("/usr/bin/true", app_binary(&app)).unwrap();
        let signed = Command::new("codesign")
            .args(["--force", "--sign", "-", "--identifier", id])
            .arg(&app)
            .output()
            .unwrap();
        assert!(signed.status.success(), "{}", String::from_utf8_lossy(&signed.stderr));
        if tamper {
            fs::write(app.join("Contents/Info.plist"), fs::read_to_string(app.join("Contents/Info.plist")).unwrap() + " ")
                .unwrap();
        }
        let zip = dir.join(format!("{version}-{id}-{tamper}.zip"));
        let zipped = Command::new("ditto").args(["-c", "-k", "--keepParent"]).arg(&app).arg(&zip).status().unwrap();
        assert!(zipped.success());
        zip
    }

    #[test]
    fn installs_replaces_only_a_different_version_and_checks_the_signature() {
        if !cfg!(target_os = "macos") || !Path::new("/usr/bin/codesign").exists() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("hands-app-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let to = dir.join("Applications").join(APP_NAME);

        let first = stub_zip(&dir, "0.2.0", BUNDLE_ID, false);
        assert_eq!(zip_info(&first).unwrap(), ("0.2.0".to_string(), BUNDLE_ID.to_string()));
        assert_eq!(install(&first, &to).unwrap(), "installed 0.2.0");
        assert_eq!(installed_version(&to).as_deref(), Some("0.2.0"));
        assert!(app_binary(&to).is_file());
        assert_eq!(install(&first, &to).unwrap(), "unchanged (0.2.0)");

        let wrong = stub_zip(&dir, "0.3.0", "com.example.other", false);
        assert!(install(&wrong, &to).unwrap_err().contains("not dev.mycroft.hands-desktop"));
        let tampered = stub_zip(&dir, "0.3.0", BUNDLE_ID, true);
        assert!(install(&tampered, &to).unwrap_err().contains("signature"));
        assert_eq!(installed_version(&to).as_deref(), Some("0.2.0"), "a failed install changed the app");

        let second = stub_zip(&dir, "0.3.0", BUNDLE_ID, false);
        assert_eq!(install(&second, &to).unwrap(), "replaced 0.2.0 with 0.3.0");
        assert_eq!(installed_version(&to).as_deref(), Some("0.3.0"));
        // Only the app is left: no staging directories or previous copies.
        let left: Vec<_> = fs::read_dir(to.parent().unwrap()).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        assert_eq!(left, [std::ffi::OsString::from(APP_NAME)]);
        assert!(zip_info(&dir.join("missing.zip")).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn reads_plist_strings() {
        let text = "<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>dev.mycroft.hands-desktop</string>\n\
                    \t<key>CFBundleShortVersionString</key>\n\t<string> 0.2.0 </string>\n</dict>";
        assert_eq!(plist_string(text, "CFBundleShortVersionString").as_deref(), Some("0.2.0"));
        assert_eq!(plist_string(text, "CFBundleIdentifier").as_deref(), Some(BUNDLE_ID));
        assert_eq!(plist_string(text, "CFBundleVersion"), None);
    }
}
