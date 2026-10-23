//! The operating system: error names, positional reads, temporary directories, and starting and killing commands,
//! each as Node (libuv) does it on macOS and Linux.

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

// hands targets macOS and Linux only (supervised jobs use Unix sockets and sessions).
#[cfg(not(unix))]
compile_error!("hands supports macOS and Linux only");

/// How a string command runs: the shell and its arguments before the command.
pub struct ShellConfig {
    pub program: String,
    pub args: Vec<String>,
}

/// How Node opens files: `r`, `writeFile` (`w`) and `appendFile` (`a`).
#[derive(Clone, Copy)]
pub enum OpenMode {
    /// Node's `open(path, "r")`: any kind of file, blocking reads.
    Read,
    Write,
    Append,
}

/// An error code libuv reports where the system call itself reported another one, such as `ENOTDIR` from a recursive
/// `mkdir` through a file.
#[derive(Debug)]
pub struct Synthetic(pub &'static str);

impl std::fmt::Display for Synthetic {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for Synthetic {}

pub fn synthetic(code: &'static str) -> std::io::Error {
    std::io::Error::other(Synthetic(code))
}

/// The libuv name of an error: a synthetic code, or the system's code translated per platform.
pub fn error_name(error: &std::io::Error) -> &'static str {
    if let Some(Synthetic(code)) = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<Synthetic>())
    {
        return code;
    }
    os_error_name(error)
}

/// Whether a path exists, following symbolic links, like Node's `access(path, F_OK)`.
pub fn path_exists(path: &str) -> bool {
    std::path::Path::new(path).metadata().is_ok()
}

/// Sixteen random bytes for temporary names (not for secrets).
pub fn random_bytes() -> [u8; 16] {
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let state = std::collections::hash_map::RandomState::new();
    let mut bytes = [0u8; 16];
    for half in 0..2 {
        let mut hasher = state.build_hasher();
        hasher.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|time| time.as_nanos())
                .unwrap_or(0),
        );
        bytes[half * 8..half * 8 + 8].copy_from_slice(&hasher.finish().to_le_bytes());
    }
    bytes
}

/// The daemon's working directory, the `process.cwd()` Node's `path.resolve` falls back to.
pub fn cwd() -> String {
    std::env::current_dir()
        .map(|cwd| cwd.to_string_lossy().into_owned())
        .unwrap_or_default()
}
