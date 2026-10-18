//! Where hands keeps its state: the supervisor's socket, lock and log, one directory per job (docs/jobs.md), and the
//! listener's port, certificate and paired phones (docs/pairing.md).
//!
//! `HANDS_STATE_DIR` overrides the location (tests use it). Otherwise it is `~/Library/Application Support/hands` on
//! macOS and `$XDG_STATE_HOME/hands` or `~/.local/state/hands` on Linux. The directory is user-only (0700).

use crate::sys;
use std::fs::{self, File};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

pub fn dir() -> PathBuf {
    let set = |key: &str| std::env::var_os(key).filter(|value| !value.is_empty());
    if let Some(dir) = set("HANDS_STATE_DIR") {
        return PathBuf::from(dir);
    }
    let home = PathBuf::from(sys::home());
    if cfg!(target_os = "macos") {
        return home.join("Library/Application Support/hands");
    }
    match set("XDG_STATE_HOME").map(PathBuf::from) {
        Some(state) if state.is_absolute() => state.join("hands"),
        _ => home.join(".local/state/hands"),
    }
}

pub fn socket() -> PathBuf {
    dir().join("supervisor.sock")
}

pub fn jobs_dir() -> PathBuf {
    dir().join("jobs")
}

pub fn log() -> PathBuf {
    dir().join("supervisor.log")
}

/// `{ "port": N }`: the listener's port, chosen once.
pub fn listener_json() -> PathBuf {
    dir().join("listener.json")
}

/// Held by the running listener, which writes its pid into it.
pub fn listener_lock() -> PathBuf {
    dir().join("listener.lock")
}

/// The phones allowed to connect: `[{ name, publicKey, pairedAt }]`.
pub fn paired_json() -> PathBuf {
    dir().join("paired.json")
}

/// Create the state and jobs directories if missing, and make the state directory user-only.
pub fn ensure() -> io::Result<PathBuf> {
    let dir = dir();
    fs::create_dir_all(dir.join("jobs"))?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

/// Take an exclusive `flock` on `file`; without `wait`, report `false` instead of waiting while another process
/// holds it. The lock is released when the file is closed, or when its process dies.
pub fn lock(file: &File, wait: bool) -> io::Result<bool> {
    let operation = if wait {
        libc::LOCK_EX
    } else {
        libc::LOCK_EX | libc::LOCK_NB
    };
    loop {
        // SAFETY: flock on a descriptor `file` owns.
        if unsafe { libc::flock(file.as_raw_fd(), operation) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        match error.kind() {
            io::ErrorKind::Interrupted => continue,
            io::ErrorKind::WouldBlock => return Ok(false),
            _ => return Err(error),
        }
    }
}
