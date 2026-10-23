//! The walkthrough of `hands permissions` (mod.rs): one item at a time on the terminal, asking macOS through the
//! service's supervisor and waiting until it's granted or the user presses Enter.

use super::{Item, Mac, RealMac, Status, remember_asked};
use crate::supervisor;
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

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
pub fn walkthrough(tty: &mut Tty) -> i32 {
    tty.line("Mycroft needs a few permissions on this Mac. macOS asks for each one; approve them one at a time.");
    tty.line("Press Enter to skip a step, Ctrl-C to stop. `hands permissions` comes back to this any time.");
    tty.line("");
    // Every permission is asked for by the service: without it, say so and stop.
    let hello = supervisor::call_running(&json!({ "op": "hello" })).ok().map(|(hello, _)| hello);
    if !hello.as_ref().is_some_and(|hello| hello["service"].as_bool() == Some(true)) {
        tty.line(match hello.as_ref().map(|hello| hello["service"].as_bool()) {
            Some(None) => "The running hands service is older than this hands, so it can't ask macOS yet.",
            Some(Some(_)) => "hands runs from a terminal rather than as the service, so it can't ask macOS yet.",
            None => "The hands service isn't running, so macOS can't be asked yet.",
        });
        tty.line("Run `hands install`, then `hands permissions` again.");
        return 1;
    }
    let mac: Arc<dyn Mac> = Arc::new(RealMac { restart: true });
    let outcomes = walk(mac, tty, &Item::ALL, &Timing::default());
    remember_asked(&Item::ALL);
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
        assert!(console.lines.iter().any(|line| line.contains("turn on \"hands\" under Accessibility")));
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
            (Item::ScreenRecording, vec![Status::Unknown("the hands service isn't running".into())]),
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
}
