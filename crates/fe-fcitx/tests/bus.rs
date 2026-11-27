//! fe-fcitx on a private dbus-daemon, driven by zbus clients that make the
//! calls fcitx5-gtk made in spike T1 (Q4). Never the session bus of the
//! desktop: each test starts its own bus in the target tmp dir (SEC-29).

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::num::NonZeroU32;
use std::path::PathBuf;
use std::pin::Pin;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use fe_fcitx::{FCITX_NAME, Options, PORTAL_NAME};
use futures_core::Stream;
use ime_core::{Ime, MemoryStateStore, Mode, Ready, SharedIme};
use zbus::message::Type;
use zbus::{Connection, DBusError, Message, MessageStream};

const IM_IFACE: &str = "org.fcitx.Fcitx.InputMethod1";
const IC_IFACE: &str = "org.fcitx.Fcitx.InputContext1";
const PORTAL_IM: &str = "/org/freedesktop/portal/inputmethod";
/// What gnome-terminal (VTE) set in the spike: Preedit, FormattedPreedit,
/// ClientUnfocusCommit, RelativeRect, KeyEventOrderFix, ReportKeyRepeat,
/// ClientSideInputPanel.
const VTE_CAPS: u64 = 962_089_451_570;
const CAP_PASSWORD: u64 = 1 << 3;
const STEP: Duration = Duration::from_secs(5);

/// A dbus-daemon of our own: path socket, EXTERNAL auth, no service files
/// (so nothing can be activated), stopped and removed on drop.
struct Bus {
    child: Child,
    dir: PathBuf,
    addr: String,
}

impl Bus {
    fn start(name: &str) -> Bus {
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("fcitx-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("bus.conf");
        std::fs::write(
            &conf,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:path={}/bus</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>"#,
                dir.display()
            ),
        )
        .unwrap();
        let mut child = Command::new("dbus-daemon")
            .arg(format!("--config-file={}", conf.display()))
            .args(["--nofork", "--print-address=1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("dbus-daemon");
        let mut addr = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut addr)
            .unwrap();
        Bus {
            child,
            dir,
            addr: addr.trim().to_owned(),
        }
    }

    async fn connect(&self) -> Connection {
        zbus::conn::Builder::address(self.addr.as_str())
            .max_queued(std::num::NonZeroUsize::new(4096).unwrap())
            .build()
            .await
            .unwrap()
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn options() -> Options {
    Options {
        name_wait: Duration::from_secs(2),
        ..Options::default()
    }
}

/// Starts the frontend and waits until it reports ready.
async fn serve(bus: &Bus, opts: Options) -> tokio::task::JoinHandle<ime_core::Result<()>> {
    let conn = bus.connect().await;
    let ime = SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)));
    let (ready, watch) = Ready::channel();
    let task = tokio::spawn(fe_fcitx::serve(conn, ime, ready, opts));
    assert!(
        tokio::time::timeout(STEP, watch.wait()).await.unwrap(),
        "frontend did not get ready"
    );
    task
}

async fn next(stream: &mut MessageStream) -> Message {
    let item = tokio::time::timeout(
        STEP,
        std::future::poll_fn(|cx| Pin::new(&mut *stream).poll_next(cx)),
    )
    .await
    .expect("no message within 5 s");
    item.unwrap().unwrap()
}

fn error_name(err: zbus::Error) -> String {
    match err {
        zbus::Error::FDO(e) => e.name().to_string(),
        zbus::Error::MethodError(name, _, _) => name.to_string(),
        other => format!("not a D-Bus error: {other}"),
    }
}

/// What the client side saw for one key call.
#[derive(Debug, Clone, PartialEq)]
enum Seen {
    Commit(String),
    Preedit(String, i32),
    Delete(i32, u32),
    Reply(bool),
}

/// A fcitx5-gtk–like client: one input context, and the text the
/// application would show (commits plus the keys handed back unhandled).
struct App {
    conn: Connection,
    stream: MessageStream,
    ic: String,
    text: String,
    preedit: String,
    seen: Vec<Seen>,
}

impl App {
    async fn new(bus: &Bus) -> App {
        let conn = bus.connect().await;
        let stream = MessageStream::from(&conn);
        App {
            conn,
            stream,
            ic: String::new(),
            text: String::new(),
            preedit: String::new(),
            seen: Vec::new(),
        }
    }

    /// The calls fcitx5-gtk makes before the first key (spike Q4).
    async fn open(bus: &Bus, caps: u64) -> App {
        let mut app = App::new(bus).await;
        let version = app.call(PORTAL_IM, IM_IFACE, "Version", &()).await.unwrap();
        assert_eq!(version.body().deserialize::<u32>().unwrap(), 1);
        app.ic = app.create(PORTAL_IM).await.unwrap();
        app.ic_call("SetCapability", &caps).await.unwrap();
        app.ic_call("SetCursorRectV2", &(25i32, 69i32, 0i32, 0i32, 1.0f64))
            .await
            .unwrap();
        app.ic_call("FocusIn", &()).await.unwrap();
        app
    }

    async fn create(&mut self, path: &str) -> zbus::Result<String> {
        let args = vec![
            ("display".to_owned(), "wayland:".to_owned()),
            ("program".to_owned(), "gnome-terminal-server".to_owned()),
        ];
        let reply = self
            .call(path, IM_IFACE, "CreateInputContext", &(args,))
            .await?;
        let (ic, uuid) = reply
            .body()
            .deserialize::<(zbus::OwnedObjectPath, Vec<u8>)>()
            .unwrap();
        assert_eq!(uuid.len(), 16);
        Ok(ic.as_str().to_owned())
    }

    fn message<B>(&self, path: &str, iface: &str, member: &str, body: &B) -> Message
    where
        B: serde::Serialize + zbus::wire::DynamicType,
    {
        Message::method_call(path.to_owned(), member.to_owned())
            .destination(PORTAL_NAME)
            .interface(iface.to_owned())
            .build(body)
            .unwrap()
    }

    /// Sends one call and reads everything up to its reply, applying signals.
    async fn call<B>(
        &mut self,
        path: &str,
        iface: &str,
        member: &str,
        body: &B,
    ) -> zbus::Result<Message>
    where
        B: serde::Serialize + zbus::wire::DynamicType,
    {
        let msg = self.message(path, iface, member, body);
        self.conn.send(&msg).await.unwrap();
        let serial = msg.primary_header().serial_num();
        let mut replies = self.replies(&[serial]).await;
        replies.remove(&serial).unwrap()
    }

    async fn ic_call<B>(&mut self, member: &str, body: &B) -> zbus::Result<Message>
    where
        B: serde::Serialize + zbus::wire::DynamicType,
    {
        let ic = self.ic.clone();
        self.call(&ic, IC_IFACE, member, body).await
    }

    /// Reads the stream until every serial has its reply; signals for our
    /// context are applied in the order they arrive.
    async fn replies(
        &mut self,
        serials: &[NonZeroU32],
    ) -> HashMap<NonZeroU32, zbus::Result<Message>> {
        let mut out = HashMap::new();
        while out.len() < serials.len() {
            let msg = next(&mut self.stream).await;
            let h = msg.header();
            match msg.message_type() {
                Type::Signal if h.interface().map(|i| i.as_str()) == Some(IC_IFACE) => {
                    assert_eq!(h.path().map(|p| p.as_str()), Some(self.ic.as_str()));
                    self.apply(&msg);
                }
                Type::MethodReturn | Type::Error => {
                    let Some(serial) = h.reply_serial() else {
                        continue;
                    };
                    if !serials.contains(&serial) {
                        continue;
                    }
                    let result = if msg.message_type() == Type::Error {
                        Err(zbus::Error::from(msg.clone()))
                    } else {
                        Ok(msg.clone())
                    };
                    out.insert(serial, result);
                }
                _ => {}
            }
        }
        out
    }

    fn apply(&mut self, msg: &Message) {
        let member = msg.header().member().unwrap().as_str().to_owned();
        match member.as_str() {
            "CommitString" => {
                let text = msg.body().deserialize::<String>().unwrap();
                self.text.push_str(&text);
                self.seen.push(Seen::Commit(text));
            }
            "UpdateFormattedPreedit" => {
                let (pieces, cursor) = msg
                    .body()
                    .deserialize::<(Vec<(String, i32)>, i32)>()
                    .unwrap();
                self.preedit = pieces.iter().map(|(s, _)| s.as_str()).collect();
                self.seen.push(Seen::Preedit(self.preedit.clone(), cursor));
            }
            "DeleteSurroundingText" => {
                let (offset, chars) = msg.body().deserialize::<(i32, u32)>().unwrap();
                self.seen.push(Seen::Delete(offset, chars));
            }
            other => panic!("unexpected signal {other}"),
        }
    }

    /// Leaves the bus: the socket is closed, as when the application exits.
    async fn close(self) {
        drop(self.stream);
        self.conn.close().await.unwrap();
    }

    /// Types `text` waiting for each reply before the next key.
    async fn type_one_by_one(&mut self, text: &str) {
        for ch in text.chars() {
            for release in [false, true] {
                let reply = self
                    .ic_call("ProcessKeyEvent", &(ch as u32, 38u32, 0u32, release, 0u32))
                    .await
                    .unwrap();
                let handled = reply.body().deserialize::<bool>().unwrap();
                if !handled && !release {
                    self.text.push(ch);
                }
            }
        }
    }

    /// Types `text` the way the spike saw it: press and release of every key
    /// sent back to back, all before any reply is read (B2 under pipelining).
    async fn type_pipelined(&mut self, text: &str) {
        let mut sent = Vec::new();
        for ch in text.chars() {
            let keyval = ch as u32;
            for release in [false, true] {
                let msg = self.message(
                    &self.ic,
                    IC_IFACE,
                    "ProcessKeyEvent",
                    &(keyval, 38u32, 0u32, release, 94_762_095u32),
                );
                self.conn.send(&msg).await.unwrap();
                sent.push((msg.primary_header().serial_num(), ch, release));
            }
        }
        // Replies come in call order; apply each as the client would.
        let serials: Vec<_> = sent.iter().map(|(s, _, _)| *s).collect();
        let mut order = Vec::new();
        while order.len() < serials.len() {
            let msg = next(&mut self.stream).await;
            let h = msg.header();
            match msg.message_type() {
                Type::Signal if h.interface().map(|i| i.as_str()) == Some(IC_IFACE) => {
                    self.apply(&msg)
                }
                Type::MethodReturn => {
                    let serial = h.reply_serial().unwrap();
                    let Some(&(_, ch, release)) = sent.iter().find(|(s, _, _)| *s == serial) else {
                        continue;
                    };
                    let handled = msg.body().deserialize::<bool>().unwrap();
                    self.seen.push(Seen::Reply(handled));
                    if !handled && !release {
                        self.text.push(ch);
                    }
                    order.push(serial);
                }
                Type::Error => panic!("key call failed: {:?}", msg.header().error_name()),
                _ => {}
            }
        }
        assert_eq!(order, serials, "replies out of order");
    }
}

#[tokio::test]
async fn replays_the_spike_sequence_and_types_viet() {
    let bus = Bus::start("replay");
    let _server = serve(&bus, options()).await;
    let mut app = App::open(&bus, VTE_CAPS).await;
    assert!(app.ic.starts_with("/org/freedesktop/portal/inputcontext/"));

    app.type_pipelined("vieetj ").await;
    assert_eq!(app.text, "việt ");
    assert_eq!(app.preedit, "");
    // The word was shown as preedit with a byte cursor, then committed
    // before the reply that hands the space back (B2).
    assert!(app.seen.contains(&Seen::Preedit("việt".into(), 6)));
    let commit = app
        .seen
        .iter()
        .position(|s| *s == Seen::Commit("việt".into()))
        .unwrap();
    assert_eq!(
        app.seen.get(commit + 1),
        Some(&Seen::Reply(false)),
        "the space is handed back right after the commit"
    );
    assert!(
        app.seen[commit + 1..]
            .iter()
            .all(|s| matches!(s, Seen::Reply(_))),
        "{:?}",
        app.seen
    );

    app.ic_call("FocusOut", &()).await.unwrap();
    app.ic_call("DestroyIC", &()).await.unwrap();
}

#[tokio::test]
async fn focus_out_reset_and_destroy_commit_the_word() {
    let bus = Bus::start("commit");
    let _server = serve(&bus, options()).await;
    let mut app = App::open(&bus, VTE_CAPS).await;

    app.type_pipelined("vieet").await;
    assert_eq!(app.text, "");
    app.ic_call("FocusOut", &()).await.unwrap();
    assert_eq!(app.text, "viêt", "focus-out commits (B3, AC-3)");

    app.ic_call("FocusIn", &()).await.unwrap();
    app.type_pipelined("dd").await;
    app.ic_call("Reset", &()).await.unwrap();
    assert_eq!(app.text, "viêtđ", "reset commits (B3, AC-3)");

    app.type_pipelined("as").await;
    app.ic_call("DestroyIC", &()).await.unwrap();
    assert_eq!(app.text, "viêtđá", "destroy commits to the owner");
    let err = app.ic_call("FocusIn", &()).await.unwrap_err();
    assert_eq!(error_name(err), "org.freedesktop.DBus.Error.AccessDenied");
}

#[tokio::test]
async fn password_field_passes_every_key_through() {
    let bus = Bus::start("password");
    let _server = serve(&bus, options()).await;
    let mut app = App::open(&bus, VTE_CAPS | CAP_PASSWORD).await;

    app.type_pipelined("matkhau1s").await;
    assert_eq!(app.text, "matkhau1s", "AC-7");
    assert!(
        app.seen.iter().all(|s| *s == Seen::Reply(false)),
        "no preedit or commit for a password field: {:?}",
        app.seen
    );

    // Leaving password mode mid-session composes again.
    app.ic_call("SetCapability", &VTE_CAPS).await.unwrap();
    app.type_pipelined(" vieetj ").await;
    assert_eq!(app.text, "matkhau1s việt ");
}

#[tokio::test]
async fn changing_to_password_commits_the_word_first() {
    let bus = Bus::start("caps-switch");
    let _server = serve(&bus, options()).await;
    let mut app = App::open(&bus, VTE_CAPS).await;
    app.type_pipelined("vieet").await;
    app.ic_call("SetCapability", &(VTE_CAPS | CAP_PASSWORD))
        .await
        .unwrap();
    assert_eq!(
        app.text, "viêt",
        "SEC-13: the word goes to its own field first"
    );
    app.type_pipelined("aa").await;
    assert_eq!(app.text, "viêtaa");
}

#[tokio::test]
async fn another_connection_can_neither_use_nor_hear_a_context() {
    let bus = Bus::start("foreign");
    let _server = serve(&bus, options()).await;
    let mut owner = App::open(&bus, VTE_CAPS).await;

    let mut intruder = App::new(&bus).await;
    intruder.ic = owner.ic.clone();
    // Ask the bus for every InputContext1 signal: a broadcast would show up.
    intruder
        .conn
        .call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            "AddMatch",
            &(format!("type='signal',interface='{IC_IFACE}'"),),
        )
        .await
        .unwrap();
    for (member, err) in [
        ("FocusIn", intruder.ic_call("FocusIn", &()).await),
        (
            "ProcessKeyEvent",
            intruder
                .ic_call("ProcessKeyEvent", &(0x61u32, 38u32, 0u32, false, 0u32))
                .await,
        ),
        (
            "SetCapability",
            intruder.ic_call("SetCapability", &CAP_PASSWORD).await,
        ),
        ("FocusOut", intruder.ic_call("FocusOut", &()).await),
        ("DestroyIC", intruder.ic_call("DestroyIC", &()).await),
    ] {
        assert_eq!(
            error_name(err.unwrap_err()),
            "org.freedesktop.DBus.Error.AccessDenied",
            "{member}"
        );
    }

    owner.type_pipelined("vieetj ").await;
    assert_eq!(owner.text, "việt ", "owner unaffected");

    // A round trip after the owner's commit: anything sent to the intruder
    // before it would be read here.
    intruder
        .call(PORTAL_IM, IM_IFACE, "Version", &())
        .await
        .unwrap();
    assert!(
        intruder.seen.is_empty(),
        "intruder heard: {:?}",
        intruder.seen
    );
}

#[tokio::test]
async fn malformed_and_unknown_calls_get_errors_and_change_nothing() {
    let bus = Bus::start("malformed");
    let _server = serve(&bus, options()).await;
    let mut app = App::open(&bus, VTE_CAPS).await;
    let mut bystander = App::open(&bus, VTE_CAPS).await;
    let ic = app.ic.clone();
    let invalid = "org.freedesktop.DBus.Error.InvalidArgs";

    let cases: Vec<(&str, zbus::Result<Message>)> = vec![
        ("key (u)", app.ic_call("ProcessKeyEvent", &(0x61u32,)).await),
        (
            "key (uuuuu)",
            app.ic_call("ProcessKeyEvent", &(1u32, 2u32, 3u32, 4u32, 5u32))
                .await,
        ),
        ("caps (s)", app.ic_call("SetCapability", &("x",)).await),
        ("focus (u)", app.ic_call("FocusIn", &(1u32,)).await),
        (
            "surrounding (s)",
            app.ic_call("SetSurroundingText", &("text",)).await,
        ),
        (
            "rect (iii)",
            app.ic_call("SetCursorRect", &(1i32, 2i32, 3i32)).await,
        ),
        (
            "create (s)",
            app.call(PORTAL_IM, IM_IFACE, "CreateInputContext", &("x",))
                .await,
        ),
        (
            "create, too many pairs",
            app.call(
                PORTAL_IM,
                IM_IFACE,
                "CreateInputContext",
                &(vec![("k".to_owned(), "v".to_owned()); 17],),
            )
            .await,
        ),
    ];
    for (what, result) in cases {
        assert_eq!(error_name(result.unwrap_err()), invalid, "{what}");
    }

    let unknown = [
        (
            app.ic_call("ProcessKeyEventBatch", &(1u32, 2u32, 3u32, false, 5u32))
                .await,
            "org.freedesktop.DBus.Error.UnknownMethod",
        ),
        (
            app.call(PORTAL_IM, IM_IFACE, "Exit", &()).await,
            "org.freedesktop.DBus.Error.UnknownMethod",
        ),
        (
            app.call("/org/freedesktop/portal/other", IM_IFACE, "Version", &())
                .await,
            "org.freedesktop.DBus.Error.UnknownObject",
        ),
        (
            app.call(
                &ic,
                "org.freedesktop.DBus.Introspectable",
                "Introspect",
                &(),
            )
            .await,
            "org.freedesktop.DBus.Error.UnknownInterface",
        ),
        (
            app.call(PORTAL_IM, "org.fcitx.Fcitx.Controller1", "Exit", &())
                .await,
            "org.freedesktop.DBus.Error.UnknownInterface",
        ),
    ];
    for (result, name) in unknown {
        assert_eq!(error_name(result.unwrap_err()), name);
    }

    // Well-formed calls that are accepted and ignored.
    app.ic_call("SetSurroundingText", &("some text", 4u32, 4u32))
        .await
        .unwrap();
    app.ic_call("SetSurroundingTextPosition", &(4u32, 4u32))
        .await
        .unwrap();
    app.ic_call("SetCursorRect", &(1i32, 2i32, 3i32, 4i32))
        .await
        .unwrap();
    app.ic_call("SetSupportedCapability", &u64::MAX)
        .await
        .unwrap();

    app.type_pipelined("vieetj ").await;
    assert_eq!(app.text, "việt ", "the context still works");

    // SEC-15: another client, connected before or after the bad calls, types normally.
    bystander.type_pipelined("vieetj ").await;
    assert_eq!(bystander.text, "việt ");
    let mut newcomer = App::open(&bus, VTE_CAPS).await;
    newcomer.type_pipelined("vieetj ").await;
    assert_eq!(newcomer.text, "việt ");
}

const LIMITS: &str = "org.freedesktop.DBus.Error.LimitsExceeded";

#[tokio::test]
async fn a_client_slot_is_freed_when_its_connection_leaves() {
    let bus = Bus::start("slots");
    let _server = serve(
        &bus,
        Options {
            max_clients: 1,
            ..options()
        },
    )
    .await;
    let a = App::open(&bus, VTE_CAPS).await;
    let a_name = a.conn.unique_name().unwrap().as_str().to_owned();

    let mut b = App::new(&bus).await;
    let err = b
        .call(PORTAL_IM, IM_IFACE, "Version", &())
        .await
        .unwrap_err();
    assert_eq!(error_name(err), LIMITS, "only one client slot");

    // B learns of A's departure from the bus; the bus told the frontend in
    // the same moment, and before B's next call, so no waiting is needed.
    b.conn
        .call_method(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            Some("org.freedesktop.DBus"),
            "AddMatch",
            &(format!(
                "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0='{a_name}'"
            ),),
        )
        .await
        .unwrap();
    a.close().await;
    loop {
        let msg = next(&mut b.stream).await;
        let h = msg.header();
        if msg.message_type() == Type::Signal
            && h.member().map(|m| m.as_str()) == Some("NameOwnerChanged")
        {
            let (name, _, new) = msg
                .body()
                .deserialize::<(String, String, String)>()
                .unwrap();
            if name == a_name && new.is_empty() {
                break;
            }
        }
    }

    b.ic = b.create(PORTAL_IM).await.expect("slot freed after A left");
    b.ic_call("SetCapability", &VTE_CAPS).await.unwrap();
    b.ic_call("FocusIn", &()).await.unwrap();
    b.type_pipelined("vieetj ").await;
    assert_eq!(b.text, "việt ");

    // B holds the only slot now.
    let mut c = App::new(&bus).await;
    let err = c
        .call(PORTAL_IM, IM_IFACE, "Version", &())
        .await
        .unwrap_err();
    assert_eq!(error_name(err), LIMITS);
}

#[tokio::test]
async fn a_burst_beyond_the_queue_is_refused_and_serving_goes_on() {
    let bus = Bus::start("queue");
    let _server = serve(
        &bus,
        Options {
            queue_per_client: 1,
            ..options()
        },
    )
    .await;
    let mut app = App::open(&bus, VTE_CAPS).await;
    let mut other = App::open(&bus, VTE_CAPS).await;

    // 64 calls without waiting for any reply.
    let mut serials = Vec::new();
    for i in 0..64 {
        let msg = app.message(
            &app.ic,
            IC_IFACE,
            "ProcessKeyEvent",
            &(0x61u32, 38u32, 0u32, i % 2 == 1, 0u32),
        );
        app.conn.send(&msg).await.unwrap();
        serials.push(msg.primary_header().serial_num());
    }
    let replies = app.replies(&serials).await;
    let (mut served, mut refused) = (0, 0);
    for serial in &serials {
        match replies.get(serial).unwrap() {
            Ok(_) => served += 1,
            Err(e) => {
                assert_eq!(error_name(e.clone()), LIMITS);
                refused += 1;
            }
        }
    }
    assert_eq!(served + refused, 64, "every call answered");
    assert!(
        served > 0 && refused > 0,
        "served {served}, refused {refused}"
    );

    // The same client is served again once it waits for its replies.
    app.ic_call("Reset", &()).await.unwrap();
    app.text.clear();
    app.type_one_by_one("vieetj ").await;
    assert_eq!(app.text, "việt ");
    other.type_one_by_one("vieetj ").await;
    assert_eq!(other.text, "việt ");
}

#[tokio::test]
async fn contexts_per_client_are_capped() {
    let bus = Bus::start("cap");
    let _server = serve(
        &bus,
        Options {
            max_contexts_per_client: 3,
            ..options()
        },
    )
    .await;
    let mut app = App::new(&bus).await;
    let mut ics = Vec::new();
    for _ in 0..3 {
        ics.push(app.create(PORTAL_IM).await.unwrap());
    }
    let err = app.create(PORTAL_IM).await.unwrap_err();
    assert_eq!(error_name(err), "org.freedesktop.DBus.Error.LimitsExceeded");

    app.ic = ics[0].clone();
    app.ic_call("DestroyIC", &()).await.unwrap();
    // The compatibility path works too and hands out a portal path.
    let ic = app.create("/inputmethod").await.unwrap();
    assert!(ic.starts_with("/org/freedesktop/portal/inputcontext/"));
    assert!(!ics.contains(&ic), "paths are never reused");

    // Another client has its own allowance.
    let mut other = App::new(&bus).await;
    other.create(PORTAL_IM).await.unwrap();
}

#[tokio::test]
async fn callers_of_another_uid_are_refused() {
    let bus = Bus::start("uid");
    let _server = serve(
        &bus,
        Options {
            uid: rustix::process::getuid().as_raw() + 1,
            ..options()
        },
    )
    .await;
    let mut app = App::new(&bus).await;
    let err = app
        .call(PORTAL_IM, IM_IFACE, "Version", &())
        .await
        .unwrap_err();
    assert_eq!(error_name(err), "org.freedesktop.DBus.Error.AccessDenied");
    let err = app.create(PORTAL_IM).await.unwrap_err();
    assert_eq!(error_name(err), "org.freedesktop.DBus.Error.AccessDenied");
}

async fn owner_of(conn: &Connection, name: &str) -> Option<String> {
    conn.call_method(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        Some("org.freedesktop.DBus"),
        "GetNameOwner",
        &(name,),
    )
    .await
    .ok()
    .map(|m| m.body().deserialize::<String>().unwrap())
}

#[tokio::test]
async fn owns_both_names_once_ready() {
    let bus = Bus::start("names");
    let conn = bus.connect().await;
    let server_conn = bus.connect().await;
    let unique = server_conn.unique_name().unwrap().as_str().to_owned();
    let ime = SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)));
    let (ready, watch) = Ready::channel();
    let _task = tokio::spawn(fe_fcitx::serve(server_conn, ime, ready, options()));
    assert!(tokio::time::timeout(STEP, watch.wait()).await.unwrap());
    assert_eq!(
        owner_of(&conn, FCITX_NAME).await.as_deref(),
        Some(unique.as_str())
    );
    assert_eq!(
        owner_of(&conn, PORTAL_NAME).await.as_deref(),
        Some(unique.as_str())
    );
}

#[tokio::test]
async fn waits_for_the_previous_owner_to_leave() {
    let bus = Bus::start("handover");
    let fcitx5 = bus.connect().await;
    fcitx5.request_name(FCITX_NAME).await.unwrap();

    let ime = SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)));
    let (ready, watch) = Ready::channel();
    let task = tokio::spawn(fe_fcitx::serve(
        bus.connect().await,
        ime,
        ready,
        Options {
            name_wait: Duration::from_secs(5),
            ..options()
        },
    ));
    let mut watch = std::pin::pin!(watch.wait());
    assert!(
        tokio::time::timeout(Duration::from_millis(600), &mut watch)
            .await
            .is_err(),
        "ready before the name was free"
    );
    fcitx5.release_name(FCITX_NAME).await.unwrap();
    assert!(tokio::time::timeout(STEP, watch).await.unwrap());
    assert!(!task.is_finished());
}

#[tokio::test]
async fn fails_when_the_previous_owner_stays() {
    let bus = Bus::start("stuck");
    let fcitx5 = bus.connect().await;
    fcitx5.request_name(PORTAL_NAME).await.unwrap();

    let ime = SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)));
    let (ready, watch) = Ready::channel();
    let result = tokio::time::timeout(
        STEP,
        fe_fcitx::serve(
            bus.connect().await,
            ime,
            ready,
            Options {
                name_wait: Duration::from_millis(500),
                ..options()
            },
        ),
    )
    .await
    .unwrap();
    let err = result.unwrap_err().to_string();
    assert_eq!(
        err,
        "fcitx: another program still owns the fcitx5 bus names"
    );
    assert!(!watch.wait().await, "never ready");
}

#[tokio::test]
async fn a_client_leaving_does_not_disturb_the_others() {
    let bus = Bus::start("leave");
    let server = serve(&bus, options()).await;
    let mut a = App::open(&bus, VTE_CAPS).await;
    let mut b = App::open(&bus, VTE_CAPS).await;
    a.type_pipelined("vie").await;
    drop(a);
    b.type_pipelined("vieetj ").await;
    assert_eq!(b.text, "việt ");
    let mut c = App::open(&bus, VTE_CAPS).await;
    c.type_pipelined("ddaau ").await;
    assert_eq!(c.text, "đâu ");
    assert!(!server.is_finished());
}

#[tokio::test]
async fn ends_with_an_error_when_the_bus_goes_away() {
    let mut bus = Bus::start("busgone");
    let server = serve(&bus, options()).await;
    bus.child.kill().unwrap();
    bus.child.wait().unwrap();
    let result = tokio::time::timeout(STEP, server).await.unwrap().unwrap();
    assert_eq!(
        result.unwrap_err().to_string(),
        "fcitx: the session bus connection closed"
    );
}
