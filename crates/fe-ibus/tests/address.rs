//! The socket and the address files clients find it by (SEC-6, SEC-7, AC-9).

mod common;

use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt, symlink};
use std::path::Path;

use common::*;

fn mode(path: &Path) -> u32 {
    fs::symlink_metadata(path)
        .expect("exists")
        .permissions()
        .mode()
        & 0o7777
}

/// The `IBUS_ADDRESS` and `IBUS_DAEMON_PID` of an address file.
fn read_address(path: &Path) -> (String, u32) {
    let content = fs::read_to_string(path).expect("an address file");
    let value = |key: &str| {
        content
            .lines()
            .find_map(|line| line.strip_prefix(key))
            .unwrap_or_else(|| panic!("no {key} line"))
            .to_owned()
    };
    (
        value("IBUS_ADDRESS="),
        value("IBUS_DAEMON_PID=").parse().expect("a pid"),
    )
}

/// Starts a frontend that is expected to refuse; returns its error.
async fn refused(sandbox: &Sandbox) -> String {
    let (task, ready) = spawn(sandbox.config(), new_ime());
    assert!(!ready.wait().await, "the frontend must not get ready");
    task.await
        .expect("no panic")
        .expect_err("an error")
        .to_string()
}

#[test]
fn the_socket_is_a_private_path_socket() {
    block_on(async {
        let bus = Bus::start().await;
        let socket = bus.sandbox.socket();
        // SEC-6: a path socket, 0600, in a 0700 directory.
        assert!(
            fs::symlink_metadata(&socket)
                .unwrap()
                .file_type()
                .is_socket()
        );
        assert_eq!(mode(&socket), 0o600);
        assert_eq!(mode(socket.parent().unwrap()), 0o700);
    });
}

#[test]
fn both_address_files_name_the_listening_socket_and_the_live_daemon() {
    block_on(async {
        let bus = Bus::start().await;
        let socket = bus.sandbox.socket();
        for display in ["wayland-0", "0"] {
            let file = bus.sandbox.address_file(display);
            assert_eq!(mode(&file), 0o600);
            assert_eq!(mode(file.parent().unwrap()), 0o700);
            let (address, pid) = read_address(&file);
            // libibus ignores the file unless the pid is alive.
            assert_eq!(pid, std::process::id());
            let (path, guid) = address
                .strip_prefix("unix:path=")
                .and_then(|rest| rest.split_once(",guid="))
                .expect("a path address with the bus id");
            assert_eq!(Path::new(path), socket);
            assert_eq!(guid.len(), 32);
        }
        // Readiness was reported after the files were there, and the socket
        // they name answers.
        bus.greeted().await;
    });
}

#[test]
fn every_start_publishes_a_new_address() {
    block_on(async {
        let sandbox = Sandbox::new();
        let file = sandbox.address_file("wayland-0");
        let mut seen = Vec::new();
        for _ in 0..2 {
            let (task, ready) = spawn(sandbox.config(), new_ime());
            assert!(ready.wait().await);
            seen.push(read_address(&file).0);
            task.abort();
            let _ = task.await;
        }
        // The same string would make a client keep its dead connection.
        assert_ne!(seen[0], seen[1]);
    });
}

#[test]
fn a_restart_takes_over_the_socket_of_a_dead_run() {
    block_on(async {
        let sandbox = Sandbox::new();
        let dir = sandbox.socket().parent().unwrap().to_owned();
        fs::create_dir_all(&dir).unwrap();
        // What a killed daemon leaves: a socket nobody listens on.
        drop(std::os::unix::net::UnixListener::bind(sandbox.socket()).unwrap());
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();

        let (task, ready) = spawn(sandbox.config(), new_ime());
        assert!(ready.wait().await);
        assert_eq!(mode(&dir), 0o700);
        Client::connect(&sandbox.socket()).await.expect("listening");
        task.abort();
    });
}

#[test]
fn a_link_at_the_address_file_path_is_refused() {
    block_on(async {
        let sandbox = Sandbox::new();
        let bus_dir = sandbox.config().bus_dir;
        fs::create_dir_all(&bus_dir).unwrap();
        let target = sandbox.dir.join("victim");
        fs::write(&target, "untouched").unwrap();
        symlink(&target, sandbox.address_file("wayland-0")).unwrap();

        // SEC-7: refused with a static error, nothing written through it.
        let error = refused(&sandbox).await;
        assert_eq!(error, "fe-ibus: cannot write the address file safely");
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
        assert!(
            fs::symlink_metadata(sandbox.address_file("wayland-0"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        // Nothing half published stays behind.
        assert!(!sandbox.socket().exists());
        assert!(!sandbox.address_file("0").exists());
    });
}

#[test]
fn a_link_in_place_of_the_bus_directory_is_refused() {
    block_on(async {
        let sandbox = Sandbox::new();
        let bus_dir = sandbox.config().bus_dir;
        fs::create_dir_all(bus_dir.parent().unwrap()).unwrap();
        let elsewhere = sandbox.dir.join("elsewhere");
        fs::create_dir(&elsewhere).unwrap();
        symlink(&elsewhere, &bus_dir).unwrap();

        let error = refused(&sandbox).await;
        assert_eq!(error, "fe-ibus: cannot write the address file safely");
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);
    });
}

#[test]
fn a_left_over_temporary_link_is_not_followed() {
    block_on(async {
        let sandbox = Sandbox::new();
        let bus_dir = sandbox.config().bus_dir;
        fs::create_dir_all(&bus_dir).unwrap();
        let target = sandbox.dir.join("victim");
        fs::write(&target, "untouched").unwrap();
        let temp = bus_dir.join(format!(".{MACHINE_ID}-unix-wayland-0.vr-talex.tmp"));
        symlink(&target, &temp).unwrap();

        let (task, ready) = spawn(sandbox.config(), new_ime());
        assert!(ready.wait().await);
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
        assert!(!temp.exists());
        task.abort();
    });
}

#[test]
fn a_socket_path_taken_by_something_else_is_refused() {
    block_on(async {
        for plant in ["file", "link", "dir-link"] {
            let sandbox = Sandbox::new();
            let dir = sandbox.socket().parent().unwrap().to_owned();
            let target = sandbox.dir.join("victim");
            fs::write(&target, "untouched").unwrap();
            match plant {
                "file" => {
                    fs::create_dir_all(&dir).unwrap();
                    fs::write(sandbox.socket(), "untouched").unwrap();
                }
                "link" => {
                    fs::create_dir_all(&dir).unwrap();
                    symlink(&target, sandbox.socket()).unwrap();
                }
                _ => {
                    let elsewhere = sandbox.dir.join("elsewhere");
                    fs::create_dir(&elsewhere).unwrap();
                    symlink(&elsewhere, &dir).unwrap();
                }
            }
            let error = refused(&sandbox).await;
            assert_eq!(error, "fe-ibus: cannot use the socket directory", "{plant}");
            assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
            assert!(!sandbox.address_file("wayland-0").exists(), "{plant}");
        }
    });
}

#[test]
fn a_missing_runtime_directory_is_an_error() {
    block_on(async {
        let sandbox = Sandbox::new();
        fs::remove_dir_all(sandbox.dir.join("run")).unwrap();
        let error = refused(&sandbox).await;
        assert_eq!(error, "fe-ibus: cannot use the socket directory");
    });
}

#[test]
fn stopping_takes_back_what_was_published() {
    block_on(async {
        let sandbox = Sandbox::new();
        let (task, ready) = spawn(sandbox.config(), new_ime());
        assert!(ready.wait().await);
        let (wayland, x) = (sandbox.address_file("wayland-0"), sandbox.address_file("0"));
        // Another input method published itself over one of the files.
        fs::write(&x, "IBUS_ADDRESS=unix:path=/other\nIBUS_DAEMON_PID=1\n").unwrap();

        task.abort();
        let _ = task.await;
        assert!(!wayland.exists());
        assert!(!sandbox.socket().exists());
        assert!(x.exists(), "a file of someone else is left alone");
    });
}

#[test]
fn a_second_instance_leaves_the_running_one_alone() {
    block_on(async {
        let bus = Bus::start().await;
        let socket = bus.sandbox.socket();
        let files = [
            bus.sandbox.address_file("wayland-0"),
            bus.sandbox.address_file("0"),
        ];
        let published: Vec<String> = files
            .iter()
            .map(|file| fs::read_to_string(file).unwrap())
            .collect();
        let inode = fs::symlink_metadata(&socket).unwrap().ino();
        let mut client = bus.greeted().await;
        let path = client.shell_context().await;

        // SEC-7: the user starts the daemon by hand while the service runs.
        // The second one gives up before it touches anything and is gone.
        let error = refused(&bus.sandbox).await;
        assert_eq!(error, "fe-ibus: another instance is running");

        assert_eq!(fs::symlink_metadata(&socket).unwrap().ino(), inode);
        for (file, content) in files.iter().zip(&published) {
            assert_eq!(&fs::read_to_string(file).unwrap(), content);
        }
        // The client that was typing keeps typing, and a new one finds the bus.
        client.type_letters(&path, "vieetj").await;
        let space = client.tap(&path, KEY_SPACE).await;
        assert_eq!(space.before[0], Seen::Commit("việt".into()));
        bus.greeted().await;
        assert!(!bus.task.is_finished());
    });
}

#[test]
fn stopping_leaves_a_socket_it_did_not_create() {
    block_on(async {
        let sandbox = Sandbox::new();
        let (task, ready) = spawn(sandbox.config(), new_ime());
        assert!(ready.wait().await);
        // Someone else took the path over while this run was serving.
        fs::remove_file(sandbox.socket()).unwrap();
        let other = std::os::unix::net::UnixListener::bind(sandbox.socket()).unwrap();
        let inode = fs::symlink_metadata(sandbox.socket()).unwrap().ino();

        task.abort();
        let _ = task.await;
        assert_eq!(
            fs::symlink_metadata(sandbox.socket())
                .map(|meta| meta.ino())
                .ok(),
            Some(inode),
            "a socket of someone else is left alone"
        );
        drop(other);
    });
}
