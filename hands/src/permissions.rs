//! `hands permissions [--check] [--json]`: what macOS must approve so Mycroft can work on this Mac, asked one at a
//! time in the terminal. `hands install` runs the same walkthrough after pairing.
//!
//! macOS gives a permission to the process that asks for it, or rather to its *responsible* process. Run from
//! Terminal, that is Terminal. So the terminal only drives and reports:
//!
//! - **Accessibility** and **Screen Recording** belong to Mycroft Hands.app, which does the desktop work. The
//!   walkthrough opens the app to ask for one of them (`--request-permissions --only …`) and follows the helper's
//!   `ping`.
//! - **Desktop, Documents, Downloads**, **Local Network** and **Full Disk Access** belong to `hands` itself, because
//!   the commands Mycroft runs are its children. The walkthrough asks the service's supervisor (the `access` op) to
//!   open the folder, send one packet to the router, or read a protected file. Started by launchd, the service is its
//!   own responsible process, so macOS asks about "hands", and the answer covers every command it runs later. A
//!   supervisor started from a terminal refuses: macOS would ask about the terminal instead.
//!
//! Checking a folder or the local network the first time makes macOS ask. So `--check` only looks at the ones a
//! walkthrough has asked about before (`permissions.json` in the state dir) and reports the rest as not asked yet.
//!
//! On Linux there is nothing to approve: hands runs as the user. `hands permissions` reports what keeps it running
//! instead: the service and lingering.

use crate::errors::Failure;
use crate::ui::app;
use crate::{install, listener, state, supervisor};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, UdpSocket};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

/// Readable only with Full Disk Access, and present on every Mac.
const PROTECTED_FILE: &str = "/Library/Application Support/com.apple.TCC/TCC.db";
/// How long the app keeps asking for one permission after the walkthrough opened it.
const APP_WAIT_SECS: u64 = 900;

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

    pub fn key(self) -> &'static str {
        match self {
            Item::Accessibility => "accessibility",
            Item::ScreenRecording => "screenRecording",
            Item::Desktop => "desktop",
            Item::Documents => "documents",
            Item::Downloads => "downloads",
            Item::LocalNetwork => "localNetwork",
            Item::FullDisk => "fullDisk",
        }
    }

    fn from_key(key: &str) -> Option<Item> {
        Item::ALL.into_iter().find(|item| item.key() == key)
    }

    pub fn title(self) -> &'static str {
        match self {
            Item::Accessibility => "Accessibility",
            Item::ScreenRecording => "Screen Recording",
            Item::Desktop => "Desktop folder",
            Item::Documents => "Documents folder",
            Item::Downloads => "Downloads folder",
            Item::LocalNetwork => "Local Network",
            Item::FullDisk => "Full Disk Access",
        }
    }

    fn purpose(self) -> &'static str {
        match self {
            Item::Accessibility => "read and use apps' buttons, menus and fields",
            Item::ScreenRecording => "see the screen when Mycroft takes a screenshot",
            Item::Desktop | Item::Documents | Item::Downloads => "commands Mycroft runs can read and change files there",
            Item::LocalNetwork => "commands can reach other devices on your network",
            Item::FullDisk => "everything else: iCloud Drive, external disks, other apps' data",
        }
    }

    fn optional(self) -> bool {
        self == Item::FullDisk
    }

    /// Checking it the first time makes macOS ask.
    fn prompts(self) -> bool {
        matches!(self, Item::Desktop | Item::Documents | Item::Downloads | Item::LocalNetwork)
    }

    /// Held by Mycroft Hands.app rather than by hands.
    fn app(self) -> bool {
        matches!(self, Item::Accessibility | Item::ScreenRecording)
    }

    /// What to do while the walkthrough waits.
    fn how(self) -> &'static str {
        match self {
            Item::Accessibility => "Turn on \"Mycroft Hands\" in System Settings, which macOS just opened.",
            Item::ScreenRecording => {
                "Turn on \"Mycroft Hands\" in System Settings, which macOS just opened. If macOS offers to quit and \
                 reopen it, choose Quit & Reopen."
            }
            Item::Desktop | Item::Documents | Item::Downloads => {
                "Click Allow when macOS asks whether \"hands\" may access it."
            }
            Item::LocalNetwork => "Click Allow when macOS asks whether \"hands\" may find devices on your local network.",
            Item::FullDisk => {
                "macOS has no prompt for this one. Drag \"hands\" from the Finder window into the list in System \
                 Settings, then turn it on."
            }
        }
    }

    /// Where to turn it on when macOS doesn't ask (because it was answered before).
    fn fallback(self) -> Option<&'static str> {
        match self {
            Item::Desktop | Item::Documents | Item::Downloads => Some(
                "No prompt? It was answered before: turn on \"hands\" under Files and Folders in System Settings, \
                 which is open now.",
            ),
            Item::LocalNetwork => Some(
                "No prompt? It was answered before: turn on \"hands\" under Local Network in System Settings, which \
                 is open now.",
            ),
            _ => None,
        }
    }

    fn pane(self) -> &'static str {
        match self {
            Item::Accessibility => "Privacy_Accessibility",
            Item::ScreenRecording => "Privacy_ScreenCapture",
            Item::Desktop | Item::Documents | Item::Downloads => "Privacy_FilesAndFolders",
            Item::LocalNetwork => "Privacy_LocalNetwork",
            Item::FullDisk => "Privacy_AllFiles",
        }
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

/// The supervisor's `access` op: `{ what }` → `{ granted }`, or `{ notApplicable: why }`.
pub fn access(json: &Value) -> Result<Value, Failure> {
    let what = json["what"].as_str().unwrap_or_default();
    let item = Item::from_key(what)
        .filter(|item| !item.app())
        .ok_or_else(|| Failure::new("EINVAL", format!("access: unknown permission {what:?}")))?;
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
        Item::Accessibility | Item::ScreenRecording => unreachable!(),
    };
    Ok(match result {
        Ok(granted) => json!({ "granted": granted }),
        Err(why) => json!({ "notApplicable": why }),
    })
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

pub struct RealMac;

impl Mac for RealMac {
    fn check(&self, item: Item) -> Status {
        if item.app() {
            if !app::app_path().exists() {
                return Status::NotApplicable("Mycroft Hands isn't installed, so desktop control is off".into());
            }
            // The helper restarts after Screen Recording is granted; give it a moment to answer again.
            return match app::ping_within(Duration::from_secs(5)) {
                Some(helper) if item == Item::Accessibility => granted(helper.trusted),
                Some(helper) => granted(helper.screen_recording),
                None => Status::Unknown("Mycroft Hands isn't answering; it runs once you're logged in on this Mac".into()),
            };
        }
        match supervisor::call_running(&json!({ "op": "access", "what": item.key() })) {
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

    fn ask(&self, item: Item) -> Result<(), String> {
        match item {
            Item::Accessibility => app::request_permissions(&app::app_path(), Some("accessibility"), APP_WAIT_SECS),
            Item::ScreenRecording => app::request_permissions(&app::app_path(), Some("screen-recording"), APP_WAIT_SECS),
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

/// Where the walkthrough writes, and how it hears Enter.
pub trait Console {
    fn line(&mut self, text: &str);
    /// Shows `text` with a spinner frame and waits up to `wait`; true when the user pressed Enter.
    fn wait(&mut self, text: &str, wait: Duration) -> bool;
    /// Clears the spinner line.
    fn settle(&mut self);
    /// Forgets keys pressed earlier, so an old Enter doesn't skip the next step.
    fn discard_input(&mut self);
}

/// The controlling terminal, even when stdin is the install script (`curl … | sh`).
pub struct Tty {
    file: File,
    frame: usize,
}

impl Tty {
    pub fn open() -> Option<Tty> {
        let file = OpenOptions::new().read(true).write(true).open("/dev/tty").ok()?;
        Some(Tty { file, frame: 0 })
    }
}

const FRAMES: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

impl Console for Tty {
    fn line(&mut self, text: &str) {
        let _ = write!(self.file, "\r\x1b[2K{text}\n");
    }

    fn wait(&mut self, text: &str, wait: Duration) -> bool {
        self.frame = (self.frame + 1) % FRAMES.len();
        let _ = write!(self.file, "\r\x1b[2K      {} {text}", FRAMES[self.frame]);
        let _ = self.file.flush();
        let mut poll = libc::pollfd { fd: self.file.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd for the duration of the call.
        let ready = unsafe { libc::poll(&mut poll, 1, wait.as_millis().min(i32::MAX as u128) as i32) };
        if ready <= 0 || poll.revents & libc::POLLIN == 0 {
            return false;
        }
        // The terminal is in line mode: there is input only once Enter is pressed.
        let mut buffer = [0u8; 256];
        matches!(self.file.read(&mut buffer), Ok(count) if count > 0)
    }

    fn settle(&mut self) {
        let _ = write!(self.file, "\r\x1b[2K");
        let _ = self.file.flush();
    }

    fn discard_input(&mut self) {
        // SAFETY: tcflush only discards queued input on a descriptor we own.
        unsafe { libc::tcflush(self.file.as_raw_fd(), libc::TCIFLUSH) };
    }
}

pub struct Timing {
    /// Between checks while waiting.
    pub poll: Duration,
    /// How long a prompted permission may stay missing before System Settings opens instead.
    pub fallback_after: Duration,
    /// One spinner frame.
    pub tick: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing { poll: Duration::from_millis(1500), fallback_after: Duration::from_secs(8), tick: Duration::from_millis(120) }
    }
}

/// How one item of the walkthrough ended.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Granted,
    AlreadyGranted,
    Skipped,
    NotApplicable(String),
    Unknown(String),
}

fn check_in_background(mac: &Arc<dyn Mac>, item: Item) -> mpsc::Receiver<Status> {
    let (sender, receiver) = mpsc::channel();
    let mac = Arc::clone(mac);
    // A folder check can block until the user answers macOS's prompt; the spinner and Enter keep working meanwhile.
    thread::spawn(move || {
        let _ = sender.send(mac.check(item));
    });
    receiver
}

/// Walks through `items` one at a time: says what each is for, has macOS ask, waits until it's granted or the user
/// presses Enter, then moves on.
pub fn walk(mac: Arc<dyn Mac>, console: &mut dyn Console, items: &[Item], timing: &Timing) -> Vec<(Item, Outcome)> {
    let mut outcomes = Vec::new();
    for (index, &item) in items.iter().enumerate() {
        let optional = if item.optional() { " (optional)" } else { "" };
        console.line(&format!("[{}/{}] {}{optional}: {}", index + 1, items.len(), item.title(), item.purpose()));
        console.discard_input();
        let outcome = walk_one(&mac, console, item, timing);
        console.settle();
        console.line(&match &outcome {
            Outcome::Granted => "      ✓ granted".to_string(),
            Outcome::AlreadyGranted => "      ✓ already granted".to_string(),
            Outcome::Skipped => "      – skipped".to_string(),
            Outcome::NotApplicable(why) => format!("      – not needed: {why}"),
            Outcome::Unknown(why) => format!("      ? can't tell: {why}"),
        });
        outcomes.push((item, outcome));
    }
    outcomes
}

fn walk_one(mac: &Arc<dyn Mac>, console: &mut dyn Console, item: Item, timing: &Timing) -> Outcome {
    let started = Instant::now();
    if item.prompts() {
        // The first check is what makes macOS ask.
        console.line(&format!("      {}", item.how()));
    }
    let mut pending = Some(check_in_background(mac, item));
    let mut next_check = None;
    let (mut first, mut opened) = (true, false);
    loop {
        if let Some(receiver) = &pending {
            match receiver.try_recv() {
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => return Outcome::Unknown("the check failed".into()),
                Ok(status) => {
                    pending = None;
                    match status {
                        Status::Granted if first && started.elapsed() < Duration::from_secs(2) => return Outcome::AlreadyGranted,
                        Status::Granted => return Outcome::Granted,
                        Status::NotApplicable(why) => return Outcome::NotApplicable(why),
                        Status::Unknown(why) => return Outcome::Unknown(why),
                        Status::Missing | Status::NotAsked => {
                            if first && !item.prompts() {
                                if let Err(error) = mac.ask(item) {
                                    return Outcome::Unknown(error);
                                }
                                console.line(&format!("      {}", item.how()));
                            }
                            first = false;
                            if let Some(fallback) = item.fallback()
                                && !opened
                                && started.elapsed() >= timing.fallback_after
                            {
                                mac.open_settings(item);
                                console.settle();
                                console.line(&format!("      {fallback}"));
                                opened = true;
                            }
                            next_check = Some(Instant::now() + timing.poll);
                        }
                    }
                }
            }
        }
        if pending.is_none() && next_check.is_some_and(|at| Instant::now() >= at) {
            pending = Some(check_in_background(mac, item));
        }
        if console.wait("Waiting… (Enter to skip)", timing.tick) {
            return Outcome::Skipped;
        }
    }
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

/// The walkthrough's last lines: what's left, and how to come back to it.
fn summary(outcomes: &[(Item, Outcome)]) -> Vec<String> {
    let left: Vec<Item> = outcomes
        .iter()
        .filter(|(_, outcome)| matches!(outcome, Outcome::Skipped | Outcome::Unknown(_)))
        .map(|(item, _)| *item)
        .collect();
    let required: Vec<&str> = left.iter().filter(|item| !item.optional()).map(|item| item.title()).collect();
    if required.is_empty() {
        let mut line = "All set: Mycroft can use this Mac.".to_string();
        if !left.is_empty() {
            line += " Full Disk Access is still off; add it any time with `hands permissions`.";
        }
        return vec![line];
    }
    vec![format!(
        "Still to approve: {}. Run `hands permissions` on this Mac any time to finish.",
        required.join(", ")
    )]
}

/// The walkthrough on this Mac's terminal. Returns 0 when nothing required is left.
fn walkthrough(tty: &mut Tty) -> i32 {
    tty.line("Mycroft needs a few permissions on this Mac. macOS asks for each one; approve them one at a time.");
    tty.line("Press Enter to skip a step, Ctrl-C to stop. `hands permissions` comes back to this any time.");
    tty.line("");
    // The folders, the network and the disk are asked for by the service: without it, say so once and skip them.
    let hello = supervisor::call_running(&json!({ "op": "hello" })).ok().map(|(hello, _)| hello);
    let service = hello.as_ref().is_some_and(|hello| hello["service"].as_bool() == Some(true));
    let items: Vec<Item> = Item::ALL.into_iter().filter(|item| service || item.app()).collect();
    if !service {
        tty.line(match hello.as_ref().map(|hello| hello["service"].as_bool()) {
            Some(None) => "The running hands service is older than this hands, so it can't ask macOS about the folders,",
            Some(Some(_)) => "hands runs from a terminal rather than as the service, so it can't ask macOS about the folders,",
            None => "The hands service isn't running, so macOS can't be asked about the folders,",
        });
        tty.line("Local Network and Full Disk Access yet. Run `hands install`, then `hands permissions` again.");
        tty.line("");
    }
    let mac: Arc<dyn Mac> = Arc::new(RealMac);
    let mut outcomes = walk(mac, tty, &items, &Timing::default());
    remember_asked(&items);
    outcomes.extend(
        Item::ALL
            .into_iter()
            .filter(|item| !items.contains(item))
            .map(|item| (item, Outcome::Unknown("the hands service isn't running".into()))),
    );
    tty.line("");
    let lines = summary(&outcomes);
    for line in &lines {
        tty.line(line);
    }
    let done = outcomes
        .iter()
        .all(|(item, outcome)| item.optional() || !matches!(outcome, Outcome::Skipped | Outcome::Unknown(_)));
    if done { 0 } else { 1 }
}

/// After `hands install`: the walkthrough on macOS when there's a terminal to talk to, otherwise one line saying how
/// to get to it. On Linux, one line when hands would stop at logout.
pub fn after_install() {
    if cfg!(target_os = "macos") {
        match Tty::open() {
            Some(mut tty) => {
                tty.line("");
                walkthrough(&mut tty);
            }
            None => println!("Mycroft needs a few permissions on this Mac: run `hands permissions` here to approve them."),
        }
    } else if linger().is_some_and(|linger| linger != "yes") {
        println!("hands stops when you log out. To keep it running, run: sudo loginctl enable-linger $USER");
    }
}

/// `loginctl`'s Linger for this user: `yes`, `no`, or `None` without loginctl.
pub fn linger() -> Option<String> {
    let user = std::env::var("USER").unwrap_or_default();
    output("loginctl", &["show-user", &user, "-p", "Linger", "--value"]).map(|text| text.trim().to_string())
}

const USAGE: &str = "usage: hands permissions [--check] [--json]";

/// `hands permissions [--check] [--json]`.
pub fn main(args: &[String]) -> i32 {
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
        return linux_report(json_output);
    }
    if !check && !json_output
        && let Some(mut tty) = Tty::open()
    {
        return walkthrough(&mut tty);
    }
    let statuses = report(&RealMac);
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

fn linux_report(json_output: bool) -> i32 {
    let service = listener::running().is_some();
    let linger = linger();
    let lingers = linger.as_deref().is_none_or(|linger| linger == "yes");
    if json_output {
        println!("{}", json!({ "service": service, "linger": linger }));
    } else {
        println!("Nothing to approve on Linux: hands runs as you, with your user's access.");
        println!(
            "{:<10} {}",
            "service",
            if service { "running" } else { "not running (`hands install` sets it up)" }
        );
        println!(
            "{:<10} {}",
            "linger",
            match linger.as_deref() {
                Some("yes") => "yes: hands keeps running after you log out".to_string(),
                Some(other) => format!("{other}: hands stops at logout (run `sudo loginctl enable-linger $USER`)"),
                None => "unknown (no loginctl)".to_string(),
            }
        );
    }
    if service && lingers { 0 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    /// Scripted answers per item; the last one repeats. Records what was asked and opened.
    struct FakeMac {
        answers: Mutex<Vec<(Item, VecDeque<Status>)>>,
        events: Mutex<Vec<String>>,
    }

    impl FakeMac {
        fn new(answers: Vec<(Item, Vec<Status>)>) -> Arc<FakeMac> {
            Arc::new(FakeMac {
                answers: Mutex::new(answers.into_iter().map(|(item, list)| (item, list.into())).collect()),
                events: Mutex::new(Vec::new()),
            })
        }

        fn events(&self) -> Vec<String> {
            self.events.lock().unwrap().clone()
        }
    }

    impl Mac for FakeMac {
        fn check(&self, item: Item) -> Status {
            let mut answers = self.answers.lock().unwrap();
            let list = &mut answers.iter_mut().find(|(each, _)| *each == item).unwrap().1;
            if list.len() > 1 { list.pop_front().unwrap() } else { list[0].clone() }
        }

        fn ask(&self, item: Item) -> Result<(), String> {
            self.events.lock().unwrap().push(format!("ask {}", item.key()));
            Ok(())
        }

        fn open_settings(&self, item: Item) {
            self.events.lock().unwrap().push(format!("settings {}", item.pane()));
        }
    }

    /// Records lines; `skips` says which waits (by count) press Enter.
    struct FakeConsole {
        lines: Vec<String>,
        waits: usize,
        skip_at: Vec<usize>,
    }

    impl Console for FakeConsole {
        fn line(&mut self, text: &str) {
            self.lines.push(text.to_string());
        }

        fn wait(&mut self, _text: &str, wait: Duration) -> bool {
            thread::sleep(wait);
            self.waits += 1;
            self.skip_at.contains(&self.waits)
        }

        fn settle(&mut self) {}
        fn discard_input(&mut self) {}
    }

    fn fast() -> Timing {
        Timing { poll: Duration::from_millis(5), fallback_after: Duration::from_millis(40), tick: Duration::from_millis(2) }
    }

    fn console(skip_at: Vec<usize>) -> FakeConsole {
        FakeConsole { lines: Vec::new(), waits: 0, skip_at }
    }

    #[test]
    fn asks_one_at_a_time_and_waits_for_each() {
        let mac = FakeMac::new(vec![
            (Item::Accessibility, vec![Status::Missing, Status::Missing, Status::Granted]),
            (Item::ScreenRecording, vec![Status::Granted]),
        ]);
        let mut console = console(vec![]);
        let outcomes = walk(mac.clone(), &mut console, &[Item::Accessibility, Item::ScreenRecording], &fast());
        assert_eq!(outcomes, [(Item::Accessibility, Outcome::Granted), (Item::ScreenRecording, Outcome::AlreadyGranted)]);
        // Screen Recording was already granted: only Accessibility was asked for.
        assert_eq!(mac.events(), ["ask accessibility"]);
        assert_eq!(console.lines[0], "[1/2] Accessibility: read and use apps' buttons, menus and fields");
        assert!(console.lines.iter().any(|line| line.contains("Turn on \"Mycroft Hands\"")));
        assert!(console.lines.iter().any(|line| line.starts_with("[2/2] Screen Recording")));
    }

    #[test]
    fn enter_skips_a_step() {
        let mac = FakeMac::new(vec![(Item::FullDisk, vec![Status::Missing]), (Item::Desktop, vec![Status::Granted])]);
        let mut console = console(vec![3]);
        let outcomes = walk(mac.clone(), &mut console, &[Item::FullDisk, Item::Desktop], &fast());
        assert_eq!(outcomes[0], (Item::FullDisk, Outcome::Skipped));
        assert_eq!(outcomes[1].1, Outcome::AlreadyGranted);
        assert_eq!(mac.events(), ["ask fullDisk"]);
        assert!(console.lines.iter().any(|line| line == "[1/2] Full Disk Access (optional): everything else: iCloud Drive, external disks, other apps' data"));
    }

    #[test]
    fn a_prompt_that_never_comes_opens_system_settings_once() {
        let mac = FakeMac::new(vec![(Item::Documents, vec![Status::Missing; 30].into_iter().chain([Status::Granted]).collect())]);
        let mut console = console(vec![]);
        let outcomes = walk(mac.clone(), &mut console, &[Item::Documents], &fast());
        assert_eq!(outcomes, [(Item::Documents, Outcome::Granted)]);
        // Checking is what asks: no `ask`, and the settings pane opened exactly once.
        assert_eq!(mac.events(), ["settings Privacy_FilesAndFolders"]);
        assert_eq!(console.lines.iter().filter(|line| line.contains("No prompt?")).count(), 1);
        assert!(console.lines[1].contains("Click Allow"), "{:?}", console.lines);
    }

    #[test]
    fn reports_what_doesnt_apply_or_cant_be_told() {
        let mac = FakeMac::new(vec![
            (Item::LocalNetwork, vec![Status::NotApplicable("macOS asks for it from version 15".into())]),
            (Item::ScreenRecording, vec![Status::Unknown("Mycroft Hands isn't answering".into())]),
        ]);
        let mut console = console(vec![]);
        let outcomes = walk(mac.clone(), &mut console, &[Item::LocalNetwork, Item::ScreenRecording], &fast());
        assert!(matches!(outcomes[0].1, Outcome::NotApplicable(_)));
        assert!(matches!(outcomes[1].1, Outcome::Unknown(_)));
        assert!(mac.events().is_empty());
        assert!(console.lines.contains(&"      – not needed: macOS asks for it from version 15".to_string()));
    }

    #[test]
    fn summarises_whats_left() {
        let all_done = [(Item::Accessibility, Outcome::Granted), (Item::FullDisk, Outcome::Skipped)];
        assert_eq!(summary(&all_done), ["All set: Mycroft can use this Mac. Full Disk Access is still off; add it any time with `hands permissions`."]);
        let left = [(Item::Accessibility, Outcome::Skipped), (Item::Desktop, Outcome::Unknown("x".into())), (Item::Documents, Outcome::Granted)];
        assert_eq!(summary(&left), ["Still to approve: Accessibility, Desktop folder. Run `hands permissions` on this Mac any time to finish."]);
    }

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
        assert_eq!(access(&json!({ "what": "accessibility" })).unwrap_err().code, "EINVAL");
        assert_eq!(access(&json!({ "what": "nope" })).unwrap_err().code, "EINVAL");
        if cfg!(target_os = "macos") && !in_service() {
            assert_eq!(access(&json!({ "what": "desktop" })).unwrap_err().code, "not_service");
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
