//! Where clients find the bus: the socket directory and the IBus address files.
//!
//! libibus (GNOME Shell, the GTK module) and Qt's IBus plugin read
//! `$XDG_CONFIG_HOME/ibus/bus/<machine-id>-<host>-<display>`, connect to its
//! `IBUS_ADDRESS` when `IBUS_DAEMON_PID` is alive, and reconnect when the
//! address string changes.

use std::fs::{self, DirBuilder, File, OpenOptions, TryLockError};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const APP_DIR: &str = "vr-talex";
const SOCKET_FILE: &str = "ibus";
/// Held by the running instance for its whole run (SEC-7).
const LOCK_FILE: &str = "ibus.lock";

fn refused(what: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, what)
}

/// One path component taken from the environment: no separators, no `..`.
fn is_component(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// The file names libibus derives for a session, newest convention first:
/// `$WAYLAND_DISPLAY` when set, and the host and number of `$DISPLAY`.
/// Both are written because clients differ in which variable they prefer.
pub fn address_file_names(
    machine_id: &str,
    wayland_display: Option<&str>,
    x_display: Option<&str>,
) -> Vec<String> {
    let mut names = Vec::new();
    if let Some(wayland) = wayland_display.filter(|name| is_component(name)) {
        names.push(format!("{machine_id}-unix-{wayland}"));
    }
    if let Some((host, rest)) = x_display.and_then(|display| display.rsplit_once(':')) {
        let host = if host.is_empty() { "unix" } else { host };
        let number = rest.split('.').next().unwrap_or_default();
        if is_component(host) && !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
            let name = format!("{machine_id}-{host}-{number}");
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    names
}

/// A machine id is 32 hex digits; anything else is not used in a file name.
pub(crate) fn parse_machine_id(content: &str) -> Option<String> {
    let id = content.trim();
    (id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())).then(|| id.to_owned())
}

/// A directory that is really one (not a link to one) and belongs to `uid`.
fn owned_dir(path: &Path, uid: u32) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        return Err(refused("not a directory"));
    }
    if meta.uid() != uid {
        return Err(refused("directory of another user"));
    }
    Ok(())
}

/// Why the socket cannot be prepared.
#[derive(Debug)]
pub(crate) enum PrepareError {
    /// Another instance holds the lock: it serves the socket and owns the
    /// address files, and none of them may be touched.
    Running,
    /// The directory, the lock or the socket path is not safe to use.
    Unsafe,
}

impl From<io::Error> for PrepareError {
    fn from(_: io::Error) -> Self {
        Self::Unsafe
    }
}

/// The socket path, and the lock that makes this run its only user.
pub(crate) struct Prepared {
    pub(crate) socket: PathBuf,
    pub(crate) lock: File,
}

/// Takes `<dir>/ibus.lock` for this run. The kernel releases the lock when
/// the process ends however it ends, so a crashed run never blocks a restart.
fn take_lock(dir: &Path, uid: u32) -> Result<File, PrepareError> {
    let path = dir.join(LOCK_FILE);
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() && meta.uid() == uid => {}
        Ok(_) => return Err(refused("the lock path is not a file of this user").into()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => return Err(err.into()),
    }
    // The directory is a real 0700 one of this user, checked just before:
    // nobody else can put a link here between the check and the open.
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)?;
    match lock.try_lock() {
        Ok(()) => Ok(lock),
        Err(TryLockError::WouldBlock) => Err(PrepareError::Running),
        Err(TryLockError::Error(err)) => Err(err.into()),
    }
}

/// Creates `<runtime_dir>/vr-talex` (0700), takes the instance lock and
/// returns the socket path in it, after removing the socket a previous run
/// left there (SEC-6, SEC-7). While another instance runs nothing is
/// touched: its socket and address files are live.
pub(crate) fn prepare_socket(runtime_dir: &Path, uid: u32) -> Result<Prepared, PrepareError> {
    owned_dir(runtime_dir, uid)?;
    let dir = runtime_dir.join(APP_DIR);
    match DirBuilder::new().mode(0o700).create(&dir) {
        Err(err) if err.kind() != io::ErrorKind::AlreadyExists => return Err(err.into()),
        _ => {}
    }
    owned_dir(&dir, uid)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    let lock = take_lock(&dir, uid)?;

    let socket = dir.join(SOCKET_FILE);
    match fs::symlink_metadata(&socket) {
        // With the lock held, a socket of this user is one a dead run left.
        Ok(meta) if meta.file_type().is_socket() && meta.uid() == uid => fs::remove_file(&socket)?,
        Ok(_) => return Err(refused("the socket path is taken by something else").into()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => return Err(err.into()),
    }
    Ok(Prepared { socket, lock })
}

/// Device and inode of a path itself (not of what a link points to).
fn identity(path: &Path) -> Option<(u64, u64)> {
    fs::symlink_metadata(path)
        .ok()
        .map(|meta| (meta.dev(), meta.ino()))
}

/// The D-Bus address of the socket. `guid` changes on every start, which is
/// what makes a client that still holds the old address connect again.
pub(crate) fn bus_address(socket: &Path, guid: &str) -> Option<String> {
    let path = socket.to_str()?;
    // Other bytes would need escaping in an address; a runtime directory
    // never has them.
    path.bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.'))
        .then(|| format!("unix:path={path},guid={guid}"))
}

pub(crate) fn file_content(address: &str, pid: u32) -> String {
    format!("IBUS_ADDRESS={address}\nIBUS_DAEMON_PID={pid}\n")
}

/// Writes `<bus_dir>/<name>` atomically (0600) and never through a link
/// (SEC-7): the directory must be a real one of this user, a path that holds
/// anything but a regular file of this user is refused, and the content goes
/// to a new temporary file that then replaces the old one.
pub(crate) fn write_address_file(
    bus_dir: &Path,
    name: &str,
    content: &str,
    uid: u32,
) -> io::Result<PathBuf> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(bus_dir)?;
    owned_dir(bus_dir, uid)?;

    let path = bus_dir.join(name);
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() && meta.uid() == uid => {}
        Ok(_) => return Err(refused("the address file path is not a file of this user")),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => return Err(err),
    }

    let temp = bus_dir.join(format!(".{name}.vr-talex.tmp"));
    match fs::remove_file(&temp) {
        Err(err) if err.kind() != io::ErrorKind::NotFound => return Err(err),
        _ => {}
    }
    let written = OpenOptions::new()
        .write(true)
        // Never opens an existing file or a link left in its place.
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .and_then(|mut file| file.write_all(content.as_bytes()))
        .and_then(|()| fs::rename(&temp, &path));
    if written.is_err() {
        let _ = fs::remove_file(&temp);
    }
    written.map(|()| path)
}

/// What a run published; taken back when the frontend stops, so that no
/// client is sent to a socket nobody listens on.
///
/// Only what this run created and still owns is removed. The lock is the
/// last field: it is released after the clean-up, never before it.
pub(crate) struct Published {
    socket: PathBuf,
    /// What `bind` created; `None` when it could not be read back, and then
    /// the socket is left where it is.
    socket_identity: Option<(u64, u64)>,
    content: String,
    files: Vec<PathBuf>,
    _lock: File,
}

impl Published {
    /// To be called right after `bind` created `socket`.
    pub(crate) fn new(prepared: Prepared, content: String) -> Self {
        Self {
            socket_identity: identity(&prepared.socket),
            socket: prepared.socket,
            content,
            files: Vec::new(),
            _lock: prepared.lock,
        }
    }

    pub(crate) fn add(&mut self, file: PathBuf) {
        self.files.push(file);
    }
}

impl Drop for Published {
    fn drop(&mut self) {
        for file in &self.files {
            // Another input method may have published itself since: only a
            // file that still holds this run's address is removed.
            let ours = fs::symlink_metadata(file).is_ok_and(|meta| meta.is_file())
                && fs::read_to_string(file).is_ok_and(|content| content == self.content);
            if ours {
                let _ = fs::remove_file(file);
            }
        }
        if self.socket_identity.is_some() && identity(&self.socket) == self.socket_identity {
            let _ = fs::remove_file(&self.socket);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn names_follow_libibus_for_wayland_and_x() {
        assert_eq!(
            address_file_names(ID, Some("wayland-0"), Some(":0")),
            [format!("{ID}-unix-wayland-0"), format!("{ID}-unix-0")]
        );
        assert_eq!(
            address_file_names(ID, None, Some(":1.0")),
            [format!("{ID}-unix-1")]
        );
        assert_eq!(
            address_file_names(ID, None, Some("localhost:10.0")),
            [format!("{ID}-localhost-10")]
        );
        assert!(address_file_names(ID, None, None).is_empty());
    }

    #[test]
    fn display_values_that_would_leave_the_directory_are_skipped() {
        assert!(address_file_names(ID, Some("../x"), Some("../../etc:0")).is_empty());
        assert!(address_file_names(ID, Some("/run/user/1000/wayland-0"), None).is_empty());
        assert!(address_file_names(ID, Some(".."), Some(":x")).is_empty());
        assert!(address_file_names(ID, Some(""), Some("0")).is_empty());
    }

    #[test]
    fn machine_id_must_be_32_hex_digits() {
        assert_eq!(parse_machine_id(&format!("{ID}\n")).as_deref(), Some(ID));
        assert_eq!(parse_machine_id("../../x"), None);
        assert_eq!(parse_machine_id(""), None);
    }

    #[test]
    fn address_is_a_path_address_with_the_guid() {
        assert_eq!(
            bus_address(Path::new("/run/user/1000/vr-talex/ibus"), "abc").as_deref(),
            Some("unix:path=/run/user/1000/vr-talex/ibus,guid=abc")
        );
        assert_eq!(bus_address(Path::new("/run/a,b/ibus"), "abc"), None);
        assert_eq!(bus_address(Path::new("/run/a b/ibus"), "abc"), None);
    }
}
