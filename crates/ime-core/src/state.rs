//! The only state the daemon persists: VI or EN (SEC-5).

use std::ffi::OsStr;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::ime::{Mode, StateStore};

const APP_DIR: &str = "vr-telex";
const FILE: &str = "mode";
const TEMP_FILE: &str = "mode.tmp";
/// "VI" or "EN" plus an optional newline; anything longer is not our file.
const MAX_LEN: u64 = 8;

/// `$XDG_STATE_HOME/vr-telex`, or `$HOME/.local/state/vr-telex` when the
/// variable is unset, empty or relative (the XDG rule). `None` without a
/// usable home directory.
pub fn state_dir(xdg_state_home: Option<&OsStr>, home: Option<&OsStr>) -> Option<PathBuf> {
    let absolute = |value: Option<&OsStr>| {
        value
            .map(Path::new)
            .filter(|path| path.is_absolute())
            .map(Path::to_path_buf)
    };
    absolute(xdg_state_home)
        .or_else(|| absolute(home).map(|home| home.join(".local").join("state")))
        .map(|base| base.join(APP_DIR))
}

/// Keeps the mode in `<dir>/mode` (directory 0700, file 0600, replaced
/// atomically). A missing, damaged or foreign file means Vietnamese.
pub struct FileStateStore {
    dir: PathBuf,
}

impl FileStateStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// The store at the place the environment names; see [`state_dir`].
    pub fn from_env() -> Option<Self> {
        let xdg = std::env::var_os("XDG_STATE_HOME");
        let home = std::env::var_os("HOME");
        state_dir(xdg.as_deref(), home.as_deref()).map(Self::new)
    }

    fn is_real_dir(&self) -> bool {
        // A symlink here would let the file land wherever the link points.
        fs::symlink_metadata(&self.dir).is_ok_and(|meta| meta.is_dir())
    }

    fn read(&self) -> Option<Mode> {
        if !self.is_real_dir() {
            return None;
        }
        let path = self.dir.join(FILE);
        let meta = fs::symlink_metadata(&path).ok()?;
        if !meta.is_file() || meta.len() > MAX_LEN {
            return None;
        }
        let mut content = Vec::new();
        File::open(&path)
            .ok()?
            .take(MAX_LEN + 1)
            .read_to_end(&mut content)
            .ok()?;
        Mode::from_symbol(content.trim_ascii())
    }

    /// Writes the mode; `save` is this without the error.
    pub fn try_save(&self, mode: Mode) -> io::Result<()> {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.dir)?;
        if !self.is_real_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the state directory is not a directory",
            ));
        }
        // Fails for a directory of another user, which is then not used.
        fs::set_permissions(&self.dir, fs::Permissions::from_mode(0o700))?;

        let temp = self.dir.join(TEMP_FILE);
        match fs::remove_file(&temp) {
            Err(err) if err.kind() != io::ErrorKind::NotFound => return Err(err),
            _ => {}
        }
        let written = OpenOptions::new()
            .write(true)
            // Never opens an existing file or a symlink left in its place.
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .and_then(|mut file| file.write_all(mode.symbol().as_bytes()))
            // rename replaces a symlink at the target instead of following it.
            .and_then(|()| fs::rename(&temp, self.dir.join(FILE)));
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written
    }
}

impl StateStore for FileStateStore {
    fn load(&self) -> Mode {
        self.read().unwrap_or(Mode::Vi)
    }

    /// A failed write only costs the mode at the next start: typing goes on.
    fn save(&self, m: Mode) {
        let _ = self.try_save(m);
    }
}
