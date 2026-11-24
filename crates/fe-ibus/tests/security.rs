//! What a client must not be able to do: reach another client's input
//! context, see its text, connect as someone else, or exhaust the daemon
//! (SEC-8, SEC-9, SEC-10, SEC-11, SEC-15, SEC-16).

mod common;

use std::os::unix::fs::MetadataExt;
use std::time::Duration;

use common::*;
use fe_ibus::Limits;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::time::timeout;

const QUIET: Duration = Duration::from_millis(150);
const WAIT: Duration = Duration::from_secs(5);

const UNKNOWN_OBJECT: &str = "org.freedesktop.DBus.Error.UnknownObject";
const UNKNOWN_METHOD: &str = "org.freedesktop.DBus.Error.UnknownMethod";
const INVALID_ARGS: &str = "org.freedesktop.DBus.Error.InvalidArgs";
const ACCESS_DENIED: &str = "org.freedesktop.DBus.Error.AccessDenied";

/// Writes `lines` on a new raw connection and returns what the bus answers
/// until it closes the connection or stays silent.
async fn raw_exchange(bus: &Bus, lines: &[u8]) -> Vec<u8> {
    let mut stream = UnixStream::connect(bus.sandbox.socket())
        .await
        .expect("connect");
    stream.write_all(lines).await.expect("write");
    let mut answer = Vec::new();
    let mut chunk = [0u8; 256];
    while let Ok(Ok(read)) = timeout(QUIET, stream.read(&mut chunk)).await {
        if read == 0 {
            break;
        }
        answer.extend_from_slice(&chunk[..read]);
    }
    answer
}

fn own_uid(bus: &Bus) -> u32 {
    std::fs::metadata(&bus.sandbox.dir).expect("own dir").uid()
}

/// `AUTH EXTERNAL` with the caller's real uid, hex-encoded as SASL wants it.
fn external_auth(uid: u32) -> Vec<u8> {
    let hex: String = uid
        .to_string()
        .bytes()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("\0AUTH EXTERNAL {hex}\r\n").into_bytes()
}

/// A raw connection that authenticated and began the message phase.
async fn raw_authenticated(bus: &Bus) -> UnixStream {
    let mut stream = UnixStream::connect(bus.sandbox.socket())
        .await
        .expect("connect");
    stream
        .write_all(&external_auth(own_uid(bus)))
        .await
        .expect("write");
    let mut answer = [0u8; 64];
    let read = timeout(WAIT, stream.read(&mut answer))
        .await
        .expect("an answer in time")
        .expect("read");
    assert!(answer[..read].starts_with(b"OK "), "authenticated");
    stream.write_all(b"BEGIN\r\n").await.expect("write");
    stream
}

async fn is_closed(stream: &mut UnixStream) -> bool {
    let mut chunk = [0u8; 64];
    loop {
        match timeout(WAIT, stream.read(&mut chunk)).await {
            Ok(Ok(0)) | Ok(Err(_)) => return true,
            Ok(Ok(_)) => {}
            Err(_) => return false,
        }
    }
}

/// Proves that the bus still serves `client`: a word goes through.
async fn still_types(client: &mut Client, path: &str) {
    assert_eq!(client.type_letters(path, "as").await, [preedit("á")]);
    let space = client.key(path, KEY_SPACE, 0).await;
    assert_eq!(space.before, [Seen::Commit("á".into()), hidden(Some(0))]);
}

#[test]
fn only_external_authentication_is_accepted() {
    block_on(async {
        let bus = Bus::start().await;
        // SEC-8: no anonymous access, no cookie file.
        for refused in [
            &b"\0AUTH ANONYMOUS\r\n"[..],
            b"\0AUTH ANONYMOUS 74657374\r\n",
        ] {
            assert_eq!(raw_exchange(&bus, refused).await, b"REJECTED EXTERNAL\r\n");
        }
        // A mechanism the bus does not know at all ends the connection.
        let cookie = b"\0AUTH DBUS_COOKIE_SHA1 31303030\r\nBEGIN\r\n";
        assert_eq!(raw_exchange(&bus, cookie).await, b"");
        let mut stream = UnixStream::connect(bus.sandbox.socket()).await.unwrap();
        stream.write_all(cookie).await.unwrap();
        assert!(is_closed(&mut stream).await);
        // The identity claimed must be the one the kernel reports.
        let other = external_auth(own_uid(&bus) + 1);
        assert_eq!(raw_exchange(&bus, &other).await, b"REJECTED EXTERNAL\r\n");
        let own = external_auth(own_uid(&bus));
        assert!(raw_exchange(&bus, &own).await.starts_with(b"OK "));
    });
}

#[test]
fn a_peer_of_another_user_is_dropped_before_the_handshake() {
    block_on(async {
        // The daemon runs as another user than the one connecting: the peer
        // credentials decide, whatever the client says (SEC-8).
        let sandbox = Sandbox::new();
        let config = sandbox.config();
        let other_user = config.uid + 1;
        let (ready, watch) = ime_core::Ready::channel();
        let ime = new_ime();
        let task = tokio::spawn(fe_ibus::serve_peers_of(
            config,
            ime.clone(),
            ready,
            other_user,
        ));
        assert!(watch.wait().await);
        let bus = Bus { sandbox, ime, task };
        // `EXTERNAL` without an identity is what the handshake alone would
        // let through.
        let answer = raw_exchange(&bus, b"\0AUTH EXTERNAL\r\nDATA\r\n").await;
        assert_eq!(answer, b"");
        assert!(Client::connect(&bus.sandbox.socket()).await.is_err());
    });
}

#[test]
fn a_context_belongs_to_the_connection_that_created_it() {
    block_on(async {
        let bus = Bus::start().await;
        let mut owner = bus.greeted().await;
        let mut intruder = bus.greeted().await;
        let path = owner.shell_context().await;
        owner.unasked(QUIET).await;
        assert_eq!(owner.type_letters(&path, "vieet").await, [preedit("viêt")]);

        // SEC-9: every call on the foreign context fails, whatever it is.
        let refused = [
            intruder.key(&path, 'j' as u32, 0).await,
            intruder.context(&path, "FocusIn", &()).await,
            intruder.context(&path, "FocusOut", &()).await,
            intruder.context(&path, "Reset", &()).await,
            intruder.context(&path, "SetCapabilities", &(0u32,)).await,
            intruder.set(&path, "ContentType", (8u32, 0u32)).await,
            intruder.call(IBUS, &path, SERVICE, "Destroy", &()).await,
        ];
        for answer in refused {
            assert_eq!(answer.error().as_deref(), Some(UNKNOWN_OBJECT));
            assert_eq!(answer.before, []);
        }

        // The owner's word is untouched by all of it, and its commit goes
        // to the owner alone.
        assert_eq!(owner.unasked(QUIET).await, []);
        let last = owner.tap(&path, 'j' as u32).await;
        assert_eq!(last.before, [preedit("việt")]);
        let space = owner.key(&path, KEY_SPACE, 0).await;
        assert_eq!(space.before, [Seen::Commit("việt".into()), hidden(Some(0))]);
        assert_eq!(intruder.unasked(QUIET).await, []);
    });
}

#[test]
fn signals_of_a_context_reach_only_its_connection() {
    block_on(async {
        let bus = Bus::start().await;
        let mut first = bus.greeted().await;
        let mut second = bus.greeted().await;
        // The second client listens for everything and has a context too.
        second.bus("AddMatch", &("type='signal'",)).await.ok();
        let second_path = second.shell_context().await;
        let first_path = first.shell_context().await;
        first.unasked(QUIET).await;
        second.unasked(QUIET).await;

        first.type_letters(&first_path, "matj").await;
        first.key(&first_path, KEY_SPACE, 0).await;
        first.type_letters(&first_path, "khaaur").await;
        first.context(&first_path, "FocusOut", &()).await.ok();
        assert_eq!(second.unasked(QUIET).await, []);
        still_types(&mut second, &second_path).await;
    });
}

#[test]
fn only_the_ibus_surface_is_served() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        let path = client.shell_context().await;

        // SEC-11: nothing to stop, reconfigure or inspect the daemon.
        for member in ["Exit", "RegisterComponent", "Ping", "GetAddress"] {
            let answer = client.ibus(member, &()).await;
            assert_eq!(answer.error().as_deref(), Some(UNKNOWN_METHOD), "{member}");
        }
        let introspect = client
            .call(
                IBUS,
                IBUS_PATH,
                "org.freedesktop.DBus.Introspectable",
                "Introspect",
                &(),
            )
            .await;
        assert_eq!(introspect.error().as_deref(), Some(UNKNOWN_METHOD));
        let introspect = client
            .call(
                IBUS,
                &path,
                "org.freedesktop.DBus.Introspectable",
                "Introspect",
                &(),
            )
            .await;
        assert_eq!(introspect.error().as_deref(), Some(UNKNOWN_METHOD));

        // Only the one engine can be selected.
        let engine = client.ibus("SetGlobalEngine", &("xkb:us::eng",)).await;
        assert_eq!(engine.error().as_deref(), Some(INVALID_ARGS));
        // Only the panel name can be requested.
        let name = client.bus("RequestName", &(IBUS, 0u32)).await;
        assert_eq!(name.error().as_deref(), Some(ACCESS_DENIED));
        // Nothing is routed to other connections.
        let routed = client
            .call(":1.1", "/org/freedesktop/IBus/Panel", PANEL, "FocusIn", &())
            .await;
        assert_eq!(
            routed.error().as_deref(),
            Some("org.freedesktop.DBus.Error.ServiceUnknown")
        );
        let object = client
            .call(IBUS, "/org/freedesktop/IBus/Other", IBUS, "FocusIn", &())
            .await;
        assert_eq!(object.error().as_deref(), Some(UNKNOWN_OBJECT));
        let hello = client.bus("Hello", &()).await;
        assert_eq!(
            hello.error().as_deref(),
            Some("org.freedesktop.DBus.Error.Failed")
        );
        still_types(&mut client, &path).await;
    });
}

#[test]
fn calls_with_wrong_arguments_fail_without_harm() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        let path = client.shell_context().await;

        // SEC-15: each gets an error reply; the connection goes on.
        let wrong = [
            client.context(&path, "ProcessKeyEvent", &("a",)).await,
            client
                .context(&path, "ProcessKeyEvent", &(1u32, 2u32))
                .await,
            client.context(&path, "ProcessKeyEvent", &()).await,
            client.context(&path, "SetCapabilities", &("all",)).await,
            client.context(&path, "SetCursorLocation", &(1i32,)).await,
            client.set(&path, "ContentType", "password").await,
            client.set(&path, "ContentType", (8u32,)).await,
            client.set(&path, "ClientCommitPreedit", true).await,
            client.set(&path, "NoSuchProperty", 1u32).await,
            client
                .call(IBUS, &path, PROPERTIES, "Set", &("only one",))
                .await,
            client.ibus("CreateInputContext", &(7u32,)).await,
            client.ibus("SetGlobalEngine", &()).await,
            client.bus("RequestName", &("name only",)).await,
            client.bus("GetNameOwner", &(1u32,)).await,
            client.bus("AddMatch", &()).await,
        ];
        for (at, answer) in wrong.iter().enumerate() {
            assert_eq!(answer.error().as_deref(), Some(INVALID_ARGS), "call {at}");
        }
        still_types(&mut client, &path).await;
    });
}

#[test]
fn a_client_must_say_hello_first() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.client().await;
        let answer = client.ibus("CreateInputContext", &("early",)).await;
        assert_eq!(answer.error().as_deref(), Some(ACCESS_DENIED));
        assert!(client.closed().await);
    });
}

#[test]
fn bytes_that_are_not_dbus_end_only_that_connection() {
    block_on(async {
        let bus = Bus::start().await;
        let mut typist = bus.greeted().await;
        let path = typist.shell_context().await;

        // SEC-15: a wrong protocol byte, a header that lies about its
        // fields, and a stream of noise.
        let mut noise = vec![0x6c, 1, 0, 1, 4, 0, 0, 0, 1, 0, 0, 0, 200, 0, 0, 0];
        noise.extend(std::iter::repeat_n(0xff, 300));
        for garbage in [&b"GET / HTTP/1.1\r\n\r\n"[..], &noise, &[0u8; 64]] {
            let mut stream = raw_authenticated(&bus).await;
            stream.write_all(garbage).await.expect("write");
            assert!(is_closed(&mut stream).await);
            still_types(&mut typist, &path).await;
        }

        // A connection that never authenticates, and one that stops
        // half way through a message, hold nobody else up.
        let _silent = UnixStream::connect(bus.sandbox.socket()).await.unwrap();
        let mut half = raw_authenticated(&bus).await;
        half.write_all(&[0x6c, 1, 0, 1]).await.expect("write");
        still_types(&mut typist, &path).await;
    });
}

#[test]
fn a_message_over_the_size_limit_ends_the_connection() {
    block_on(async {
        let bus = Bus::start_with(|config| config.limits.message_bytes = 4096).await;
        let mut typist = bus.greeted().await;
        let path = typist.shell_context().await;
        let mut flooder = bus.greeted().await;

        // Under the limit: served.
        let rule = "x".repeat(2048);
        flooder.bus("AddMatch", &(rule.as_str(),)).await.ok();
        // Over it: dropped before the body is read (SEC-16).
        let rule = "x".repeat(8192);
        flooder
            .send(DBUS, DBUS_PATH, DBUS, "AddMatch", &(rule.as_str(),))
            .await;
        assert!(flooder.closed().await);
        still_types(&mut typist, &path).await;

        // A header that announces 100 MiB is refused without waiting for it.
        let mut stream = raw_authenticated(&bus).await;
        let mut header = vec![0x6c, 1, 0, 1];
        header.extend_from_slice(&(100u32 << 20).to_le_bytes());
        header.extend_from_slice(&1u32.to_le_bytes());
        header.extend_from_slice(&0u32.to_le_bytes());
        stream.write_all(&header).await.expect("write");
        assert!(is_closed(&mut stream).await);
    });
}

#[test]
fn a_handshake_that_never_ends_is_cut_off() {
    block_on(async {
        let bus = Bus::start().await;
        let mut stream = UnixStream::connect(bus.sandbox.socket()).await.unwrap();
        // One endless line: the bus must not buffer it (SEC-16).
        let line = vec![b'A'; 4096];
        let mut written = 0usize;
        while written < 64 * 1024 {
            if stream.write_all(&line).await.is_err() {
                break;
            }
            written += line.len();
        }
        assert!(is_closed(&mut stream).await);
    });
}

#[test]
fn input_contexts_per_connection_are_limited() {
    block_on(async {
        let limits = Limits {
            contexts_per_connection: 2,
            ..Limits::default()
        };
        let bus = Bus::start_with(|config| config.limits = limits).await;
        let mut client = bus.greeted().await;
        let first = client.create_context().await;
        let _second = client.create_context().await;
        let third = client.ibus("CreateInputContext", &("third",)).await;
        assert_eq!(
            third.error().as_deref(),
            Some("org.freedesktop.DBus.Error.LimitsExceeded")
        );
        // Destroying one makes room again; another connection has its own.
        client
            .call(IBUS, &first, SERVICE, "Destroy", &())
            .await
            .ok();
        client.create_context().await;
        let mut other = bus.greeted().await;
        other.create_context().await;
    });
}

#[test]
fn connections_are_limited() {
    block_on(async {
        let bus = Bus::start_with(|config| config.limits.connections = 2).await;
        let mut first = bus.greeted().await;
        let path = first.shell_context().await;
        let second = bus.greeted().await;
        // The third is closed at once (SEC-16)…
        assert!(Client::connect(&bus.sandbox.socket()).await.is_err());
        still_types(&mut first, &path).await;
        // …until one of the others leaves.
        drop(second);
        let mut retried = None;
        for _ in 0..50 {
            if let Ok(client) = Client::connect(&bus.sandbox.socket()).await {
                retried = Some(client);
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        retried
            .expect("a freed slot is given out again")
            .hello()
            .await;
    });
}

#[test]
fn a_departed_client_leaves_nothing_behind() {
    block_on(async {
        let bus = Bus::start().await;
        let mut client = bus.greeted().await;
        client.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = client.shell_context().await;
        client.type_letters(&path, "matkhau").await;
        drop(client);

        // The panel role is free again, which shows the session is gone;
        // its contexts and their words went with it (SEC-4).
        let mut next = bus.greeted().await;
        for _ in 0..50 {
            let answer = next.bus("NameHasOwner", &(PANEL,)).await.ok();
            let (owned,): (bool,) = answer.reply.body().deserialize().unwrap();
            if !owned {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("the panel name was not released");
    });
}

#[test]
fn the_panel_role_follows_the_documented_rule() {
    block_on(async {
        let bus = Bus::start().await;
        let mut first = bus.greeted().await;
        let mut second = bus.greeted().await;
        let granted = |answer: Answer| -> u32 {
            let (code,): (u32,) = answer.reply.body().deserialize().unwrap();
            code
        };
        assert_eq!(granted(first.bus("RequestName", &(PANEL, 2u32)).await), 1);
        assert_eq!(granted(first.bus("RequestName", &(PANEL, 2u32)).await), 4);
        // SEC-10: a second connection of the same process (GNOME Shell
        // connecting again) takes the role over; both test clients are this
        // process. Another process is refused: see the unit tests of
        // `claim_panel`.
        assert_eq!(granted(second.bus("RequestName", &(PANEL, 2u32)).await), 1);
        first.unasked(QUIET).await;
        second.unasked(QUIET).await;

        // Only the current panel is told about the mode.
        let path = second.shell_context().await;
        second.unasked(QUIET).await;
        second.tap_ctrl_shift(&path).await;
        assert_eq!(
            second.unasked(QUIET).await,
            [Seen::Panel("UpdateProperty".into(), "EN".into())]
        );
        assert_eq!(first.unasked(QUIET).await, []);

        // The former panel cannot release what it no longer holds.
        assert_eq!(granted(first.bus("ReleaseName", &(PANEL,)).await), 3);
        assert_eq!(granted(second.bus("ReleaseName", &(PANEL,)).await), 1);
        assert_eq!(granted(second.bus("ReleaseName", &(PANEL,)).await), 2);
    });
}

#[test]
fn a_password_context_sends_the_panel_nothing() {
    block_on(async {
        let bus = Bus::start().await;
        let mut shell = bus.greeted().await;
        shell.bus("RequestName", &(PANEL, 2u32)).await.ok();
        let path = shell.shell_context().await;
        shell.set(&path, "ContentType", (8u32, 0u32)).await.ok();
        shell.unasked(QUIET).await;
        // SEC-10: no text of a password field reaches the panel — nor
        // anything else: the keys only pass.
        for letter in "matkhau1s".chars() {
            let answer = shell.tap(&path, letter as u32).await;
            assert!(!answer.handled());
            assert_eq!(answer.before, []);
        }
        assert_eq!(shell.unasked(QUIET).await, []);
    });
}
