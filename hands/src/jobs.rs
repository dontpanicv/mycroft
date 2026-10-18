//! Supervised jobs (docs/jobs.md): commands that outlive the connection that started them, keyed by the caller's
//! idempotency key (the brain uses its durable tool-call id, so a replayed tool call reattaches).
//!
//! Each job has a directory under the state dir's `jobs/`:
//! - `job.json`: what was started and how it ended. Never the environment, which may hold secrets.
//! - `output.log`: stdout and stderr combined, written by the job itself, so output survives the supervisor.
//! - `runner.lock` and `exit.json`, below.
//!
//! The supervisor does not run the command itself. It starts `hands __job-runner <dir> -- <program> <args>` as the
//! leader of a new session, so the job is one process group, and the runner starts the command, waits for it and
//! writes `exit.json`. The runner holds `runner.lock` while it lives and ignores the polite signals a cancel sends
//! to the group, so it records the exit status even if the supervisor was restarted meanwhile (an upgrade, a
//! crash). A restarted supervisor adopts running jobs by watching their lock.

use crate::errors::Failure;
use crate::frame::MAX_PAYLOAD;
use crate::serve::now_ms;
use crate::{state, sys};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Finished jobs are deleted after this long...
const RETENTION_MS: u64 = 7 * 24 * 3600 * 1000;
/// ...or when more than this many have finished, oldest first. Running jobs are never deleted.
const MAX_FINISHED: usize = 200;
const MAX_KEY_BYTES: usize = 1024;
const DEFAULT_WAIT_MS: u64 = 30_000;
const DEFAULT_OUTPUT_BYTES: u64 = 1024 * 1024;
/// How often a job adopted from an earlier supervisor is checked.
const ADOPT_POLL: Duration = Duration::from_millis(250);
/// Signals the runner ignores so it outlives a polite cancel and records the exit status; the job gets the default.
const POLITE: [libc::c_int; 4] = [libc::SIGHUP, libc::SIGINT, libc::SIGTERM, libc::SIGQUIT];

#[derive(Clone, Copy, PartialEq, Debug)]
enum JobState {
    Running,
    Exited,
    Failed,
    Cancelled,
}

impl JobState {
    fn name(self) -> &'static str {
        match self {
            JobState::Running => "running",
            JobState::Exited => "exited",
            JobState::Failed => "failed",
            JobState::Cancelled => "cancelled",
        }
    }

    fn parse(name: &str) -> Option<JobState> {
        [
            JobState::Running,
            JobState::Exited,
            JobState::Failed,
            JobState::Cancelled,
        ]
        .into_iter()
        .find(|state| state.name() == name)
    }
}

struct Job {
    key: String,
    dir: PathBuf,
    command: Option<String>,
    argv: Option<Vec<String>>,
    cwd: String,
    state: JobState,
    /// The runner's pid, which is also the job's process group id.
    pid: Option<u32>,
    exit_code: Option<i64>,
    started_at: u64,
    ended_at: Option<u64>,
    error: Option<String>,
    /// The signal a `job.cancel` sent; the job then ends as `cancelled`.
    cancel_signal: Option<i32>,
}

impl Job {
    /// The persisted form (`job.json`).
    fn to_json(&self) -> Value {
        let mut value = json!({
            "key": self.key,
            "cwd": self.cwd,
            "state": self.state.name(),
            "pid": self.pid,
            "exitCode": self.exit_code,
            "startedAt": self.started_at,
            "endedAt": self.ended_at,
        });
        if let Some(command) = &self.command {
            value["command"] = json!(command);
        }
        if let Some(argv) = &self.argv {
            value["argv"] = json!(argv);
        }
        if let Some(error) = &self.error {
            value["error"] = json!(error);
        }
        if let Some(signal) = self.cancel_signal {
            value["cancelSignal"] = json!(signal);
        }
        value
    }

    fn from_json(dir: PathBuf, value: &Value) -> Option<Job> {
        let strings = |value: &Value| -> Option<Vec<String>> {
            value
                .as_array()?
                .iter()
                .map(|item| item.as_str().map(str::to_string))
                .collect()
        };
        Some(Job {
            key: value["key"].as_str()?.to_string(),
            dir,
            command: value["command"].as_str().map(str::to_string),
            argv: strings(&value["argv"]),
            cwd: value["cwd"].as_str().unwrap_or_default().to_string(),
            state: JobState::parse(value["state"].as_str()?)?,
            pid: value["pid"].as_u64().map(|pid| pid as u32),
            exit_code: value["exitCode"].as_i64(),
            started_at: value["startedAt"].as_u64().unwrap_or(0),
            ended_at: value["endedAt"].as_u64(),
            error: value["error"].as_str().map(str::to_string),
            cancel_signal: value["cancelSignal"].as_i64().map(|signal| signal as i32),
        })
    }

    /// What `job.status` reports: the persisted form plus the current size of the output.
    fn status(&self) -> Value {
        let mut value = self.to_json();
        value["outputBytes"] = json!(output_bytes(&self.dir));
        value
    }

    fn save(&self) {
        let temporary = self.dir.join("job.json.tmp");
        let saved = fs::write(&temporary, self.to_json().to_string())
            .and_then(|()| fs::rename(&temporary, self.dir.join("job.json")));
        if let Err(error) = saved {
            eprintln!("hands: cannot save job {}: {error}", self.key);
        }
    }
}

fn output_bytes(dir: &Path) -> u64 {
    fs::metadata(dir.join("output.log"))
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

/// A key's directory name: a readable prefix and a 64-bit FNV-1a hash of the whole key. `job.json` holds the key.
fn dir_name(key: &str) -> String {
    let readable: String = key
        .chars()
        .take(48)
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in key.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{readable}-{hash:016x}")
}

fn key(json: &Value) -> Result<&str, Failure> {
    match json["key"].as_str() {
        Some(key) if !key.is_empty() && key.len() <= MAX_KEY_BYTES => Ok(key),
        _ => Err(Failure::new(
            "EINVAL",
            format!("key must be a string of 1 to {MAX_KEY_BYTES} bytes"),
        )),
    }
}

fn not_found(key: &str) -> Failure {
    Failure::new("not_found", format!("no job with key {key}"))
}

/// `signal` as a name (`SIGTERM`, `TERM`) or a number; SIGTERM when absent.
fn signal(value: &Value) -> Result<i32, Failure> {
    const NAMES: [(&str, i32); 7] = [
        ("HUP", libc::SIGHUP),
        ("INT", libc::SIGINT),
        ("QUIT", libc::SIGQUIT),
        ("KILL", libc::SIGKILL),
        ("TERM", libc::SIGTERM),
        ("USR1", libc::SIGUSR1),
        ("USR2", libc::SIGUSR2),
    ];
    let invalid = || Failure::new("EINVAL", format!("unknown signal {value}"));
    match value {
        Value::Null => Ok(libc::SIGTERM),
        Value::Number(number) => match number.as_i64() {
            Some(signal @ 1..=31) => Ok(signal as i32),
            _ => Err(invalid()),
        },
        Value::String(name) => {
            let name = name.strip_prefix("SIG").unwrap_or(name);
            NAMES
                .iter()
                .find(|(known, _)| *known == name)
                .map(|(_, signal)| *signal)
                .ok_or_else(invalid)
        }
        _ => Err(invalid()),
    }
}

/// Whether the runner of the job in `dir` still lives: it holds `runner.lock` until it exits.
fn runner_alive(dir: &Path) -> bool {
    match File::open(dir.join("runner.lock")) {
        Ok(file) => matches!(state::lock(&file, false), Ok(false)),
        Err(_) => false,
    }
}

/// Every job recorded under `root`, as `job.status` reports them, newest first.
pub fn read_all(root: &Path) -> Vec<Value> {
    let mut jobs = load_dir(root);
    jobs.sort_by_key(|job| std::cmp::Reverse(job.started_at));
    jobs.iter().map(Job::status).collect()
}

fn load_dir(root: &Path) -> Vec<Job> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    entries
        .filter_map(|entry| {
            let dir = entry.ok()?.path();
            let bytes = fs::read(dir.join("job.json")).ok()?;
            Job::from_json(dir, &serde_json::from_slice(&bytes).ok()?)
        })
        .collect()
}

/// The jobs one supervisor owns.
pub struct Jobs {
    root: PathBuf,
    table: Mutex<HashMap<String, Job>>,
    /// Signalled whenever a job ends.
    ended: Condvar,
}

impl Jobs {
    /// The jobs recorded under `root`; running ones are adopted and watched until they end.
    pub fn load(root: PathBuf) -> Arc<Jobs> {
        let jobs = Arc::new(Jobs {
            table: Mutex::new(HashMap::new()),
            ended: Condvar::new(),
            root: root.clone(),
        });
        let mut running = Vec::new();
        {
            let mut table = jobs.table.lock().unwrap();
            for job in load_dir(&root) {
                if job.state == JobState::Running {
                    running.push(job.key.clone());
                }
                table.insert(job.key.clone(), job);
            }
        }
        for key in running {
            let adopter = jobs.clone();
            thread::spawn(move || adopter.adopt(&key));
        }
        jobs.prune();
        jobs
    }

    /// Watch a job started by an earlier supervisor until its runner exits.
    fn adopt(&self, key: &str) {
        loop {
            let dir = match self.table.lock().unwrap().get(key) {
                Some(job) if job.state == JobState::Running => job.dir.clone(),
                _ => return,
            };
            if !runner_alive(&dir) {
                self.finish(key, None);
                return;
            }
            thread::sleep(ADOPT_POLL);
        }
    }

    pub fn start(self: &Arc<Self>, json: &Value) -> Result<Value, Failure> {
        let key = key(json)?;
        let mut table = self.table.lock().unwrap();
        if let Some(job) = table.get(key) {
            // Idempotent: the same key never starts a second process, whatever the other fields say.
            let mut status = job.status();
            status["created"] = json!(false);
            return Ok(status);
        }
        let command = json["command"].as_str().map(str::to_string);
        let argv: Option<Vec<String>> = match json["argv"].as_array() {
            None => None,
            Some(items) => Some(
                items
                    .iter()
                    .map(|item| item.as_str().map(str::to_string))
                    .collect::<Option<_>>()
                    .ok_or_else(|| Failure::new("EINVAL", "argv must hold strings"))?,
            ),
        };
        let (program, args) = match (&command, &argv) {
            (Some(command), _) => {
                let shell = sys::shell_config(json["shellPath"].as_str())?;
                let mut args = shell.args;
                args.push(command.clone());
                (shell.program, args)
            }
            (None, Some(argv)) => match argv.split_first() {
                Some((first, rest)) => (first.clone(), rest.to_vec()),
                None => return Err(Failure::new("spawn_error", "Empty argv: no program to run")),
            },
            (None, None) => {
                return Err(Failure::new("EINVAL", "job.start needs command or argv"));
            }
        };
        let cwd = json["cwd"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(sys::home);
        if !Path::new(&cwd).is_dir() {
            return Err(Failure::new(
                "spawn_error",
                format!("Working directory does not exist: {cwd}"),
            ));
        }
        let dir = self.root.join(dir_name(key));
        let dir_text = dir.to_string_lossy().into_owned();
        // Left over from a job this supervisor does not know (pruned, or a start that failed half way).
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).map_err(|error| Failure::io(&error, "mkdir", &dir_text))?;
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("output.log"))
            .and_then(|log| Ok((log.try_clone()?, log)))
            .map_err(|error| Failure::io(&error, "open", &dir_text))?;
        let executable = std::env::current_exe()
            .map_err(|error| Failure::new("spawn_error", error.to_string()))?;
        let mut runner = Command::new(executable);
        runner
            .arg("__job-runner")
            .arg(&dir)
            .arg("--")
            .arg(&program)
            .current_dir(&cwd)
            .stdin(Stdio::null())
            .stdout(log.0)
            .stderr(log.1);
        // A new session (one process group to signal), default signal handling, and the environment serve resolved.
        sys::configure(
            &mut runner,
            &args,
            &json["env"].as_object().cloned().unwrap_or_default(),
            json["inheritEnv"].as_bool().unwrap_or(true),
        );
        let mut child = runner.spawn().map_err(|error| {
            let _ = fs::remove_dir_all(&dir);
            Failure::new("spawn_error", error.to_string())
        })?;
        let job = Job {
            key: key.to_string(),
            dir,
            argv: if command.is_some() { None } else { argv },
            command,
            cwd,
            state: JobState::Running,
            pid: Some(child.id()),
            exit_code: None,
            started_at: now_ms(),
            ended_at: None,
            error: None,
            cancel_signal: None,
        };
        job.save();
        let mut status = job.status();
        status["created"] = json!(true);
        table.insert(key.to_string(), job);
        drop(table);
        let jobs = self.clone();
        let key = key.to_string();
        thread::spawn(move || {
            let status = child.wait().ok();
            jobs.finish(&key, status);
        });
        Ok(status)
    }

    /// Record how a job ended, from the runner's `exit.json` or, without it, from what is known.
    fn finish(&self, key: &str, runner_status: Option<ExitStatus>) {
        let mut table = self.table.lock().unwrap();
        let Some(job) = table.get_mut(key) else {
            return;
        };
        if job.state != JobState::Running {
            return;
        }
        let exit: Value = fs::read(job.dir.join("exit.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or(Value::Null);
        job.ended_at = Some(exit["endedAt"].as_u64().unwrap_or_else(now_ms));
        job.exit_code = exit["exitCode"]
            .as_i64()
            .or_else(|| runner_status.map(sys::exit_code))
            .or_else(|| job.cancel_signal.map(|signal| 128 + i64::from(signal)));
        job.state = if job.cancel_signal.is_some() {
            JobState::Cancelled
        } else if let Some(error) = exit["error"].as_str() {
            job.error = Some(error.to_string());
            JobState::Failed
        } else if exit.is_null() {
            job.error = Some(if runner_status.is_some() {
                "the job runner was killed before it recorded the exit status".into()
            } else {
                "the job ended while no supervisor was running; its exit status is unknown".into()
            });
            JobState::Failed
        } else {
            JobState::Exited
        };
        job.save();
        self.ended.notify_all();
    }

    pub fn status(&self, json: &Value) -> Result<Value, Failure> {
        let key = key(json)?;
        let table = self.table.lock().unwrap();
        table.get(key).map(Job::status).ok_or_else(|| not_found(key))
    }

    /// Wait until the job ends or `timeoutMs` passes; the job keeps running either way.
    pub fn wait(&self, json: &Value) -> Result<Value, Failure> {
        let key = key(json)?;
        let timeout = json["timeoutMs"].as_u64().unwrap_or(DEFAULT_WAIT_MS);
        let deadline = Instant::now() + Duration::from_millis(timeout);
        let mut table = self.table.lock().unwrap();
        loop {
            let job = table.get(key).ok_or_else(|| not_found(key))?;
            let now = Instant::now();
            if job.state != JobState::Running || now >= deadline {
                let mut status = job.status();
                status["timedOut"] = json!(job.state == JobState::Running);
                return Ok(status);
            }
            table = self.ended.wait_timeout(table, deadline - now).unwrap().0;
        }
    }

    /// Up to `maxBytes` of the output log from `offset`, as raw bytes.
    pub fn output(&self, json: &Value) -> Result<(Value, Vec<u8>), Failure> {
        let key = key(json)?;
        let (dir, state) = {
            let table = self.table.lock().unwrap();
            let job = table.get(key).ok_or_else(|| not_found(key))?;
            (job.dir.clone(), job.state)
        };
        let offset = json["offset"].as_u64().unwrap_or(0);
        let max = json["maxBytes"]
            .as_u64()
            .unwrap_or(DEFAULT_OUTPUT_BYTES)
            .min(MAX_PAYLOAD as u64);
        let path = dir.join("output.log");
        let path_text = path.to_string_lossy().into_owned();
        let file = File::open(&path).map_err(|error| Failure::io(&error, "open", &path_text))?;
        let size = file
            .metadata()
            .map_err(|error| Failure::io(&error, "fstat", &path_text))?
            .len();
        let mut bytes = vec![0u8; size.saturating_sub(offset).min(max) as usize];
        let mut filled = 0;
        while filled < bytes.len() {
            match sys::read_at(&file, &mut bytes[filled..], offset + filled as u64) {
                Ok(0) => break,
                Ok(read) => filled += read,
                Err(error) => return Err(Failure::io(&error, "read", &path_text)),
            }
        }
        bytes.truncate(filled);
        let next = offset + filled as u64;
        Ok((
            json!({
                "offset": offset,
                "nextOffset": next,
                "outputBytes": size.max(next),
                "state": state.name(),
                "eof": state != JobState::Running && next >= size,
            }),
            bytes,
        ))
    }

    /// Send `signal` (default SIGTERM) to the job's whole process group; the job then ends as `cancelled`.
    pub fn cancel(&self, json: &Value) -> Result<Value, Failure> {
        let key = key(json)?;
        let signal = signal(&json["signal"])?;
        let mut table = self.table.lock().unwrap();
        let job = table.get_mut(key).ok_or_else(|| not_found(key))?;
        let mut signalled = false;
        if job.state == JobState::Running
            && let Some(pid) = job.pid
        {
            job.cancel_signal = Some(signal);
            job.save();
            // SAFETY: plain signal delivery to the job's process group, which the runner leads while it runs.
            signalled = unsafe { libc::kill(-(pid as i32), signal) } == 0;
        }
        let mut status = job.status();
        status["signalled"] = json!(signalled);
        Ok(status)
    }

    pub fn list(&self) -> Value {
        let table = self.table.lock().unwrap();
        let mut jobs: Vec<&Job> = table.values().collect();
        jobs.sort_by_key(|job| std::cmp::Reverse(job.started_at));
        json!({ "jobs": jobs.into_iter().map(Job::status).collect::<Vec<_>>() })
    }

    pub fn count(&self) -> (usize, usize) {
        let table = self.table.lock().unwrap();
        let running = table
            .values()
            .filter(|job| job.state == JobState::Running)
            .count();
        (table.len(), running)
    }

    /// Exit the supervisor between requests: taking the table lock waits for a `job.start` in flight to be saved.
    pub fn exit(&self) -> ! {
        let _table = self.table.lock().unwrap();
        std::process::exit(0);
    }

    /// Delete finished jobs older than the retention period, and the oldest beyond the maximum count.
    pub fn prune(&self) {
        let mut table = self.table.lock().unwrap();
        let now = now_ms();
        let mut finished: Vec<(u64, String)> = table
            .values()
            .filter(|job| job.state != JobState::Running)
            .map(|job| (job.ended_at.unwrap_or(job.started_at), job.key.clone()))
            .collect();
        finished.sort();
        let excess = finished.len().saturating_sub(MAX_FINISHED);
        for (index, (ended, key)) in finished.iter().enumerate() {
            if index < excess || now.saturating_sub(*ended) > RETENTION_MS {
                if let Some(job) = table.remove(key) {
                    let _ = fs::remove_dir_all(&job.dir);
                }
            }
        }
    }
}

/// `hands __job-runner <dir> -- <program> <args>`: runs one job's command in the job's process group and records
/// its exit status in `<dir>/exit.json` (see the module docs). Returns the process exit code.
pub fn runner(args: &[String]) -> i32 {
    let (Some(dir), Some("--"), Some(program)) = (
        args.first(),
        args.get(1).map(String::as_str),
        args.get(2),
    ) else {
        eprintln!("usage: hands __job-runner <dir> -- <program> [args...]");
        return 2;
    };
    let dir = Path::new(dir);
    // Held until this process exits; a supervisor that finds it free knows the job has ended.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join("runner.lock"));
    if let Ok(lock) = &lock {
        let _ = state::lock(lock, true);
    }
    // SAFETY: setting dispositions before any threads exist; the command gets the defaults back below.
    unsafe {
        for signal in POLITE {
            libc::signal(signal, libc::SIG_IGN);
        }
    }
    let record = |value: Value| {
        let temporary = dir.join("exit.json.tmp");
        let _ = fs::write(&temporary, value.to_string())
            .and_then(|()| fs::rename(&temporary, dir.join("exit.json")));
    };
    let mut command = Command::new(program);
    command.args(&args[3..]);
    // SAFETY: only async-signal-safe calls between fork and exec.
    unsafe {
        command.pre_exec(|| {
            for signal in POLITE {
                libc::signal(signal, libc::SIG_DFL);
            }
            Ok(())
        });
    }
    let status = command.spawn().and_then(|mut child| child.wait());
    match status {
        Ok(status) => {
            let code = sys::exit_code(status);
            record(json!({ "exitCode": code, "endedAt": now_ms() }));
            code as i32
        }
        Err(error) => {
            eprintln!("hands: cannot start {program}: {error}");
            record(json!({ "error": format!("spawn_error: {error}"), "endedAt": now_ms() }));
            127
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directory_names_are_safe_and_distinct() {
        let name = dir_name("call_1|fc_../x");
        assert!(name.starts_with("call_1_fc____x-"));
        assert!(!name.contains('/') && !name.contains('.'));
        assert_ne!(dir_name("a|b"), dir_name("a/b"));
        assert_eq!(dir_name("a|b"), dir_name("a|b"));
        assert!(dir_name(&"k".repeat(MAX_KEY_BYTES)).len() < 100);
    }

    #[test]
    fn signals_by_name_or_number() {
        assert_eq!(signal(&Value::Null).unwrap(), libc::SIGTERM);
        assert_eq!(signal(&json!("SIGKILL")).unwrap(), libc::SIGKILL);
        assert_eq!(signal(&json!("INT")).unwrap(), libc::SIGINT);
        assert_eq!(signal(&json!(9)).unwrap(), 9);
        assert!(signal(&json!(0)).is_err());
        assert!(signal(&json!("SIGSEGV")).is_err());
    }

    #[test]
    fn records_round_trip() {
        let job = Job {
            key: "k".into(),
            dir: PathBuf::from("/nonexistent"),
            command: None,
            argv: Some(vec!["ls".into(), "-l".into()]),
            cwd: "/".into(),
            state: JobState::Cancelled,
            pid: Some(42),
            exit_code: Some(143),
            started_at: 1,
            ended_at: Some(2),
            error: None,
            cancel_signal: Some(15),
        };
        let back = Job::from_json(job.dir.clone(), &job.to_json()).unwrap();
        assert_eq!(back.to_json(), job.to_json());
        assert_eq!(job.status()["outputBytes"], 0);
    }
}
