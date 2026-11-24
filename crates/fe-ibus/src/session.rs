//! One client connection, served by one task from accept to close.
//!
//! Everything a client can name lives in its own session: its input contexts
//! are kept here, so another connection cannot reach them under any path, and
//! every signal is written to this connection only (SEC-9). Messages are
//! handled one at a time in arrival order, and the answer to a key — the
//! signals it causes, then its reply — is on the wire before the next message
//! is read (B2).

use std::collections::HashMap;
use std::future::{Future, poll_fn};
use std::pin::{Pin, pin};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::Poll;
use std::time::Duration;

use ime_core::{Action, Caps, CtxId, KeyEvent, Mode, ModeWatch, Mods, SharedIme};
use tokio::net::UnixStream;
use tokio::time::timeout;
use zbus::connection::{AuthMechanism, Builder};
use zbus::export::futures_core::Stream;
use zbus::message::{Body, Flags, Header, Type};
use zbus::{Connection, DynamicType, Guid, Message, MessageStream, ObjectPath, Variant};

use crate::Limits;
use crate::ibus::{
    self, BUS_NAME, BUS_PATH, CONTEXT_IFACE, CONTEXT_PATH_PREFIX, ENGINE_NAME, IBUS_NAME,
    IBUS_PATH, IBUS_UNIQUE, PANEL_NAME, PANEL_PATH, PEER_IFACE, PROPERTIES_IFACE, SERVICE_IFACE,
};
use crate::socket::{self, Peer};

/// A client gets this long to authenticate before its slot is taken back.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
/// A client that does not read for this long is dropped. Its keys then reach
/// the application untouched, which is better than an input method that
/// answers late.
const SEND_TIMEOUT: Duration = Duration::from_secs(5);
/// How long after clearing the preedit of an address field its word is
/// committed. Mutter sends the text-input `done` of the cleared preedit from
/// an idle callback, normally well within a millisecond; a commit that
/// arrives before it shares that `done`, and Chrome then drops its inline
/// completion, which is no worse than committing without the gap. Short
/// enough that the word is not seen to disappear.
const ADDRESS_COMMIT_GAP: Duration = Duration::from_millis(5);

const ERR_FAILED: &str = "org.freedesktop.DBus.Error.Failed";
const ERR_INVALID_ARGS: &str = "org.freedesktop.DBus.Error.InvalidArgs";
const ERR_UNKNOWN_METHOD: &str = "org.freedesktop.DBus.Error.UnknownMethod";
const ERR_UNKNOWN_OBJECT: &str = "org.freedesktop.DBus.Error.UnknownObject";
const ERR_UNKNOWN_SERVICE: &str = "org.freedesktop.DBus.Error.ServiceUnknown";
const ERR_NO_OWNER: &str = "org.freedesktop.DBus.Error.NameHasNoOwner";
const ERR_ACCESS_DENIED: &str = "org.freedesktop.DBus.Error.AccessDenied";
const ERR_LIMITS: &str = "org.freedesktop.DBus.Error.LimitsExceeded";

/// `RequestName` replies.
const NAME_PRIMARY_OWNER: u32 = 1;
const NAME_EXISTS: u32 = 3;
const NAME_ALREADY_OWNER: u32 = 4;
/// `ReleaseName` replies.
const NAME_RELEASED: u32 = 1;
const NAME_NON_EXISTENT: u32 = 2;
const NAME_NOT_OWNER: u32 = 3;

/// The connection must be closed: the client broke the protocol, went away
/// or stopped reading.
struct Closed;
type Step = Result<(), Closed>;

/// The connection that holds `org.freedesktop.IBus.Panel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PanelOwner {
    pub(crate) connection: u64,
    pub(crate) pid: Option<i32>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Claim {
    Granted,
    AlreadyOwner,
    Refused,
}

/// Decides who is the panel (SEC-10). There is one at a time: the first
/// connection that asks. A later one gets the role only when it comes from
/// the same process — GNOME Shell connecting again after the address
/// changed, possibly before the close of its old connection was seen here.
/// Any other process is refused while the panel is connected.
pub(crate) fn claim_panel(slot: &mut Option<PanelOwner>, who: PanelOwner) -> Claim {
    match *slot {
        Some(owner) if owner.connection == who.connection => Claim::AlreadyOwner,
        Some(owner) if owner.pid.is_none() || owner.pid != who.pid => Claim::Refused,
        _ => {
            *slot = Some(who);
            Claim::Granted
        }
    }
}

/// What all sessions share.
pub(crate) struct Shared {
    ime: SharedIme,
    limits: Limits,
    guid: Guid<'static>,
    panel: Mutex<Option<PanelOwner>>,
    /// Input context numbers are never reused, across all connections.
    next_context: AtomicU64,
}

impl Shared {
    pub(crate) fn new(ime: SharedIme, limits: Limits, guid: Guid<'static>) -> Self {
        Self {
            ime,
            limits,
            guid,
            panel: Mutex::new(None),
            next_context: AtomicU64::new(0),
        }
    }

    fn panel(&self) -> MutexGuard<'_, Option<PanelOwner>> {
        // The slot is a plain value: whatever a panicked holder left is whole.
        self.panel
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn unique_name(connection: u64) -> String {
    format!(":1.{connection}")
}

fn context_path(number: u64) -> String {
    format!("{CONTEXT_PATH_PREFIX}{number}")
}

/// Why the actions being sent were produced.
#[derive(Clone, Copy)]
enum Cause {
    /// A key, or a change of the field's kind.
    Engine,
    /// The client's `FocusOut`.
    FocusOut,
    /// The client's `Reset`.
    Reset,
}

/// An input context as this frontend sees it.
struct Context {
    id: CtxId,
    /// `SetCapabilities` bits.
    capabilities: u32,
    /// `ContentType` property.
    purpose: u32,
    hints: u32,
    /// The client set `ClientCommitPreedit`: it commits the preedit it shows
    /// by itself when the field loses focus or is reset.
    client_commit: bool,
    /// A preedit is on the client's screen.
    preedit_shown: bool,
}

impl Context {
    /// `shell`: the context belongs to GNOME Shell (`Session::is_shell`).
    ///
    /// The shell is never offered the surrounding-text way of editing,
    /// whatever it declares: Mutter 46 aborts, and the desktop session with
    /// it, on a `DeleteSurroundingText` that does not fit the surrounding
    /// text it holds, and that text lags behind the keys.
    fn caps(&self, shell: bool) -> Caps {
        Caps {
            preedit: self.capabilities & ibus::CAP_PREEDIT_TEXT != 0,
            surrounding_text: !shell && self.capabilities & ibus::CAP_SURROUNDING_TEXT != 0,
            password: ibus::is_private(self.purpose, self.hints),
        }
    }
}

enum Event {
    Message(Option<zbus::Result<Message>>),
    Mode(Option<Mode>),
}

/// The next message of the client, or a mode change made anywhere.
async fn next_event(messages: &mut MessageStream, watch: Option<&mut ModeWatch>) -> Event {
    let mut next = |cx: &mut std::task::Context<'_>| Pin::new(&mut *messages).poll_next(cx);
    let Some(watch) = watch else {
        return Event::Message(poll_fn(next).await);
    };
    let mut changed = pin!(watch.changed());
    poll_fn(|cx| match next(cx) {
        Poll::Ready(message) => Poll::Ready(Event::Message(message)),
        Poll::Pending => changed.as_mut().poll(cx).map(Event::Mode),
    })
    .await
}

/// Serves one client until it leaves or has to be dropped.
pub(crate) async fn serve(stream: UnixStream, id: u64, peer: Peer, shared: Arc<Shared>) {
    let split = socket::capped(stream, peer, shared.limits.message_bytes);
    let handshake = Builder::socket(split)
        .server(shared.guid.clone())
        .p2p()
        // The only mechanism: no ANONYMOUS, no cookie file (SEC-8).
        .auth_mechanism(AuthMechanism::External)
        // A body that does not match its signature ends the connection
        // instead of reaching a handler (SEC-15).
        .validate_bodies()
        .build_message_stream();
    let Ok(Ok(mut messages)) = timeout(HANDSHAKE_TIMEOUT, handshake).await else {
        return;
    };
    let mut watch = Some(shared.ime.subscribe_mode());
    let mut session = Session {
        id,
        unique: unique_name(id),
        pid: peer.pid,
        connection: Connection::from(&messages),
        shared,
        greeted: false,
        contexts: HashMap::new(),
    };
    loop {
        let step = match next_event(&mut messages, watch.as_mut()).await {
            Event::Message(Some(Ok(message))) => session.handle(&message, watch.as_mut()).await,
            // The client left, or sent something that is not D-Bus.
            Event::Message(_) => break,
            Event::Mode(Some(mode)) => session.update_property(mode).await,
            Event::Mode(None) => {
                watch = None;
                Ok(())
            }
        };
        if step.is_err() {
            break;
        }
    }
}

struct Session {
    id: u64,
    unique: String,
    pid: Option<i32>,
    connection: Connection,
    shared: Arc<Shared>,
    /// `Hello` was called; nothing else is answered before.
    greeted: bool,
    /// The contexts this connection created, by the number in their path.
    contexts: HashMap<u64, Context>,
}

impl Drop for Session {
    fn drop(&mut self) {
        // The client is gone: what its contexts would still commit has no
        // reader, and the words must not stay in memory (SEC-4).
        for context in self.contexts.values() {
            drop(self.shared.ime.destroy_context(context.id));
        }
        let mut panel = self.shared.panel();
        if panel.is_some_and(|owner| owner.connection == self.id) {
            *panel = None;
        }
    }
}

impl Session {
    async fn send(&self, message: zbus::Result<Message>) -> Step {
        let message = message.map_err(|_| Closed)?;
        match timeout(SEND_TIMEOUT, self.connection.send(&message)).await {
            Ok(Ok(())) => Ok(()),
            _ => Err(Closed),
        }
    }

    async fn reply<B>(&self, call: &Header<'_>, from: &str, body: &B) -> Step
    where
        B: zbus::export::serde::Serialize + DynamicType,
    {
        if call.primary().flags().contains(Flags::NO_REPLY_EXPECTED) {
            return Ok(());
        }
        self.send(Message::method_return(call).sender(from).build(body))
            .await
    }

    async fn error(&self, call: &Header<'_>, from: &str, name: &str, text: &str) -> Step {
        if call.primary().flags().contains(Flags::NO_REPLY_EXPECTED) {
            return Ok(());
        }
        self.send(Message::error(call, name).sender(from).build(&(text,)))
            .await
    }

    async fn signal<B>(&self, path: &str, interface: &str, member: &str, body: &B) -> Step
    where
        B: zbus::export::serde::Serialize + DynamicType,
    {
        self.send(
            Message::signal(path, interface, member)
                .sender(IBUS_UNIQUE)
                .destination(self.unique.as_str())
                .build(body),
        )
        .await
    }

    fn is_panel(&self) -> bool {
        self.shared
            .panel()
            .is_some_and(|owner| owner.connection == self.id)
    }

    /// True when `context` is one of GNOME Shell's: the shell owns the panel
    /// and is the client that commits its preedit itself.
    fn is_shell(&self, context: &Context) -> bool {
        context.client_commit || self.is_panel()
    }

    /// A call to the panel object GNOME Shell serves on this connection.
    async fn panel_call(&self, member: &str, value: zbus::Result<Variant<'_>>) -> Step {
        if !self.is_panel() {
            return Ok(());
        }
        let value = value.map_err(|_| Closed)?;
        self.send(
            Message::method_call(PANEL_PATH, member)
                .interface(PANEL_NAME)
                .destination(PANEL_NAME)
                .sender(IBUS_UNIQUE)
                .with_flags(Flags::NO_REPLY_EXPECTED)
                .build(&(value,)),
        )
        .await
    }

    /// Hands the panel the engine's properties: the shell takes them once
    /// after each engine change and builds the indicator from them.
    async fn register_properties(&self) -> Step {
        let mode = self.shared.ime.mode();
        self.panel_call("RegisterProperties", ibus::mode_property_list(mode))
            .await
    }

    /// Shows a new mode in the indicator.
    async fn update_property(&self, mode: Mode) -> Step {
        self.panel_call("UpdateProperty", ibus::mode_property(mode))
            .await
    }

    async fn handle(&mut self, message: &Message, watch: Option<&mut ModeWatch>) -> Step {
        // Replies to panel calls and signals of the client need no answer.
        if message.message_type() != Type::MethodCall {
            return Ok(());
        }
        let call = message.header();
        let body = message.body();
        let (Some(path), Some(member)) = (call.path(), call.member()) else {
            return Err(Closed);
        };
        let (path, member) = (path.as_str(), member.as_str());
        let interface = call.interface().map(|name| name.as_str());
        let to_bus = match call.destination().map(|name| name.as_str()) {
            Some(BUS_NAME) => true,
            None | Some(IBUS_NAME | IBUS_UNIQUE) => false,
            // Nothing is routed between clients.
            Some(_) => {
                return self
                    .error(&call, BUS_NAME, ERR_UNKNOWN_SERVICE, "No such service")
                    .await;
            }
        };

        if !self.greeted {
            if !(to_bus && member == "Hello") {
                self.error(&call, BUS_NAME, ERR_ACCESS_DENIED, "Hello comes first")
                    .await?;
                return Err(Closed);
            }
            self.greeted = true;
            self.reply(&call, BUS_NAME, &(self.unique.as_str(),))
                .await?;
            return self.name_acquired(&self.unique).await;
        }
        if interface == Some(PEER_IFACE) && member == "Ping" {
            let from = if to_bus { BUS_NAME } else { IBUS_UNIQUE };
            return self.reply(&call, from, &()).await;
        }
        if to_bus {
            return self.bus_call(&call, member, &body).await;
        }
        if path == IBUS_PATH {
            return self.ibus_call(&call, interface, member, &body).await;
        }
        let number = path
            .strip_prefix(CONTEXT_PATH_PREFIX)
            .and_then(|number| number.parse::<u64>().ok())
            // Also unknown: a context of another connection (SEC-9).
            .filter(|number| self.contexts.contains_key(number));
        match number {
            Some(number) => {
                self.context_call(&call, number, interface, member, &body, watch)
                    .await
            }
            None => self.unknown(&call, ERR_UNKNOWN_OBJECT).await,
        }
    }

    async fn unknown(&self, call: &Header<'_>, name: &str) -> Step {
        self.error(call, IBUS_UNIQUE, name, "Not supported").await
    }

    async fn invalid(&self, call: &Header<'_>, from: &str) -> Step {
        self.error(call, from, ERR_INVALID_ARGS, "Invalid arguments")
            .await
    }

    async fn name_acquired(&self, name: &str) -> Step {
        self.send(
            Message::signal(BUS_PATH, BUS_NAME, "NameAcquired")
                .sender(BUS_NAME)
                .destination(self.unique.as_str())
                .build(&(name,)),
        )
        .await
    }

    /// The unique name behind `name`, as far as this client may know.
    fn owner_of(&self, name: &str) -> Option<String> {
        match name {
            BUS_NAME => Some(BUS_NAME.to_owned()),
            IBUS_NAME | IBUS_UNIQUE => Some(IBUS_UNIQUE.to_owned()),
            PANEL_NAME => self
                .shared
                .panel()
                .map(|owner| unique_name(owner.connection)),
            own if own == self.unique => Some(self.unique.clone()),
            _ => None,
        }
    }

    /// `org.freedesktop.DBus`: the part of a message bus the clients use.
    async fn bus_call(&mut self, call: &Header<'_>, member: &str, body: &Body) -> Step {
        match member {
            "Hello" => {
                self.error(call, BUS_NAME, ERR_FAILED, "Already said Hello")
                    .await
            }
            "RequestName" => {
                let Ok((name, _flags)) = body.deserialize::<(&str, u32)>() else {
                    return self.invalid(call, BUS_NAME).await;
                };
                if name != PANEL_NAME {
                    return self
                        .error(call, BUS_NAME, ERR_ACCESS_DENIED, "Name not available")
                        .await;
                }
                let who = PanelOwner {
                    connection: self.id,
                    pid: self.pid,
                };
                let claim = claim_panel(&mut self.shared.panel(), who);
                match claim {
                    Claim::Granted => {
                        self.reply(call, BUS_NAME, &(NAME_PRIMARY_OWNER,)).await?;
                        self.name_acquired(PANEL_NAME).await?;
                        // Contexts made before the claim are the shell's now.
                        let numbers: Vec<u64> = self.contexts.keys().copied().collect();
                        for number in numbers {
                            self.apply_caps(number).await?;
                        }
                        Ok(())
                    }
                    Claim::AlreadyOwner => self.reply(call, BUS_NAME, &(NAME_ALREADY_OWNER,)).await,
                    Claim::Refused => self.reply(call, BUS_NAME, &(NAME_EXISTS,)).await,
                }
            }
            "ReleaseName" => {
                let Ok((name,)) = body.deserialize::<(&str,)>() else {
                    return self.invalid(call, BUS_NAME).await;
                };
                let result = if name != PANEL_NAME {
                    NAME_NON_EXISTENT
                } else {
                    let mut panel = self.shared.panel();
                    match *panel {
                        Some(owner) if owner.connection == self.id => {
                            *panel = None;
                            NAME_RELEASED
                        }
                        Some(_) => NAME_NOT_OWNER,
                        None => NAME_NON_EXISTENT,
                    }
                };
                self.reply(call, BUS_NAME, &(result,)).await
            }
            "GetNameOwner" => {
                let Ok((name,)) = body.deserialize::<(&str,)>() else {
                    return self.invalid(call, BUS_NAME).await;
                };
                match self.owner_of(name) {
                    Some(owner) => self.reply(call, BUS_NAME, &(owner,)).await,
                    None => {
                        self.error(call, BUS_NAME, ERR_NO_OWNER, "Name has no owner")
                            .await
                    }
                }
            }
            "NameHasOwner" => {
                let Ok((name,)) = body.deserialize::<(&str,)>() else {
                    return self.invalid(call, BUS_NAME).await;
                };
                let owned = self.owner_of(name).is_some();
                self.reply(call, BUS_NAME, &(owned,)).await
            }
            "ListNames" => {
                let mut names = vec![BUS_NAME, IBUS_NAME, self.unique.as_str()];
                if self.shared.panel().is_some() {
                    names.push(PANEL_NAME);
                }
                self.reply(call, BUS_NAME, &(names,)).await
            }
            // Signals go only to the connection they concern, whatever it
            // subscribed to, so match rules are accepted and not kept.
            "AddMatch" | "RemoveMatch" => match body.deserialize::<(&str,)>() {
                Ok(_) => self.reply(call, BUS_NAME, &()).await,
                Err(_) => self.invalid(call, BUS_NAME).await,
            },
            _ => {
                self.error(call, BUS_NAME, ERR_UNKNOWN_METHOD, "Not supported")
                    .await
            }
        }
    }

    /// The bus-level IBus object at `/org/freedesktop/IBus` (SEC-11: only
    /// what GNOME Shell and the toolkit modules call).
    async fn ibus_call(
        &mut self,
        call: &Header<'_>,
        interface: Option<&str>,
        member: &str,
        body: &Body,
    ) -> Step {
        let engines = || ibus::engine_list().map(Variant::from);
        let global = || ibus::engine_desc().map(|desc| Variant::Variant(Box::new(desc)));
        match (interface, member) {
            (Some(PROPERTIES_IFACE), "Get") => {
                let Ok((_, name)) = body.deserialize::<(&str, &str)>() else {
                    return self.invalid(call, IBUS_UNIQUE).await;
                };
                let value = match name {
                    "Engines" | "ActiveEngines" => engines(),
                    "GlobalEngine" => global(),
                    "EmbedPreeditText" => Ok(Variant::Bool(true)),
                    _ => return self.invalid(call, IBUS_UNIQUE).await,
                };
                let value = value.map_err(|_| Closed)?;
                self.reply(call, IBUS_UNIQUE, &(value,)).await?;
                if name == "GlobalEngine" {
                    self.register_properties().await?;
                }
                Ok(())
            }
            (Some(PROPERTIES_IFACE), "GetAll") => {
                let mut all = HashMap::new();
                all.insert("Engines", engines().map_err(|_| Closed)?);
                all.insert("ActiveEngines", engines().map_err(|_| Closed)?);
                all.insert("GlobalEngine", global().map_err(|_| Closed)?);
                all.insert("EmbedPreeditText", Variant::Bool(true));
                self.reply(call, IBUS_UNIQUE, &(all,)).await
            }
            (Some(PROPERTIES_IFACE), "Set") => {
                match body.deserialize::<(&str, &str, Variant<'_>)>() {
                    // Settings of ibus-daemon that have no meaning here.
                    Ok((_, "PreloadEngines" | "EmbedPreeditText", _)) => {
                        self.reply(call, IBUS_UNIQUE, &()).await
                    }
                    _ => self.invalid(call, IBUS_UNIQUE).await,
                }
            }
            (None | Some(IBUS_NAME), "CreateInputContext") => {
                if body.deserialize::<(&str,)>().is_err() {
                    return self.invalid(call, IBUS_UNIQUE).await;
                }
                if self.contexts.len() >= self.shared.limits.contexts_per_connection {
                    return self
                        .error(call, IBUS_UNIQUE, ERR_LIMITS, "Too many input contexts")
                        .await;
                }
                let number = self.shared.next_context.fetch_add(1, Ordering::Relaxed) + 1;
                let path = context_path(number);
                let Ok(object) = ObjectPath::try_from(path.as_str()) else {
                    return Err(Closed);
                };
                self.contexts.insert(
                    number,
                    Context {
                        id: self.shared.ime.create_context(),
                        capabilities: 0,
                        purpose: 0,
                        hints: 0,
                        client_commit: false,
                        preedit_shown: false,
                    },
                );
                self.reply(call, IBUS_UNIQUE, &(object,)).await
            }
            (None | Some(IBUS_NAME), "SetGlobalEngine") => {
                match body.deserialize::<(&str,)>() {
                    Ok((ENGINE_NAME,)) => {}
                    _ => return self.invalid(call, IBUS_UNIQUE).await,
                }
                self.reply(call, IBUS_UNIQUE, &()).await?;
                self.signal(IBUS_PATH, IBUS_NAME, "GlobalEngineChanged", &(ENGINE_NAME,))
                    .await?;
                self.register_properties().await
            }
            (None | Some(IBUS_NAME), "GetGlobalEngine") => {
                let desc = ibus::engine_desc().map_err(|_| Closed)?;
                self.reply(call, IBUS_UNIQUE, &(desc,)).await?;
                self.register_properties().await
            }
            (None | Some(IBUS_NAME), "ListEngines" | "ListActiveEngines") => {
                let list = ibus::engine_list().map_err(|_| Closed)?;
                self.reply(call, IBUS_UNIQUE, &(list,)).await
            }
            (None | Some(IBUS_NAME), "IsGlobalEngineEnabled" | "GetUseGlobalEngine") => {
                self.reply(call, IBUS_UNIQUE, &(true,)).await
            }
            _ => self.unknown(call, ERR_UNKNOWN_METHOD).await,
        }
    }

    /// An input context of this connection.
    async fn context_call(
        &mut self,
        call: &Header<'_>,
        number: u64,
        interface: Option<&str>,
        member: &str,
        body: &Body,
        watch: Option<&mut ModeWatch>,
    ) -> Step {
        let Some(id) = self.contexts.get(&number).map(|context| context.id) else {
            return self.unknown(call, ERR_UNKNOWN_OBJECT).await;
        };
        let ime = self.shared.ime.clone();
        match (interface, member) {
            (None | Some(CONTEXT_IFACE), "ProcessKeyEvent") => {
                let Ok((keysym, keycode, state)) = body.deserialize::<(u32, u32, u32)>() else {
                    return self.invalid(call, IBUS_UNIQUE).await;
                };
                let result = ime.process_key(
                    id,
                    KeyEvent {
                        keysym,
                        keycode,
                        state: Mods(state),
                        is_release: state & ibus::RELEASE_MASK != 0,
                    },
                );
                self.emit(number, &result.actions, Cause::Engine).await?;
                self.reply(call, IBUS_UNIQUE, &(result.handled,)).await?;
                // A Ctrl+Shift tap ended with this key: show the new mode
                // right behind the reply.
                match watch.and_then(ModeWatch::try_changed) {
                    Some(mode) => self.update_property(mode).await,
                    None => Ok(()),
                }
            }
            (None | Some(CONTEXT_IFACE), "FocusIn") => {
                ime.focus_in(id);
                self.reply(call, IBUS_UNIQUE, &()).await?;
                self.register_properties().await
            }
            (None | Some(CONTEXT_IFACE), "FocusOut") => {
                let actions = ime.focus_out(id);
                self.emit(number, &actions, Cause::FocusOut).await?;
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (None | Some(CONTEXT_IFACE), "Reset") => {
                let actions = ime.reset(id);
                self.emit(number, &actions, Cause::Reset).await?;
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (None | Some(CONTEXT_IFACE), "SetCapabilities") => {
                let Ok((capabilities,)) = body.deserialize::<(u32,)>() else {
                    return self.invalid(call, IBUS_UNIQUE).await;
                };
                if let Some(context) = self.contexts.get_mut(&number) {
                    context.capabilities = capabilities;
                }
                self.apply_caps(number).await?;
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            // The cursor rectangle follows every preedit change; it is not a
            // cursor move by the user and must not end the word.
            (None | Some(CONTEXT_IFACE), "SetCursorLocation" | "SetCursorLocationRelative") => {
                match body.deserialize::<(i32, i32, i32, i32)>() {
                    Ok(_) => self.reply(call, IBUS_UNIQUE, &()).await,
                    Err(_) => self.invalid(call, IBUS_UNIQUE).await,
                }
            }
            // The engine never asks for the text around the cursor and keeps
            // none of it (SEC-4): the message is dropped unread.
            (None | Some(CONTEXT_IFACE), "SetSurroundingText") => {
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (None | Some(CONTEXT_IFACE), "SetEngine") => match body.deserialize::<(&str,)>() {
                Ok((ENGINE_NAME,)) => self.reply(call, IBUS_UNIQUE, &()).await,
                _ => self.invalid(call, IBUS_UNIQUE).await,
            },
            (None | Some(CONTEXT_IFACE), "GetEngine") => {
                let desc = ibus::engine_desc().map_err(|_| Closed)?;
                self.reply(call, IBUS_UNIQUE, &(desc,)).await
            }
            // A click on the indicator's menu entry: there is nothing to do.
            (None | Some(CONTEXT_IFACE), "PropertyActivate") => {
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (None | Some(SERVICE_IFACE), "Destroy") => {
                self.contexts.remove(&number);
                // The context is gone on the client's side: nothing can be
                // sent for it any more.
                drop(ime.destroy_context(id));
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (Some(PROPERTIES_IFACE), "GetAll") => {
                let none: HashMap<&str, Variant<'_>> = HashMap::new();
                self.reply(call, IBUS_UNIQUE, &(none,)).await
            }
            (Some(PROPERTIES_IFACE), "Set") => {
                let Ok((_, name, value)) = body.deserialize::<(&str, &str, Variant<'_>)>() else {
                    return self.invalid(call, IBUS_UNIQUE).await;
                };
                let Some(context) = self.contexts.get_mut(&number) else {
                    return Err(Closed);
                };
                match name {
                    "ContentType" => {
                        let Some((purpose, hints)) = ibus::content_type(&value) else {
                            return self.invalid(call, IBUS_UNIQUE).await;
                        };
                        context.purpose = purpose;
                        context.hints = hints;
                        self.apply_caps(number).await?;
                    }
                    "ClientCommitPreedit" => {
                        let Some(client_commit) = ibus::flag(&value) else {
                            return self.invalid(call, IBUS_UNIQUE).await;
                        };
                        context.client_commit = client_commit;
                        self.apply_caps(number).await?;
                    }
                    _ => return self.invalid(call, IBUS_UNIQUE).await,
                }
                self.reply(call, IBUS_UNIQUE, &()).await
            }
            (Some(PROPERTIES_IFACE), "Get") => self.invalid(call, IBUS_UNIQUE).await,
            _ => self.unknown(call, ERR_UNKNOWN_METHOD).await,
        }
    }

    /// Tells the IME what the client can do and what kind of field it is in.
    /// A word typed before the change is committed first (SEC-13).
    async fn apply_caps(&mut self, number: u64) -> Step {
        let Some(context) = self.contexts.get(&number) else {
            return Ok(());
        };
        let caps = context.caps(self.is_shell(context));
        let actions = self.shared.ime.set_caps(context.id, caps);
        self.emit(number, &actions, Cause::Engine).await
    }

    /// Sends the client what the IME decided, in order.
    ///
    /// `cause`: what the client asked when the actions answer its `FocusOut`
    /// or `Reset`. The commit of a word whose preedit the client shows is
    /// then not sent when the client has already inserted that preedit
    /// itself, because a second copy would be inserted:
    /// - a client that set `ClientCommitPreedit` (GNOME Shell) commits it on
    ///   both, as the preedit was sent with the "commit" focus mode. Leaving
    ///   the commit to the client is what keeps the word when the focus
    ///   moves by a pointer click: a `CommitText` sent after the field lost
    ///   focus arrives too late to be inserted there;
    /// - Qt 5 (`QIBusPlatformInputContext::commit`, called on every focus
    ///   change and click) inserts its preedit and only then sends `Reset`;
    ///   its `FocusOut` follows that `Reset`, with nothing left to commit.
    async fn emit(&mut self, number: u64, actions: &[Action], cause: Cause) -> Step {
        let Some(context) = self.contexts.get(&number) else {
            return Ok(());
        };
        let with_mode = context.client_commit;
        let shell = self.is_shell(context);
        let address = with_mode && context.purpose == ibus::PURPOSE_URL;
        let mut shown = context.preedit_shown;
        let skip_commit = shown
            && match cause {
                Cause::Reset => true,
                Cause::FocusOut => with_mode,
                Cause::Engine => false,
            };

        // The IME ends a word with "hide the preedit, commit the text". Sent
        // in that order the client first sees its composition cancelled and
        // then an unrelated insertion, in two steps; some clients (xterm.js)
        // lose or repeat text between the two when keys follow closely.
        // Commit first: the commit replaces the preedit in one step, and
        // the hide that follows only clears what the client still remembers.
        //
        // An address field (Chrome's address bar, through GNOME Shell) needs
        // the opposite. Chrome works out its inline completion while it
        // applies the commit, and deletes it again when the preedit changes
        // in the same text-input `done`: the preedit has to be gone before,
        // in a `done` of its own (`ADDRESS_COMMIT_GAP`). Enter then goes to
        // the completed address and Tab accepts it, as without an IME.
        let mut plan: Vec<&Action> = Vec::with_capacity(actions.len());
        for action in actions {
            match (plan.last(), action) {
                (Some(Action::HidePreedit), Action::Commit(_)) if skip_commit => {}
                (Some(Action::HidePreedit), Action::Commit(_)) if address => plan.push(action),
                (Some(Action::HidePreedit), Action::Commit(_)) => {
                    let hide = plan.pop();
                    plan.push(action);
                    plan.extend(hide);
                }
                _ => plan.push(action),
            }
        }

        let path = context_path(number);
        let mut result = Ok(());
        let mut plan = plan.into_iter().peekable();
        while let Some(action) = plan.next() {
            result = match action {
                Action::UpdatePreedit { text, cursor } => {
                    shown = true;
                    self.preedit(&path, ibus::preedit_text(text), *cursor, true, with_mode)
                        .await
                }
                Action::HidePreedit => {
                    shown = false;
                    let sent = self
                        .preedit(&path, ibus::text(""), 0, false, with_mode)
                        .await;
                    if address && matches!(plan.peek(), Some(Action::Commit(_))) {
                        tokio::time::sleep(ADDRESS_COMMIT_GAP).await;
                    }
                    sent
                }
                Action::Commit(text) => match ibus::text(text) {
                    Ok(text) => {
                        self.signal(&path, CONTEXT_IFACE, "CommitText", &(text,))
                            .await
                    }
                    Err(_) => Err(Closed),
                },
                // Unreachable while `Context::caps` keeps the shell out of
                // the surrounding-text way of editing; a wrong word is still
                // better than a desktop session that goes down.
                Action::DeleteSurrounding { .. } if shell => Ok(()),
                Action::DeleteSurrounding { offset, chars } => {
                    self.signal(
                        &path,
                        CONTEXT_IFACE,
                        "DeleteSurroundingText",
                        &(*offset, *chars),
                    )
                    .await
                }
            };
            if result.is_err() {
                break;
            }
        }
        if let Some(context) = self.contexts.get_mut(&number) {
            context.preedit_shown = shown;
        }
        result
    }

    async fn preedit(
        &self,
        path: &str,
        text: zbus::Result<Variant<'_>>,
        cursor: u32,
        visible: bool,
        with_mode: bool,
    ) -> Step {
        let text = text.map_err(|_| Closed)?;
        if with_mode {
            // "Commit" focus mode: the client commits this preedit itself
            // when the field loses focus or is reset.
            let mode = if visible {
                ibus::PREEDIT_COMMIT
            } else {
                ibus::PREEDIT_CLEAR
            };
            let body = (text, cursor, visible, mode);
            self.signal(path, CONTEXT_IFACE, "UpdatePreeditTextWithMode", &body)
                .await
        } else {
            let body = (text, cursor, visible);
            self.signal(path, CONTEXT_IFACE, "UpdatePreeditText", &body)
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner(connection: u64, pid: i32) -> PanelOwner {
        PanelOwner {
            connection,
            pid: Some(pid),
        }
    }

    #[test]
    fn the_first_connection_that_asks_is_the_panel() {
        let mut slot = None;
        assert_eq!(claim_panel(&mut slot, owner(1, 10)), Claim::Granted);
        assert_eq!(slot, Some(owner(1, 10)));
        assert_eq!(claim_panel(&mut slot, owner(1, 10)), Claim::AlreadyOwner);
    }

    #[test]
    fn another_process_cannot_take_the_panel_role() {
        let mut slot = Some(owner(1, 10));
        assert_eq!(claim_panel(&mut slot, owner(2, 11)), Claim::Refused);
        assert_eq!(slot, Some(owner(1, 10)));
    }

    #[test]
    fn the_same_process_takes_the_role_over_with_a_new_connection() {
        let mut slot = Some(owner(1, 10));
        assert_eq!(claim_panel(&mut slot, owner(2, 10)), Claim::Granted);
        assert_eq!(slot, Some(owner(2, 10)));
    }

    #[test]
    fn an_owner_of_unknown_process_is_never_replaced() {
        let unknown = PanelOwner {
            connection: 1,
            pid: None,
        };
        let mut slot = Some(unknown);
        let other = PanelOwner {
            connection: 2,
            pid: None,
        };
        assert_eq!(claim_panel(&mut slot, other), Claim::Refused);
        assert_eq!(slot, Some(unknown));
    }
}
