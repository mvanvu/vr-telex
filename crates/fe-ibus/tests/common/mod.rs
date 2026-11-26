//! A bus in a throwaway directory and a client that plays libibus: it sends
//! the calls GNOME Shell makes (spike T1, Q3) and reads back everything the
//! bus writes, in wire order.
#![allow(dead_code)]

use std::fs;
use std::future::poll_fn;
use std::num::NonZeroU32;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use fe_ibus::{Config, Limits};
use ime_core::{Ime, MemoryStateStore, Mode, Ready, SharedIme};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use zbus::connection::Builder;
use zbus::export::futures_core::Stream;
use zbus::export::serde::Serialize;
use zbus::message::Type;
use zbus::{Connection, DynamicType, Message, MessageStream, Variant};

pub const DBUS: &str = "org.freedesktop.DBus";
pub const DBUS_PATH: &str = "/org/freedesktop/DBus";
pub const IBUS: &str = "org.freedesktop.IBus";
pub const IBUS_PATH: &str = "/org/freedesktop/IBus";
pub const PANEL: &str = "org.freedesktop.IBus.Panel";
pub const CONTEXT: &str = "org.freedesktop.IBus.InputContext";
pub const SERVICE: &str = "org.freedesktop.IBus.Service";
pub const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
pub const MACHINE_ID: &str = "0123456789abcdef0123456789abcdef";

pub const SHIFT: u32 = 1 << 0;
pub const CONTROL: u32 = 1 << 2;
pub const RELEASE: u32 = 1 << 30;
pub const KEY_SPACE: u32 = 0x20;
pub const KEY_TAB: u32 = 0xff09;
pub const KEY_RETURN: u32 = 0xff0d;
pub const KEY_SHIFT_L: u32 = 0xffe1;
pub const KEY_CONTROL_L: u32 = 0xffe3;

const WAIT: Duration = Duration::from_secs(5);

pub fn block_on<F: Future>(test: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(test)
}

fn unique_dir() -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    std::env::temp_dir().join(format!(
        "vr-telex-ibus-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

/// Directories of one test; removed when dropped.
pub struct Sandbox {
    pub dir: PathBuf,
}

impl Sandbox {
    pub fn new() -> Self {
        let dir = unique_dir();
        let _ = fs::remove_dir_all(&dir);
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(dir.join("run"))
            .expect("runtime dir");
        Self { dir }
    }

    pub fn config(&self) -> Config {
        Config {
            runtime_dir: self.dir.join("run"),
            bus_dir: self.dir.join("config").join("ibus").join("bus"),
            address_files: vec![
                format!("{MACHINE_ID}-unix-wayland-0"),
                format!("{MACHINE_ID}-unix-0"),
            ],
            uid: fs::metadata(&self.dir).expect("own dir").uid(),
            limits: Limits::default(),
        }
    }

    pub fn socket(&self) -> PathBuf {
        self.dir.join("run").join("vr-telex").join("ibus")
    }

    pub fn address_file(&self, display: &str) -> PathBuf {
        self.config()
            .bus_dir
            .join(format!("{MACHINE_ID}-unix-{display}"))
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn new_ime() -> SharedIme {
    SharedIme::new(Ime::new(&MemoryStateStore::new(Mode::Vi)))
}

/// A running frontend.
pub struct Bus {
    pub sandbox: Sandbox,
    pub ime: SharedIme,
    pub task: JoinHandle<ime_core::Result<()>>,
}

impl Bus {
    pub async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    pub async fn start_with(adjust: impl FnOnce(&mut Config)) -> Self {
        let sandbox = Sandbox::new();
        let mut config = sandbox.config();
        adjust(&mut config);
        let ime = new_ime();
        let (task, ready) = spawn(config, ime.clone());
        assert!(ready.wait().await, "the frontend did not get ready");
        Self { sandbox, ime, task }
    }

    pub async fn client(&self) -> Client {
        Client::connect(&self.sandbox.socket())
            .await
            .expect("the bus accepts its own user")
    }

    /// A client that said `Hello`.
    pub async fn greeted(&self) -> Client {
        let mut client = self.client().await;
        client.hello().await;
        client
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub fn spawn(
    config: Config,
    ime: SharedIme,
) -> (JoinHandle<ime_core::Result<()>>, ime_core::ReadyWatch) {
    let (ready, watch) = Ready::channel();
    (tokio::spawn(fe_ibus::serve(config, ime, ready)), watch)
}

/// What the bus wrote, reduced to what the tests compare.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Seen {
    /// `UpdatePreeditText` (`mode: None`) or `UpdatePreeditTextWithMode`.
    Preedit {
        text: String,
        cursor: u32,
        visible: bool,
        mode: Option<u32>,
    },
    Commit(String),
    Delete(i32, u32),
    /// `RegisterProperties` / `UpdateProperty` with the symbol they carry.
    Panel(String, String),
    /// Any other signal or call, by member.
    Other(String),
}

fn fields<'a>(value: &'a Variant<'a>) -> &'a [Variant<'a>] {
    match value {
        Variant::Structure(structure) => structure.fields(),
        Variant::Variant(inner) => fields(inner),
        other => panic!("not an IBus object: {}", other.value_signature()),
    }
}

/// The string of an `IBusText`.
pub fn text_of(value: &Variant<'_>) -> String {
    let fields = fields(value);
    assert_eq!(fields[0], Variant::from("IBusText"));
    match &fields[2] {
        Variant::Str(text) => text.as_str().to_owned(),
        _ => panic!("IBusText without a string"),
    }
}

/// The symbol of an `IBusProperty`, after checking that it is `InputMode`.
pub fn symbol_of(property: &Variant<'_>) -> String {
    let fields = fields(property);
    assert_eq!(fields[0], Variant::from("IBusProperty"));
    assert_eq!(fields[2], Variant::from("InputMode"));
    text_of(&fields[11])
}

pub fn seen(message: &Message) -> Seen {
    let header = message.header();
    let member = header.member().expect("member").as_str().to_owned();
    let body = message.body();
    match member.as_str() {
        "UpdatePreeditTextWithMode" => {
            let (text, cursor, visible, mode): (Variant<'_>, u32, bool, u32) =
                body.deserialize().expect("(vubu)");
            Seen::Preedit {
                text: text_of(&text),
                cursor,
                visible,
                mode: Some(mode),
            }
        }
        "UpdatePreeditText" => {
            let (text, cursor, visible): (Variant<'_>, u32, bool) =
                body.deserialize().expect("(vub)");
            Seen::Preedit {
                text: text_of(&text),
                cursor,
                visible,
                mode: None,
            }
        }
        "CommitText" => {
            let (text,): (Variant<'_>,) = body.deserialize().expect("(v)");
            Seen::Commit(text_of(&text))
        }
        "DeleteSurroundingText" => {
            let (offset, chars): (i32, u32) = body.deserialize().expect("(iu)");
            Seen::Delete(offset, chars)
        }
        "UpdateProperty" => {
            assert_eq!(message.message_type(), Type::MethodCall);
            let (property,): (Variant<'_>,) = body.deserialize().expect("(v)");
            Seen::Panel(member, symbol_of(&property))
        }
        "RegisterProperties" => {
            assert_eq!(message.message_type(), Type::MethodCall);
            let (list,): (Variant<'_>,) = body.deserialize().expect("(v)");
            let list = fields(&list);
            assert_eq!(list[0], Variant::from("IBusPropList"));
            let Variant::Array(properties) = &list[2] else {
                panic!("IBusPropList without an array");
            };
            assert_eq!(properties.len(), 1);
            Seen::Panel(member, symbol_of(&properties[0]))
        }
        _ => Seen::Other(member),
    }
}

/// A shown preedit in the "commit" focus mode, as GNOME Shell gets it.
pub fn preedit(text: &str) -> Seen {
    Seen::Preedit {
        text: text.to_owned(),
        cursor: text.chars().count() as u32,
        visible: true,
        mode: Some(1),
    }
}

/// The preedit taken away again.
pub fn hidden(mode: Option<u32>) -> Seen {
    Seen::Preedit {
        text: String::new(),
        cursor: 0,
        visible: false,
        mode,
    }
}

/// The answer to one call and everything written before it.
pub struct Answer {
    pub before: Vec<Seen>,
    pub reply: Message,
}

impl Answer {
    /// The error name, when the call failed.
    pub fn error(&self) -> Option<String> {
        self.reply
            .header()
            .error_name()
            .map(|name| name.as_str().to_owned())
    }

    #[track_caller]
    pub fn ok(self) -> Self {
        assert_eq!(self.error(), None, "the call failed");
        self
    }

    #[track_caller]
    pub fn handled(&self) -> bool {
        assert_eq!(self.error(), None, "the key call failed");
        let (handled,): (bool,) = self.reply.body().deserialize().expect("(b)");
        handled
    }
}

pub struct Client {
    pub connection: Connection,
    stream: MessageStream,
}

impl Client {
    pub async fn connect(socket: &Path) -> zbus::Result<Self> {
        let stream = std::os::unix::net::UnixStream::connect(socket)?;
        // Peer-to-peer on the client side: the library adds no call of its
        // own, so the test decides every message, `Hello` included.
        let connection = Builder::unix_stream(stream).p2p().build().await?;
        let stream = MessageStream::from(&connection);
        Ok(Self { connection, stream })
    }

    /// Sends a call without waiting for its reply, as GNOME Shell does for
    /// the press and the release of a key.
    pub async fn send<B>(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        body: &B,
    ) -> NonZeroU32
    where
        B: Serialize + DynamicType,
    {
        let message = Message::method_call(path, member)
            .destination(destination)
            .interface(interface)
            .build(body)
            .expect("a valid call");
        self.connection.send(&message).await.expect("sent");
        message.primary_header().serial_num()
    }

    /// The next message, or `None` when nothing came within `wait` or the
    /// bus closed the connection.
    pub async fn next(&mut self, wait: Duration) -> Option<Message> {
        let next = poll_fn(|cx| Pin::new(&mut self.stream).poll_next(cx));
        timeout(wait, next).await.ok()?.and_then(Result::ok)
    }

    /// Everything up to the reply to `serial`, in wire order.
    pub async fn answer(&mut self, serial: NonZeroU32) -> Answer {
        let mut before = Vec::new();
        loop {
            let message = self.next(WAIT).await.expect("a reply in time");
            let replies = matches!(message.message_type(), Type::MethodReturn | Type::Error);
            if replies && message.header().reply_serial() == Some(serial) {
                return Answer {
                    before,
                    reply: message,
                };
            }
            before.push(seen(&message));
        }
    }

    pub async fn call<B>(
        &mut self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        body: &B,
    ) -> Answer
    where
        B: Serialize + DynamicType,
    {
        let serial = self.send(destination, path, interface, member, body).await;
        self.answer(serial).await
    }

    /// What arrives within `wait` without having been asked for.
    pub async fn unasked(&mut self, wait: Duration) -> Vec<Seen> {
        let mut all = Vec::new();
        while let Some(message) = self.next(wait).await {
            all.push(seen(&message));
        }
        all
    }

    /// True when the bus closed the connection within the usual wait.
    pub async fn closed(&mut self) -> bool {
        let next = poll_fn(|cx| Pin::new(&mut self.stream).poll_next(cx));
        matches!(timeout(WAIT, next).await, Ok(None | Some(Err(_))))
    }

    pub async fn hello(&mut self) -> String {
        let answer = self.call(DBUS, DBUS_PATH, DBUS, "Hello", &()).await.ok();
        let (name,): (String,) = answer.reply.body().deserialize().expect("(s)");
        let acquired = self.next(WAIT).await.expect("NameAcquired follows");
        assert_eq!(seen(&acquired), Seen::Other("NameAcquired".into()));
        name
    }

    pub async fn bus<B>(&mut self, member: &str, body: &B) -> Answer
    where
        B: Serialize + DynamicType,
    {
        self.call(DBUS, DBUS_PATH, DBUS, member, body).await
    }

    pub async fn ibus<B>(&mut self, member: &str, body: &B) -> Answer
    where
        B: Serialize + DynamicType,
    {
        self.call(IBUS, IBUS_PATH, IBUS, member, body).await
    }

    pub async fn context<B>(&mut self, path: &str, member: &str, body: &B) -> Answer
    where
        B: Serialize + DynamicType,
    {
        self.call(IBUS, path, CONTEXT, member, body).await
    }

    pub async fn set<V>(&mut self, path: &str, property: &str, value: V) -> Answer
    where
        V: Into<Variant<'static>>,
    {
        let body = (CONTEXT, property, value.into());
        self.call(IBUS, path, PROPERTIES, "Set", &body).await
    }

    pub async fn create_context(&mut self) -> String {
        let answer = self.ibus("CreateInputContext", &("test",)).await.ok();
        let (path,): (zbus::OwnedObjectPath,) = answer.reply.body().deserialize().expect("(o)");
        path.as_str().to_owned()
    }

    /// A focused context set up the way GNOME Shell does it: the client
    /// commits its preedit itself, preedit and surrounding text supported.
    pub async fn shell_context(&mut self) -> String {
        let path = self.create_context().await;
        self.set(&path, "ClientCommitPreedit", (true,)).await.ok();
        self.context(&path, "SetCapabilities", &(41u32,)).await.ok();
        self.set(&path, "ContentType", (0u32, 0u32)).await.ok();
        self.context(&path, "FocusIn", &()).await.ok();
        path
    }

    pub async fn key(&mut self, path: &str, keysym: u32, state: u32) -> Answer {
        self.context(path, "ProcessKeyEvent", &(keysym, 0u32, state))
            .await
    }

    /// Press and release of one unmodified key; the answer to the press.
    pub async fn tap(&mut self, path: &str, keysym: u32) -> Answer {
        let press = self.key(path, keysym, 0).await;
        assert!(!self.key(path, keysym, RELEASE).await.handled());
        press
    }

    /// Types letters; returns what the last one caused.
    pub async fn type_letters(&mut self, path: &str, letters: &str) -> Vec<Seen> {
        let mut last = Vec::new();
        for letter in letters.chars() {
            let answer = self.tap(path, letter as u32).await;
            assert!(answer.handled(), "a letter of a word is handled");
            last = answer.before;
        }
        last
    }

    /// Ctrl+Shift tapped alone; everything the four keys caused.
    pub async fn tap_ctrl_shift(&mut self, path: &str) -> Vec<Seen> {
        let mut all = Vec::new();
        for (keysym, state) in [
            (KEY_CONTROL_L, 0),
            (KEY_SHIFT_L, CONTROL),
            (KEY_SHIFT_L, CONTROL | SHIFT | RELEASE),
            (KEY_CONTROL_L, CONTROL | RELEASE),
        ] {
            let answer = self.key(path, keysym, state).await;
            assert!(!answer.handled(), "modifiers always pass");
            all.extend(answer.before);
        }
        all
    }
}
