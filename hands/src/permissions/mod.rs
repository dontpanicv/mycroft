//! `hands permissions [--check] [--json]`: what macOS must approve so Mycroft can work on this Mac, asked one at a
//! time in the terminal. `hands install` runs the same walkthrough after pairing.
//!
//! macOS gives a permission to the process that asks for it, or rather to its *responsible* process. Run from
//! Terminal, that is Terminal. So the terminal only drives and reports, and every permission belongs to the service's
//! supervisor: Started by launchd, it is its own responsible process, so macOS asks about "hands", and the answer
//! covers the desktop control it runs (cua.rs) and every command it runs later. The walkthrough asks the supervisor
//! (the `access` op) to ask macOS for Accessibility or Screen Recording, open a folder, send one packet to the router,
//! or read a protected file. A supervisor started from a terminal refuses: macOS would ask about the terminal instead.
//!
//! macOS tells a process about a new Screen Recording grant only once it restarts. So the supervisor checks both
//! desktop permissions in a fresh child (`hands permissions --probe <item>`), which macOS also counts as hands, and
//! says whether it sees the grant itself (`applied`). When it doesn't, the walkthrough restarts the service, whether
//! the grant is new or older than the service.
//!
//! Checking a folder or the local network the first time makes macOS ask. So `--check` only looks at the ones a
//! walkthrough has asked about before (`permissions.json` in the state dir) and reports the rest as not asked yet.
//!
//! The walkthrough itself, one item at a time on the terminal, is in walkthrough.rs. On Linux there is nothing to
//! approve: hands runs as the user. `hands permissions` reports what keeps it running instead: the service and
//! lingering (linux.rs).

mod linux;
mod walkthrough;

pub use linux::linger;
use walkthrough::{Console, Tty};

use crate::errors::Failure;
use crate::{install, state, supervisor};
use serde_json::{Map, Value, json};
use std::fs::{self, File};
use std::io;
use std::net::{Ipv4Addr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Readable only with Full Disk Access, and present on every Mac.
const PROTECTED_FILE: &str = "/Library/Application Support/com.apple.TCC/TCC.db";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Item {
    Accessibility,
    ScreenRecording,
    Desktop,
    Documents,
    Downloads,
    LocalNetwork,
    FullDisk,
}

/// What the walkthrough says and does about one [`Item`].
struct ItemSpec {
    item: Item,
    /// In `permissions.json`, `--json` and the supervisor's `access` op.
    key: &'static str,
    title: &'static str,
    purpose: &'static str,
    /// Checking it the first time makes macOS ask.
    prompts: bool,
    /// What to do while the walkthrough waits.
    how: &'static str,
    /// Where to turn it on when macOS doesn't ask (because it was answered before).
    fallback: Option<&'static str>,
    /// The System Settings pane.
    pane: &'static str,
}

const FOLDER_PURPOSE: &str = "commands Mycroft runs can read and change files there";
const FOLDER_HOW: &str = "Click Allow when macOS asks whether \"hands\" may access it.";
const FOLDER_FALLBACK: Option<&str> = Some(
    "No prompt? It was answered before: turn on \"hands\" under Files and Folders in System Settings, which is open \
     now.",
);

/// In walkthrough order.
const SPECS: [ItemSpec; 7] = [
    ItemSpec {
        item: Item::Accessibility,
        key: "accessibility",
        title: "Accessibility",
        purpose: "read and use apps' buttons, menus and fields",
        prompts: false,
        how: "When macOS asks, click Open System Settings and turn on \"hands\" under Accessibility.",
        fallback: Some(
            "No prompt? It was answered before: turn on \"hands\" under Accessibility in System Settings, which is \
             open now. Already on? That was an older hands: remove it with −, then run `hands permissions` again.",
        ),
        pane: "Privacy_Accessibility",
    },
    ItemSpec {
        item: Item::ScreenRecording,
        key: "screenRecording",
        title: "Screen Recording",
        purpose: "see app windows when Mycroft looks at them",
        prompts: false,
        how: "When macOS asks, click Open System Settings and turn on \"hands\" under Screen & System Audio \
              Recording. hands restarts by itself afterwards.",
        fallback: Some(
            "No prompt? It was answered before: turn on \"hands\" under Screen & System Audio Recording in System \
             Settings, which is open now. Already on? That was an older hands: remove it with −, then run \
             `hands permissions` again.",
        ),
        pane: "Privacy_ScreenCapture",
    },
    ItemSpec {
        item: Item::Desktop,
        key: "desktop",
        title: "Desktop folder",
        purpose: FOLDER_PURPOSE,
        prompts: true,
        how: FOLDER_HOW,
        fallback: FOLDER_FALLBACK,
        pane: "Privacy_FilesAndFolders",
    },
    ItemSpec {
        item: Item::Documents,
        key: "documents",
        title: "Documents folder",
        purpose: FOLDER_PURPOSE,
        prompts: true,
        how: FOLDER_HOW,
        fallback: FOLDER_FALLBACK,
        pane: "Privacy_FilesAndFolders",
    },
    ItemSpec {
        item: Item::Downloads,
        key: "downloads",
        title: "Downloads folder",
        purpose: FOLDER_PURPOSE,
        prompts: true,
        how: FOLDER_HOW,
        fallback: FOLDER_FALLBACK,
        pane: "Privacy_FilesAndFolders",
    },
    ItemSpec {
        item: Item::LocalNetwork,
        key: "localNetwork",
        title: "Local Network",
        purpose: "commands can reach other devices on your network",
        prompts: true,
        how: "Click Allow when macOS asks whether \"hands\" may find devices on your local network.",
        fallback: Some(
            "No prompt? It was answered before: turn on \"hands\" under Local Network in System Settings, which is \
             open now.",
        ),
        pane: "Privacy_LocalNetwork",
    },
    ItemSpec {
        item: Item::FullDisk,
        key: "fullDisk",
        title: "Full Disk Access",
        purpose: "everything else: iCloud Drive, external disks, other apps' data",
        prompts: false,
        how: "macOS has no prompt for this one. Drag \"hands\" from the Finder window into the list in System \
              Settings, then turn it on.",
        fallback: None,
        pane: "Privacy_AllFiles",
    },
];

impl Item {
    pub const ALL: [Item; 7] = [
        Item::Accessibility,
        Item::ScreenRecording,
        Item::Desktop,
        Item::Documents,
        Item::Downloads,
        Item::LocalNetwork,
        Item::FullDisk,
    ];

    fn spec(self) -> &'static ItemSpec {
        SPECS.iter().find(|spec| spec.item == self).expect("every item has a spec")
    }

    pub fn key(self) -> &'static str {
        self.spec().key
    }

    fn from_key(key: &str) -> Option<Item> {
        SPECS.iter().find(|spec| spec.key == key).map(|spec| spec.item)
    }

    pub fn title(self) -> &'static str {
        self.spec().title
    }

    fn purpose(self) -> &'static str {
        self.spec().purpose
    }

    fn optional(self) -> bool {
        self == Item::FullDisk
    }

    fn prompts(self) -> bool {
        self.spec().prompts
    }

    fn how(self) -> &'static str {
        self.spec().how
    }

    fn fallback(self) -> Option<&'static str> {
        self.spec().fallback
    }

    fn pane(self) -> &'static str {
        self.spec().pane
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    Granted,
    Missing,
    /// Doesn't apply on this Mac, and why.
    NotApplicable(String),
    /// Can't tell now, and why.
    Unknown(String),
    /// Not checked, because checking would make macOS ask.
    NotAsked,
}

impl Status {
    fn word(&self) -> String {
        match self {
            Status::Granted => "granted".into(),
            Status::Missing => "not granted".into(),
            Status::NotApplicable(why) => format!("not needed ({why})"),
            Status::Unknown(why) => format!("unknown ({why})"),
            Status::NotAsked => "not asked yet".into(),
        }
    }

    fn key(&self) -> &'static str {
        match self {
            Status::Granted => "granted",
            Status::Missing => "missing",
            Status::NotApplicable(_) => "notApplicable",
            Status::Unknown(_) => "unknown",
            Status::NotAsked => "notAsked",
        }
    }
}

// MARK: The service's side: the `access` op.

/// This process was started by the service manager (launchd or systemd), so macOS asks about hands itself.
pub fn in_service() -> bool {
    if cfg!(target_os = "macos") {
        std::env::var("XPC_SERVICE_NAME").is_ok_and(|name| name == install::LABEL)
    } else {
        std::env::var_os("INVOCATION_ID").is_some()
    }
}

/// The supervisor's `access` op: `{ what, ask? }` → `{ granted }`, or `{ notApplicable: why }`. With `ask`, macOS
/// first asks for Accessibility or Screen Recording.
pub fn access(json: &Value) -> Result<Value, Failure> {
    let what = json["what"].as_str().unwrap_or_default();
    let item =
        Item::from_key(what).ok_or_else(|| Failure::new("EINVAL", format!("access: unknown permission {what:?}")))?;
    if !cfg!(target_os = "macos") {
        return Ok(json!({ "notApplicable": "only macOS asks" }));
    }
    if !in_service() {
        return Err(Failure::new(
            "not_service",
            "this supervisor was started from a terminal, so macOS would ask about the terminal instead of hands; \
             `hands install` sets up the service that should run it",
        ));
    }
    let home = PathBuf::from(crate::sys::home());
    let result = match item {
        Item::Desktop => folder(&home.join("Desktop")),
        Item::Documents => folder(&home.join("Documents")),
        Item::Downloads => folder(&home.join("Downloads")),
        Item::FullDisk => readable(Path::new(PROTECTED_FILE)),
        Item::LocalNetwork => local_network(),
        Item::Accessibility | Item::ScreenRecording => {
            if json["ask"].as_bool() == Some(true) {
                tcc::ask(item);
            }
            probe(item)
        }
    };
    Ok(match result {
        // `applied`: whether this process sees the grant too; it sees a new Screen Recording grant only once it
        // restarts.
        Ok(granted) if matches!(item, Item::Accessibility | Item::ScreenRecording) => {
            json!({ "granted": granted, "applied": tcc::granted(item) })
        }
        Ok(granted) => json!({ "granted": granted }),
        Err(why) => json!({ "notApplicable": why }),
    })
}

/// Whether hands has Accessibility or Screen Recording, as a fresh `hands permissions --probe` sees it.
fn probe(item: Item) -> Result<bool, String> {
    let binary = std::env::current_exe().map_err(|error| error.to_string())?;
    let output = Command::new(binary)
        .args(["permissions", "--probe", item.key()])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("cannot run hands: {error}"))?;
    match String::from_utf8_lossy(&output.stdout).trim() {
        "granted" => Ok(true),
        "missing" => Ok(false),
        other => Err(format!("the probe answered {other:?}")),
    }
}

/// macOS's own calls for the two desktop permissions; they act for this process's responsible one.
#[cfg(target_os = "macos")]
mod tcc {
    use super::Item;
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::string::CFString;

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn AXIsProcessTrusted() -> bool;
        fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGPreflightScreenCaptureAccess() -> bool;
        fn CGRequestScreenCaptureAccess() -> bool;
    }

    pub fn granted(item: Item) -> bool {
        // SAFETY: plain queries without arguments.
        unsafe {
            match item {
                Item::ScreenRecording => CGPreflightScreenCaptureAccess(),
                _ => AXIsProcessTrusted(),
            }
        }
    }

    /// Make macOS ask, once; later it only reports.
    pub fn ask(item: Item) {
        if item == Item::ScreenRecording {
            // SAFETY: no arguments; shows macOS's prompt the first time.
            unsafe { CGRequestScreenCaptureAccess() };
            return;
        }
        let prompt = CFString::new("AXTrustedCheckOptionPrompt");
        let options = CFDictionary::from_CFType_pairs(&[(prompt.as_CFType(), CFBoolean::true_value().as_CFType())]);
        // SAFETY: a valid dictionary, alive for the call.
        unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) };
    }
}

#[cfg(not(target_os = "macos"))]
mod tcc {
    use super::Item;

    pub fn granted(_: Item) -> bool {
        false
    }

    pub fn ask(_: Item) {}
}

fn denied(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::EPERM | libc::EACCES))
}

/// Opening the folder is what makes macOS ask, the first time.
fn folder(path: &Path) -> Result<bool, String> {
    match fs::read_dir(path) {
        Ok(_) => Ok(true),
        Err(error) if denied(&error) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Err(format!("there is no {}", path.display())),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

fn readable(path: &Path) -> Result<bool, String> {
    match File::open(path) {
        Ok(_) => Ok(true),
        Err(error) if denied(&error) => Ok(false),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

/// One UDP packet to the router: refused with EHOSTUNREACH until Local Network is allowed, and what makes macOS ask.
fn local_network() -> Result<bool, String> {
    if macos_major().is_some_and(|major| major < 15) {
        return Err("macOS asks for it from version 15".into());
    }
    let router = router().ok_or("this Mac is not on a local network right now")?;
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|error| error.to_string())?;
    match socket.connect((router, 9)).and_then(|()| socket.send(&[0])) {
        Ok(_) => Ok(true),
        Err(error) if error.raw_os_error() == Some(libc::EHOSTUNREACH) => Ok(false),
        Err(error) => Err(format!("cannot reach the router at {router}: {error}")),
    }
}

fn output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn macos_major() -> Option<u32> {
    output("sw_vers", &["-productVersion"])?.trim().split('.').next()?.parse().ok()
}

/// The router of the default route, unless that leads into a VPN tunnel; then the Wi-Fi or Ethernet router.
fn router() -> Option<Ipv4Addr> {
    if let Some(route) = output("route", &["-n", "get", "default"])
        && let Some(router) = parse_route(&route)
    {
        return Some(router);
    }
    ["en0", "en1", "en2"]
        .into_iter()
        .find_map(|interface| output("ipconfig", &["getoption", interface, "router"])?.trim().parse().ok())
}

/// `route -n get default`'s gateway, when its interface is a LAN one (`en*`, `bridge*`).
fn parse_route(text: &str) -> Option<Ipv4Addr> {
    let field = |name: &str| {
        text.lines().find_map(|line| line.trim().strip_prefix(name).map(|rest| rest.trim().to_string()))
    };
    let interface = field("interface:")?;
    if !(interface.starts_with("en") || interface.starts_with("bridge")) {
        return None;
    }
    field("gateway:")?.parse().ok()
}

// MARK: The terminal's side.

/// How the walkthrough reads and asks. [`RealMac`] in use; a fake in the tests.
pub trait Mac: Send + Sync {
    fn check(&self, item: Item) -> Status;
    /// Start asking: the app's prompt, or Finder and System Settings. Folders and Local Network are asked by
    /// checking them.
    fn ask(&self, item: Item) -> Result<(), String>;
    fn open_settings(&self, item: Item);
}

/// `restart`: in the walkthrough, a service that doesn't see a grant yet is restarted, so that it does.
pub struct RealMac {
    pub restart: bool,
}

impl Mac for RealMac {
    fn check(&self, item: Item) -> Status {
        let request = json!({ "op": "access", "what": item.key() });
        let reply = supervisor::call_running(&request);
        if self.restart
            && let Ok((reply, _)) = &reply
            && reply["granted"] == true
            && reply["applied"] == false
        {
            restart_service();
            return access_status(supervisor::call_running(&request));
        }
        access_status(reply)
    }

    fn ask(&self, item: Item) -> Result<(), String> {
        match item {
            Item::Accessibility | Item::ScreenRecording => {
                match access_status(supervisor::call_running(&json!({ "op": "access", "what": item.key(), "ask": true }))) {
                    Status::Unknown(why) => Err(why),
                    _ => Ok(()),
                }
            }
            Item::FullDisk => {
                self.open_settings(item);
                // ~/.local is hidden in Finder: show the binary itself, ready to drag.
                open(&["-R".as_ref(), install::binary_path().as_os_str()])
            }
            _ => Ok(()),
        }
    }

    fn open_settings(&self, item: Item) {
        let _ = open(&[format!("x-apple.systempreferences:com.apple.preference.security?{}", item.pane()).as_ref()]);
    }
}

/// Restart the service (the supervisor's `shutdown`; launchd starts it again at once), and wait until it's back.
/// Running jobs are not affected.
fn restart_service() {
    let hello = json!({ "op": "hello" });
    let pid = |reply: Result<(Value, Vec<u8>), Failure>| reply.ok().and_then(|(hello, _)| hello["pid"].as_u64());
    let before = pid(supervisor::call_running(&hello));
    let _ = supervisor::call_running(&json!({ "op": "shutdown" }));
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(250));
        if pid(supervisor::call_running(&hello)).is_some_and(|now| Some(now) != before) {
            return;
        }
    }
}

/// The supervisor's answer to an `access` request.
fn access_status(reply: Result<(Value, Vec<u8>), Failure>) -> Status {
    match reply {
        Ok((reply, _)) => match (reply["granted"].as_bool(), reply["notApplicable"].as_str()) {
            (Some(value), _) => granted(value),
            (None, Some(why)) => Status::NotApplicable(why.to_string()),
            _ => Status::Unknown(format!("the service answered {reply}")),
        },
        Err(failure) if failure.code == "supervisor_unavailable" => {
            Status::Unknown("the hands service isn't running (`hands install` sets it up)".into())
        }
        Err(failure) if failure.code == "EINVAL" => {
            Status::Unknown("the running hands service is older; restart it with `hands install`".into())
        }
        Err(failure) => Status::Unknown(failure.message),
    }
}

fn granted(value: bool) -> Status {
    if value { Status::Granted } else { Status::Missing }
}

fn open(args: &[&std::ffi::OsStr]) -> Result<(), String> {
    let status = Command::new("open")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| format!("cannot run open: {error}"))?;
    if status.success() { Ok(()) } else { Err(format!("open exited with {status}")) }
}

/// The prompted items a walkthrough has asked about, so `--check` may check them without making macOS ask.
fn asked_file() -> PathBuf {
    state::dir().join("permissions.json")
}

fn asked() -> Vec<String> {
    fs::read(asked_file())
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value["asked"].as_array().cloned())
        .map(|keys| keys.iter().filter_map(|key| key.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

fn remember_asked(items: &[Item]) {
    let mut keys = asked();
    for item in items.iter().filter(|item| item.prompts()) {
        if !keys.iter().any(|key| key == item.key()) {
            keys.push(item.key().to_string());
        }
    }
    if state::ensure().is_ok() {
        let _ = fs::write(asked_file(), json!({ "asked": keys }).to_string());
    }
}

/// Every item's status, without making macOS ask about any.
pub fn report(mac: &dyn Mac) -> Vec<(Item, Status)> {
    let asked = asked();
    Item::ALL
        .into_iter()
        .map(|item| {
            let status = if item.prompts() && !asked.iter().any(|key| key == item.key()) {
                Status::NotAsked
            } else {
                mac.check(item)
            };
            (item, status)
        })
        .collect()
}

/// After `hands install`: the walkthrough on macOS when there's a terminal to talk to, otherwise one line saying how
/// to get to it. On Linux, one line when hands would stop at logout.
pub fn after_install() {
    if cfg!(target_os = "macos") {
        match Tty::open() {
            Some(mut tty) => {
                tty.line("");
                walkthrough::walkthrough(&mut tty);
            }
            None => println!("Mycroft needs a few permissions on this Mac: run `hands permissions` here to approve them."),
        }
    } else if linger().is_some_and(|linger| linger != "yes") {
        println!("hands stops when you log out. To keep it running, run: sudo loginctl enable-linger $USER");
    }
}

const USAGE: &str = "usage: hands permissions [--check] [--json]";

/// `hands permissions [--check] [--json]`.
pub fn main(args: &[String]) -> i32 {
    // The supervisor's fresh look at a desktop permission (`probe`).
    if let [flag, key] = args
        && flag == "--probe"
        && let Some(item) = Item::from_key(key)
    {
        println!("{}", if tcc::granted(item) { "granted" } else { "missing" });
        return 0;
    }
    let (mut check, mut json_output) = (false, false);
    for arg in args {
        match arg.as_str() {
            "--check" => check = true,
            "--json" => json_output = true,
            _ => {
                eprintln!("{USAGE}");
                return 2;
            }
        }
    }
    if !cfg!(target_os = "macos") {
        return linux::report(json_output);
    }
    if !check && !json_output
        && let Some(mut tty) = Tty::open()
    {
        return walkthrough::walkthrough(&mut tty);
    }
    let statuses = report(&RealMac { restart: false });
    if json_output {
        let mut object = Map::new();
        for (item, status) in &statuses {
            let mut entry = json!({ "status": status.key() });
            if let Status::NotApplicable(why) | Status::Unknown(why) = status {
                entry["reason"] = json!(why);
            }
            object.insert(item.key().into(), entry);
        }
        println!("{}", Value::Object(object));
    } else {
        for (item, status) in &statuses {
            println!("{:<20} {}", item.title(), status.word());
        }
    }
    let missing = statuses
        .iter()
        .any(|(item, status)| !item.optional() && matches!(status, Status::Missing | Status::NotAsked));
    if missing && !json_output {
        println!("Approve them with: hands permissions");
    }
    if missing { 1 } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_lan_router() {
        let wifi = "   route to: default\ndestination: default\n       mask: default\n    gateway: 10.12.201.1\n  interface: en0\n";
        assert_eq!(parse_route(wifi), Some(Ipv4Addr::new(10, 12, 201, 1)));
        let vpn = "    gateway: 100.64.0.1\n  interface: utun4\n";
        assert_eq!(parse_route(vpn), None);
        assert_eq!(parse_route("  interface: en0\n"), None);
    }

    #[test]
    fn access_refuses_outside_the_service_and_unknown_items() {
        assert_eq!(access(&json!({ "what": "nope" })).unwrap_err().code, "EINVAL");
        if cfg!(target_os = "macos") && !in_service() {
            assert_eq!(access(&json!({ "what": "desktop" })).unwrap_err().code, "not_service");
            assert_eq!(access(&json!({ "what": "accessibility", "ask": true })).unwrap_err().code, "not_service");
        }
    }

    #[test]
    fn items_have_distinct_keys_and_round_trip() {
        for item in Item::ALL {
            assert_eq!(Item::from_key(item.key()), Some(item));
        }
        assert_eq!(Item::ALL.iter().filter(|item| item.optional()).count(), 1);
    }
}
