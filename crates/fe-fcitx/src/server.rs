//! The bus side: names, the reader, one task per client connection.

use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use futures_core::Stream;
use ime_core::{Action, Ready, SharedIme};
use tokio::sync::mpsc::{self, error::TrySendError};
use zbus::fdo;
use zbus::message::{Flags, Type};
use zbus::{Connection, Message, MessageStream};

use crate::contexts::{Contexts, IC_PREFIX, ic_path};
use crate::wire::{
    FORMAT_UNDERLINE, byte_cursor, caps_from_fcitx, create_args_ok, key_event, peer_allowed,
};
use crate::{FCITX_NAME, Options, PORTAL_NAME};

const IM_IFACE: &str = "org.fcitx.Fcitx.InputMethod1";
const IC_IFACE: &str = "org.fcitx.Fcitx.InputContext1";
/// fcitx5 serves `InputMethod1` at both; fcitx5-gtk uses the first.
const IM_PATHS: [&str; 2] = ["/org/freedesktop/portal/inputmethod", "/inputmethod"];

const BUS_NAME: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";
/// RequestName: do not queue behind the owner; we never allow replacement,
/// so no other process can take the clients over while we run.
const DO_NOT_QUEUE: u32 = 4;
const PRIMARY_OWNER: u32 = 1;
const ALREADY_OWNER: u32 = 4;
const NAME_RETRY: Duration = Duration::from_millis(200);

struct Shared {
    conn: Connection,
    ime: SharedIme,
    opts: Options,
    next_ic: AtomicU64,
}

/// Serves fcitx5 clients on `conn` (a bus connection) until the bus goes away.
///
/// Waits up to `opts.name_wait` for both names (a running fcitx5 must quit
/// first), calls `ready.notify()` once it owns them, then returns only with
/// an error.
pub async fn serve(
    conn: Connection,
    ime: SharedIme,
    ready: Ready,
    opts: Options,
) -> ime_core::Result<()> {
    // Made before the names are owned, so the first call cannot be missed.
    let mut stream = MessageStream::from(&conn);
    bus_call(
        &conn,
        "AddMatch",
        &(
            "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',\
           member='NameOwnerChanged',path='/org/freedesktop/DBus'",
        ),
    )
    .await
    .map_err(|_| "fcitx: cannot watch client connections")?;
    acquire_names(&conn, opts.name_wait).await?;
    ready.notify();

    let shared = Arc::new(Shared {
        conn,
        ime,
        opts,
        next_ic: AtomicU64::new(0),
    });
    let mut clients: HashMap<String, mpsc::Sender<Message>> = HashMap::new();
    loop {
        let msg = match next(&mut stream).await {
            None => return Err("fcitx: the session bus connection closed".into()),
            // One unreadable message; the connection itself goes on.
            Some(Err(_)) => continue,
            Some(Ok(msg)) => msg,
        };
        match msg.message_type() {
            Type::MethodCall => route(&shared, &mut clients, msg).await,
            Type::Signal => {
                if let Some(gone) = disconnected(&msg) {
                    // Closing the queue ends the task once it has handled
                    // what the client sent before it left.
                    clients.remove(&gone);
                }
            }
            _ => {}
        }
    }
}

async fn next(stream: &mut MessageStream) -> Option<zbus::Result<Message>> {
    std::future::poll_fn(|cx| Pin::new(&mut *stream).poll_next(cx)).await
}

/// Takes both names, waiting while another process (fcitx5) still has them.
async fn acquire_names(conn: &Connection, wait: Duration) -> ime_core::Result<()> {
    let deadline = Instant::now() + wait;
    for name in [FCITX_NAME, PORTAL_NAME] {
        loop {
            let reply = bus_call(conn, "RequestName", &(name, DO_NOT_QUEUE))
                .await
                .and_then(|m| m.body().deserialize::<u32>())
                .map_err(|_| "fcitx: cannot request a bus name")?;
            if reply == PRIMARY_OWNER || reply == ALREADY_OWNER {
                break;
            }
            if Instant::now() >= deadline {
                return Err("fcitx: another program still owns the fcitx5 bus names".into());
            }
            tokio::time::sleep(NAME_RETRY).await;
        }
    }
    Ok(())
}

async fn bus_call<B>(conn: &Connection, method: &str, body: &B) -> zbus::Result<Message>
where
    B: serde::Serialize + zbus::wire::DynamicType,
{
    conn.call_method(Some(BUS_NAME), BUS_PATH, Some(BUS_NAME), method, body)
        .await
}

/// The unique name of a connection that left the bus, from the bus's own
/// `NameOwnerChanged`; a look-alike signal from a client is ignored.
fn disconnected(msg: &Message) -> Option<String> {
    let h = msg.header();
    if h.sender().map(|s| s.as_str()) != Some(BUS_NAME)
        || h.interface().map(|i| i.as_str()) != Some(BUS_NAME)
        || h.member().map(|m| m.as_str()) != Some("NameOwnerChanged")
    {
        return None;
    }
    let (name, _old, new) = msg.body().deserialize::<(String, String, String)>().ok()?;
    (name.starts_with(':') && new.is_empty()).then_some(name)
}

/// Hands a call to its client's task, starting one for a new client.
async fn route(
    shared: &Arc<Shared>,
    clients: &mut HashMap<String, mpsc::Sender<Message>>,
    msg: Message,
) {
    let Some(sender) = msg.header().sender().map(|s| s.as_str().to_owned()) else {
        return;
    };
    let msg = match clients.get(&sender) {
        Some(tx) => match tx.try_send(msg) {
            Ok(()) => return,
            Err(TrySendError::Full(msg)) => {
                refuse(&shared.conn, &msg, limits("too many calls waiting")).await;
                return;
            }
            // The task is gone; start over for this client.
            Err(TrySendError::Closed(msg)) => {
                clients.remove(&sender);
                msg
            }
        },
        None => msg,
    };
    if clients.len() >= shared.opts.max_clients {
        refuse(&shared.conn, &msg, limits("too many clients")).await;
        return;
    }
    let (tx, rx) = mpsc::channel(shared.opts.queue_per_client.max(1));
    // Cannot fail: the queue is new and empty.
    let _ = tx.try_send(msg);
    clients.insert(sender.clone(), tx);
    tokio::spawn(client_task(Arc::clone(shared), sender, rx));
}

/// Serves one client connection, strictly in the order it sent its calls.
async fn client_task(shared: Arc<Shared>, sender: String, mut rx: mpsc::Receiver<Message>) {
    let allowed = peer_allowed(peer_uid(&shared.conn, &sender).await, shared.opts.uid);
    let mut client = Client {
        shared: &shared,
        sender: &sender,
        contexts: Contexts::new(shared.opts.max_contexts_per_client),
    };
    while let Some(msg) = rx.recv().await {
        if allowed {
            client.handle(&msg).await;
        } else {
            refuse(
                &shared.conn,
                &msg,
                fdo::Error::AccessDenied("caller is another user".into()),
            )
            .await;
        }
    }
    // The client left: its words have nowhere to go; they are wiped on drop.
    for id in client.contexts.drain() {
        drop(shared.ime.destroy_context(id));
    }
}

async fn peer_uid(conn: &Connection, sender: &str) -> Option<u32> {
    bus_call(conn, "GetConnectionUnixUser", &(sender,))
        .await
        .ok()?
        .body()
        .deserialize::<u32>()
        .ok()
}

fn limits(what: &str) -> fdo::Error {
    fdo::Error::LimitsExceeded(what.into())
}

fn invalid() -> fdo::Error {
    fdo::Error::InvalidArgs("unexpected arguments".into())
}

fn wants_reply(msg: &Message) -> bool {
    !msg.primary_header()
        .flags()
        .contains(Flags::NO_REPLY_EXPECTED)
}

/// Error reply; a failed send means the caller is gone, which the reader learns too.
async fn refuse(conn: &Connection, msg: &Message, err: fdo::Error) {
    if wants_reply(msg) {
        let _ = conn.reply_dbus_error(&msg.header(), err).await;
    }
}

struct Client<'a> {
    shared: &'a Shared,
    sender: &'a str,
    contexts: Contexts,
}

impl Client<'_> {
    async fn handle(&mut self, msg: &Message) {
        let h = msg.header();
        let path = h.path().map_or("", |p| p.as_str());
        let iface = h.interface().map(|i| i.as_str());
        let member = h.member().map_or("", |m| m.as_str());
        let result = if IM_PATHS.contains(&path) {
            if iface.is_some_and(|i| i != IM_IFACE) {
                Err(fdo::Error::UnknownInterface("unknown interface".into()))
            } else {
                self.input_method(msg, member).await
            }
        } else if path.starts_with(IC_PREFIX) {
            match self.contexts.get(path) {
                // Not created by this connection, or destroyed (SEC-9).
                None => Err(fdo::Error::AccessDenied(
                    "not an input context of the caller".into(),
                )),
                Some(_) if iface.is_some_and(|i| i != IC_IFACE) => {
                    Err(fdo::Error::UnknownInterface("unknown interface".into()))
                }
                Some(id) => self.input_context(msg, path, id, member).await,
            }
        } else {
            Err(fdo::Error::UnknownObject("unknown object".into()))
        };
        if let Err(err) = result {
            refuse(&self.shared.conn, msg, err).await;
        }
    }

    async fn input_method(&mut self, msg: &Message, member: &str) -> fdo::Result<()> {
        match member {
            "CreateInputContext" => {
                let args = msg
                    .body()
                    .deserialize::<Vec<(String, String)>>()
                    .map_err(|_| invalid())?;
                if !create_args_ok(&args) {
                    return Err(invalid());
                }
                if !self.contexts.has_room() {
                    return Err(limits("too many input contexts"));
                }
                let n = self.shared.next_ic.fetch_add(1, Ordering::Relaxed) + 1;
                let path = ic_path(n);
                let object = zbus::ObjectPath::try_from(path.as_str())
                    .map_err(|_| fdo::Error::Failed("bad path".into()))?;
                let id = self.shared.ime.create_context();
                if self.contexts.insert(path.clone(), id).is_err() {
                    drop(self.shared.ime.destroy_context(id));
                    return Err(limits("too many input contexts"));
                }
                self.reply(msg, &(object, uuid())).await;
                Ok(())
            }
            "Version" => {
                expect_signature(msg, "")?;
                self.reply(msg, &1u32).await;
                Ok(())
            }
            _ => Err(fdo::Error::UnknownMethod("unknown method".into())),
        }
    }

    async fn input_context(
        &mut self,
        msg: &Message,
        path: &str,
        id: ime_core::CtxId,
        member: &str,
    ) -> fdo::Result<()> {
        let ime = &self.shared.ime;
        match member {
            "ProcessKeyEvent" => {
                let (keyval, keycode, state, is_release, _time) = msg
                    .body()
                    .deserialize::<(u32, u32, u32, bool, u32)>()
                    .map_err(|_| invalid())?;
                let result = ime.process_key(id, key_event(keyval, keycode, state, is_release));
                self.emit(path, &result.actions).await;
                self.reply(msg, &result.handled).await;
            }
            "FocusIn" => {
                expect_signature(msg, "")?;
                ime.focus_in(id);
                self.reply(msg, &()).await;
            }
            "FocusOut" => {
                expect_signature(msg, "")?;
                let actions = ime.focus_out(id);
                self.emit(path, &actions).await;
                self.reply(msg, &()).await;
            }
            "Reset" => {
                expect_signature(msg, "")?;
                let actions = ime.reset(id);
                self.emit(path, &actions).await;
                self.reply(msg, &()).await;
            }
            "SetCapability" => {
                let bits = msg.body().deserialize::<u64>().map_err(|_| invalid())?;
                let actions = ime.set_caps(id, caps_from_fcitx(bits));
                self.emit(path, &actions).await;
                self.reply(msg, &()).await;
            }
            "DestroyIC" => {
                expect_signature(msg, "")?;
                self.contexts.remove(path);
                let actions = ime.destroy_context(id);
                self.emit(path, &actions).await;
                self.reply(msg, &()).await;
            }
            // Accepted and not used: the engine needs no cursor position and
            // does not read the text around the cursor, which is therefore
            // never even decoded (SEC-4).
            "SetCursorRect" => self.accept(msg, "iiii").await?,
            "SetCursorRectV2" => self.accept(msg, "iiiid").await?,
            "SetSupportedCapability" => self.accept(msg, "t").await?,
            "SetSurroundingText" => self.accept(msg, "suu").await?,
            "SetSurroundingTextPosition" => self.accept(msg, "uu").await?,
            _ => return Err(fdo::Error::UnknownMethod("unknown method".into())),
        }
        Ok(())
    }

    async fn accept(&self, msg: &Message, signature: &str) -> fdo::Result<()> {
        expect_signature(msg, signature)?;
        self.reply(msg, &()).await;
        Ok(())
    }

    async fn reply<B>(&self, msg: &Message, body: &B)
    where
        B: serde::Serialize + zbus::wire::DynamicType,
    {
        if wants_reply(msg) {
            let _ = self.shared.conn.reply(&msg.header(), body).await;
        }
    }

    /// Sends the actions, in order, to the owner of the context only (SEC-9).
    async fn emit(&self, path: &str, actions: &[Action]) {
        for action in actions {
            let _ = match action {
                Action::UpdatePreedit { text, cursor } => {
                    let pieces: Vec<(&str, i32)> = if text.is_empty() {
                        Vec::new()
                    } else {
                        vec![(text.as_str(), FORMAT_UNDERLINE)]
                    };
                    self.signal(
                        path,
                        "UpdateFormattedPreedit",
                        &(pieces, byte_cursor(text, *cursor)),
                    )
                    .await
                }
                Action::HidePreedit => {
                    let none: Vec<(&str, i32)> = Vec::new();
                    self.signal(path, "UpdateFormattedPreedit", &(none, 0i32))
                        .await
                }
                Action::Commit(text) => self.signal(path, "CommitString", &(text.as_str(),)).await,
                Action::DeleteSurrounding { offset, chars } => {
                    self.signal(path, "DeleteSurroundingText", &(*offset, *chars))
                        .await
                }
            };
        }
    }

    async fn signal<B>(&self, path: &str, name: &str, body: &B) -> zbus::Result<()>
    where
        B: serde::Serialize + zbus::wire::DynamicType,
    {
        self.shared
            .conn
            .emit_signal(Some(self.sender), path, IC_IFACE, name, body)
            .await
    }
}

fn expect_signature(msg: &Message, signature: &str) -> fdo::Result<()> {
    if msg.body().signature().to_string_no_parens() == signature {
        Ok(())
    } else {
        Err(invalid())
    }
}

/// The 16-byte id fcitx5 hands out with a context. Clients only echo it, so
/// it needs to be unique, not secret.
fn uuid() -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    for _ in 0..2 {
        let mut h = RandomState::new().build_hasher();
        h.write_u64(0);
        out.extend_from_slice(&h.finish().to_le_bytes());
    }
    out
}
