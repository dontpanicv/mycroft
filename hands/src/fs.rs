//! File operations with Node's semantics where the Rust standard library differs (docs/semantics.md).

use crate::errors::Failure;
use crate::sys;
use serde_json::{Value, json};
use std::fs::{self, File, Metadata};
use std::io::{self, Write};
use std::path::Path;

pub type Outcome<T> = Result<T, Failure>;

/// `{ name, kind, size, mtimeSec, mtimeNsec, dev, ino }` of fstat metadata.
pub fn info(path: &str, metadata: &Metadata) -> Value {
    let file_type = metadata.file_type();
    let kind = if file_type.is_file() {
        "file"
    } else if file_type.is_dir() {
        "directory"
    } else if file_type.is_symlink() {
        "symlink"
    } else {
        "other"
    };
    let name = Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let (mtime_sec, mtime_nsec) = sys::mtime(metadata);
    let (dev, ino) = sys::identity(metadata);
    json!({
        "name": name,
        "kind": kind,
        "size": metadata.len(),
        "mtimeSec": mtime_sec,
        "mtimeNsec": mtime_nsec,
        "dev": dev,
        "ino": ino,
    })
}

/// Node's recursive `mkdir`: an existing directory is fine, an existing file is `EEXIST`, a file in the way of a
/// parent is `ENOTDIR`.
pub fn mkdir_recursive(path: &Path) -> io::Result<()> {
    let is_dir = |path: &Path| {
        fs::metadata(path)
            .map(|metadata| metadata.is_dir())
            .unwrap_or(false)
    };
    match fs::create_dir(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            if is_dir(path) {
                Ok(())
            } else {
                Err(error)
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let Some(parent) = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
            else {
                return Err(error);
            };
            match mkdir_recursive(parent) {
                Err(parent_error) if parent_error.kind() == io::ErrorKind::AlreadyExists => {
                    return Err(sys::synthetic("ENOTDIR"));
                }
                other => other?,
            }
            match fs::create_dir(path) {
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists && is_dir(path) => {
                    Ok(())
                }
                other => other,
            }
        }
        Err(error) => Err(error),
    }
}

/// `writeFile`/`appendFile`: create missing parents like Node's recursive `mkdir`, then write.
pub fn write(path: &str, append: bool, content: &[u8]) -> Outcome<()> {
    if let Some(parent) = Path::new(path)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        mkdir_recursive(parent)
            .map_err(|error| Failure::io(&error, "mkdir", &parent.to_string_lossy()))?;
    }
    let mode = if append {
        sys::OpenMode::Append
    } else {
        sys::OpenMode::Write
    };
    let mut file = sys::open(path, mode).map_err(|error| Failure::io(&error, "open", path))?;
    file.write_all(content)
        .map_err(|error| Failure::io(&error, "write", path))
}

/// Up to `length` bytes at `offset`; fewer only at the end of the file.
pub fn pread(file: &File, path: &str, offset: u64, length: usize) -> Outcome<Vec<u8>> {
    let mut buffer = vec![0u8; length];
    let mut filled = 0;
    while filled < length {
        match sys::read_at(file, &mut buffer[filled..], offset + filled as u64) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(Failure::io(&error, "read", path)),
        }
    }
    buffer.truncate(filled);
    Ok(buffer)
}
