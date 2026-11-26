//! The VI/EN state file (AC-8, SEC-5).

mod common;

use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};

use common::{PREEDIT, ctx, tap_ctrl_shift};
use ime_core::{FileStateStore, Ime, Mode, StateStore, state_dir};

/// A fresh directory under the cargo target dir, removed on drop.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("ime-core-state-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn state_dir(&self) -> PathBuf {
        self.0.join("state").join("vr-telex")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn mode_bits(path: &Path) -> u32 {
    fs::symlink_metadata(path).unwrap().permissions().mode() & 0o7777
}

/// One run of the daemon: start from the file, tap, and save what the mode
/// watch reports, as the daemon does off the key path.
fn run_and_toggle(dir: &Path) -> (Mode, Mode) {
    let store = FileStateStore::new(dir.to_path_buf());
    let mut ime = Ime::new(&store);
    let started = ime.mode();
    let mut watch = ime.subscribe_mode();
    let id = ctx(&mut ime, PREEDIT);
    tap_ctrl_shift(&mut ime, id);
    assert_eq!(store.load(), started, "the key path itself writes nothing");
    let now = watch.try_changed().expect("the watch reports the toggle");
    store.save(now);
    (started, now)
}

#[test]
fn the_mode_survives_a_restart() {
    let scratch = Scratch::new("restart");
    let dir = scratch.state_dir();

    assert_eq!(
        run_and_toggle(&dir),
        (Mode::Vi, Mode::En),
        "first start: VI"
    );
    assert_eq!(
        run_and_toggle(&dir),
        (Mode::En, Mode::Vi),
        "EN after a restart"
    );
    let ime = Ime::new(&FileStateStore::new(dir));
    assert_eq!(ime.mode(), Mode::Vi, "VI after the next restart");
}

#[test]
fn only_the_mode_is_stored_in_a_private_file() {
    let scratch = Scratch::new("private");
    let dir = scratch.state_dir();
    let store = FileStateStore::new(dir.clone());

    store.save(Mode::En);
    assert_eq!(fs::read(dir.join("mode")).unwrap(), b"EN");
    store.save(Mode::Vi);
    assert_eq!(fs::read(dir.join("mode")).unwrap(), b"VI");

    assert_eq!(mode_bits(&dir), 0o700);
    assert_eq!(mode_bits(&dir.join("mode")), 0o600);
    let names: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(
        names,
        [OsStr::new("mode")],
        "no other file, no temp file left"
    );
}

#[test]
fn an_existing_wider_directory_is_tightened() {
    let scratch = Scratch::new("tighten");
    let dir = scratch.state_dir();
    fs::create_dir_all(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    // A temp file left by a killed run must not block the next save.
    fs::write(dir.join("mode.tmp"), b"junk").unwrap();

    let store = FileStateStore::new(dir.clone());
    store.save(Mode::En);
    assert_eq!(mode_bits(&dir), 0o700);
    assert_eq!(store.load(), Mode::En);
    assert!(!dir.join("mode.tmp").exists());
}

#[test]
fn a_missing_or_damaged_file_means_vietnamese() {
    let scratch = Scratch::new("damaged");
    let dir = scratch.state_dir();
    let store = FileStateStore::new(dir.clone());
    assert_eq!(store.load(), Mode::Vi, "no directory yet");
    assert!(!dir.exists(), "loading creates nothing");

    fs::create_dir_all(&dir).unwrap();
    for content in [&b""[..], b"en", b"EN extra", b"\xff\xfe", &[b'E'; 4096]] {
        fs::write(dir.join("mode"), content).unwrap();
        assert_eq!(store.load(), Mode::Vi);
    }
    for content in [&b"EN"[..], b"EN\n"] {
        fs::write(dir.join("mode"), content).unwrap();
        assert_eq!(store.load(), Mode::En);
    }
}

#[test]
fn a_symlink_in_place_of_the_file_is_neither_read_nor_written_through() {
    let scratch = Scratch::new("symlink");
    let dir = scratch.state_dir();
    fs::create_dir_all(&dir).unwrap();
    let target = scratch.0.join("elsewhere");
    fs::write(&target, b"EN").unwrap();
    symlink(&target, dir.join("mode")).unwrap();

    let store = FileStateStore::new(dir.clone());
    assert_eq!(store.load(), Mode::Vi, "a symlink is not our file");

    store.save(Mode::Vi);
    assert_eq!(
        fs::read(&target).unwrap(),
        b"EN",
        "the link target is untouched"
    );
    assert!(fs::symlink_metadata(dir.join("mode")).unwrap().is_file());
    assert_eq!(fs::read(dir.join("mode")).unwrap(), b"VI");
}

#[test]
fn a_symlink_in_place_of_the_directory_is_refused() {
    let scratch = Scratch::new("dirlink");
    let dir = scratch.state_dir();
    let target = scratch.0.join("elsewhere");
    fs::create_dir_all(&target).unwrap();
    fs::create_dir_all(dir.parent().unwrap()).unwrap();
    symlink(&target, &dir).unwrap();

    let store = FileStateStore::new(dir);
    store.save(Mode::En);
    assert_eq!(fs::read_dir(&target).unwrap().count(), 0);
    assert_eq!(store.load(), Mode::Vi);
}

#[test]
fn an_unwritable_location_does_not_break_typing() {
    let store = FileStateStore::new(PathBuf::from("/proc/vr-telex-no-such-dir/state"));
    let mut ime = Ime::new(&store);
    let id = ctx(&mut ime, PREEDIT);
    tap_ctrl_shift(&mut ime, id);
    assert_eq!(ime.mode(), Mode::En, "the mode still changes for this run");
}

#[test]
fn the_state_directory_follows_the_xdg_rules() {
    let home = Some(OsStr::new("/home/u"));
    assert_eq!(
        state_dir(Some(OsStr::new("/x/state")), home),
        Some(PathBuf::from("/x/state/vr-telex"))
    );
    assert_eq!(
        state_dir(None, home),
        Some(PathBuf::from("/home/u/.local/state/vr-telex"))
    );
    // XDG: a relative or empty value is invalid and ignored.
    assert_eq!(
        state_dir(Some(OsStr::new("relative/state")), home),
        Some(PathBuf::from("/home/u/.local/state/vr-telex"))
    );
    assert_eq!(
        state_dir(Some(OsStr::new("")), home),
        Some(PathBuf::from("/home/u/.local/state/vr-telex"))
    );
    assert_eq!(state_dir(None, None), None);
    assert_eq!(state_dir(None, Some(OsStr::new("not-absolute"))), None);
}
