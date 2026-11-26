//! vr-telex daemon: wires every frontend to one shared IME.
#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::future::poll_fn;
use std::io;
use std::os::linux::net::SocketAddrExt;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::{SocketAddr, UnixDatagram};
use std::panic::Location;
use std::path::Path;
use std::pin::Pin;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::task::Poll;
use std::time::Duration;

use ime_core::{
    FileStateStore, Ime, MemoryStateStore, Mode, ModeWatch, Ready, ReadyWatch, SharedIme,
    StateStore,
};
use rustix::process::{DumpableBehavior, Resource, Rlimit};
use tokio::signal::unix::{SignalKind, signal};
use tokio::task::JoinSet;

/// The mode file, shared with the task that writes it.
type Store = Arc<dyn StateStore + Send + Sync>;

/// One frontend: its `run` future and the daemon's end of its readiness handle.
///
/// What `run` tells the daemon (the same text is on each frontend's `run`):
/// `Ready::notify` — clients can reach it; `Ok(())` — not needed on this
/// machine, which also counts as ready; `Err` — it failed, and the whole
/// daemon ends so that systemd restarts it (decision D22).
struct Frontend {
    name: &'static str,
    run: Pin<Box<dyn Future<Output = ime_core::Result<()>> + Send>>,
    ready: ReadyWatch,
}

impl Frontend {
    fn new<F>(name: &'static str, run: impl FnOnce(Ready) -> F) -> Self
    where
        F: Future<Output = ime_core::Result<()>> + Send + 'static,
    {
        let (ready, watch) = Ready::channel();
        Self {
            name,
            run: Box::pin(run(ready)),
            ready: watch,
        }
    }
}

/// What the tasks of [`serve`] report.
enum Event {
    Finished(&'static str, ime_core::Result<()>),
    /// The frontend reported ready (`true`) or dropped its handle unused.
    Ready(&'static str, bool),
    /// SIGTERM or SIGINT arrived, or the signals cannot be watched.
    Shutdown(ime_core::Result<()>),
}

fn main() -> ExitCode {
    // Before any socket exists, so no key can be in memory yet (SEC-3).
    if harden().is_err() {
        eprintln!("vr-telex: cannot switch off core dumps, not starting");
        return ExitCode::FAILURE;
    }
    install_panic_hook();
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => {
            eprintln!("vr-telex: cannot start the async runtime");
            return ExitCode::FAILURE;
        }
    };
    let store = state_store();
    let ime = SharedIme::new(Ime::new(store.as_ref()));
    let frontends = vec![
        Frontend::new("ibus", |ready| fe_ibus::run(ime.clone(), ready)),
        Frontend::new("fcitx", |ready| fe_fcitx::run(ime.clone(), ready)),
        Frontend::new("xim", |ready| fe_xim::run(ime.clone(), ready)),
    ];
    runtime.block_on(serve(frontends, ime, store, Notifier::from_env()))
}

/// No core dump and no ptrace attach by a non-root process: a dump of this
/// process would hold what the user typed last (SEC-3).
fn harden() -> rustix::io::Result<()> {
    rustix::process::set_dumpable_behavior(DumpableBehavior::NotDumpable)?;
    rustix::process::setrlimit(
        Resource::Core,
        Rlimit {
            current: Some(0),
            maximum: Some(0),
        },
    )
}

/// The default hook prints the panic message, and a message of the standard
/// library can quote the data it failed on, which here may be typed text.
/// Only the place in the source goes to the journal (SEC-1).
fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        eprintln!("{}", panic_line(info.location()));
    }));
}

/// Takes the location alone, so the payload cannot end up in the line.
fn panic_line(location: Option<&Location<'_>>) -> String {
    match location {
        Some(at) => format!(
            "vr-telex: internal error at {}:{}:{}",
            at.file(),
            at.line(),
            at.column()
        ),
        None => "vr-telex: internal error".to_owned(),
    }
}

/// The VI/EN file under the XDG state directory: the only thing persisted (SEC-5).
fn state_store() -> Store {
    match FileStateStore::from_env() {
        Some(store) => Arc::new(store),
        None => {
            eprintln!("vr-telex: no home directory, the VI/EN mode is not saved");
            Arc::new(MemoryStateStore::new(Mode::Vi))
        }
    }
}

/// Writes the mode file away from the keys: never under the IME lock and
/// never on the thread that serves the clients.
struct ModeSaver {
    ime: SharedIme,
    store: Store,
    /// One write at a time, so a slow earlier write cannot land after a later one.
    writing: Mutex<()>,
}

impl ModeSaver {
    /// Stores the mode as it is now (not as it was when the save was asked
    /// for): whichever write runs last leaves the latest mode in the file.
    fn save_now(&self) {
        let _one = self
            .writing
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mode = self.ime.mode();
        if self.store.load() != mode {
            self.store.save(mode);
        }
    }
}

/// Saves the mode after every toggle, on the blocking pool.
async fn persist_mode(mut watch: ModeWatch, saver: Arc<ModeSaver>) {
    while watch.changed().await.is_some() {
        let saver = Arc::clone(&saver);
        // A failed or panicked write only costs the mode at the next start.
        let _ = tokio::task::spawn_blocking(move || saver.save_now()).await;
    }
}

async fn serve(
    frontends: Vec<Frontend>,
    ime: SharedIme,
    store: Store,
    notifier: Option<Notifier>,
) -> ExitCode {
    let mut running = frontends.len();
    let mut unready: Vec<&'static str> = frontends.iter().map(|frontend| frontend.name).collect();
    let mut tasks = JoinSet::new();
    for Frontend { name, run, ready } in frontends {
        tasks.spawn(async move { Event::Finished(name, run.await) });
        tasks.spawn(async move { Event::Ready(name, ready.wait().await) });
    }
    tasks.spawn(async { Event::Shutdown(shutdown_signal().await) });

    let saver = Arc::new(ModeSaver {
        ime: ime.clone(),
        store,
        writing: Mutex::new(()),
    });
    // Neither is in `tasks`: they never end and die with the runtime.
    tokio::spawn(persist_mode(ime.subscribe_mode(), Arc::clone(&saver)));
    if let Some(notifier) = &notifier {
        let pid = std::env::var_os("WATCHDOG_PID");
        let usec = std::env::var_os("WATCHDOG_USEC");
        if let Some(period) = watchdog_period(usec.as_deref(), pid.as_deref(), std::process::id()) {
            tokio::spawn(watchdog(notifier.clone(), period, ime));
        }
    }

    // Runs until SIGTERM, a failed frontend, or no frontend left to serve anyone.
    let mut status = ExitCode::SUCCESS;
    let mut announced = false;
    while running > 0 {
        match tasks.join_next().await {
            None | Some(Ok(Event::Shutdown(Ok(())))) => break,
            Some(Ok(Event::Shutdown(Err(_)))) => {
                // The default action of SIGTERM still ends the process.
                eprintln!("vr-telex: cannot watch for SIGTERM");
            }
            Some(Ok(Event::Ready(name, true))) => unready.retain(|waiting| *waiting != name),
            // The handle was dropped unused: the `run` result says why.
            Some(Ok(Event::Ready(_, false))) => {}
            // Not needed on this machine: nothing to wait for.
            Some(Ok(Event::Finished(name, Ok(())))) => {
                unready.retain(|waiting| *waiting != name);
                running -= 1;
            }
            // A dead frontend leaves its clients typing raw keys for the rest
            // of the session unless the daemon ends and systemd restarts it
            // whole (SEC-17, D22).
            Some(Ok(Event::Finished(name, Err(err)))) => {
                // Frontend errors carry no typed text by contract (SEC-1).
                eprintln!("vr-telex: frontend {name} failed: {err}");
                status = ExitCode::FAILURE;
                break;
            }
            Some(Err(_)) => {
                eprintln!("vr-telex: a frontend task panicked");
                status = ExitCode::FAILURE;
                break;
            }
        }
        // systemd (and the installer's health check) may count on every
        // frontend being reachable once the daemon says it has started.
        if !announced && unready.is_empty() {
            announced = true;
            if let Some(notifier) = &notifier {
                notifier.send("READY=1");
            }
        }
    }
    if let Some(notifier) = &notifier {
        notifier.send("STOPPING=1");
    }
    // Cancels the frontends and waits until each has dropped what it owns
    // (sockets, the address file), so nothing stale is left behind.
    tasks.shutdown().await;
    // A toggle right before the stop may not have been written yet.
    saver.save_now();
    status
}

/// Resolves on SIGTERM (systemd stop) or SIGINT (Ctrl+C in a terminal).
async fn shutdown_signal() -> ime_core::Result<()> {
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    poll_fn(|cx| {
        if terminate.poll_recv(cx).is_ready() || interrupt.poll_recv(cx).is_ready() {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    })
    .await;
    Ok(())
}

/// Tells systemd the daemon is alive, from the thread that handles the keys
/// and through the lock they take: when either is stuck the pings stop and
/// systemd restarts the daemon (SEC-18).
async fn watchdog(notifier: Notifier, period: Duration, ime: SharedIme) {
    let mut tick = tokio::time::interval(period);
    loop {
        tick.tick().await;
        let _ = ime.mode();
        notifier.send("WATCHDOG=1");
    }
}

/// Half of `WATCHDOG_USEC`, when systemd asks this process for pings.
fn watchdog_period(usec: Option<&OsStr>, pid: Option<&OsStr>, own_pid: u32) -> Option<Duration> {
    let number = |value: &OsStr| value.to_str()?.parse::<u64>().ok();
    // WATCHDOG_PID names the process the request is for; it may be a parent.
    if pid.is_some_and(|pid| number(pid) != Some(u64::from(own_pid))) {
        return None;
    }
    let usec = usec.and_then(number).filter(|&usec| usec > 0)?;
    Some(Duration::from_micros(usec / 2).max(Duration::from_millis(1)))
}

/// The systemd notification socket (`sd_notify`), written to with fixed
/// strings only.
#[derive(Clone)]
struct Notifier {
    addr: SocketAddr,
}

impl Notifier {
    fn from_env() -> Option<Self> {
        Self::parse(&std::env::var_os("NOTIFY_SOCKET")?)
    }

    /// An absolute path, or `@name` for an abstract socket; anything else is ignored.
    fn parse(socket: &OsStr) -> Option<Self> {
        let addr = match socket.as_bytes() {
            [b'@', name @ ..] if !name.is_empty() => SocketAddr::from_abstract_name(name).ok()?,
            [b'/', ..] => SocketAddr::from_pathname(Path::new(socket)).ok()?,
            _ => return None,
        };
        Some(Self { addr })
    }

    fn try_send(&self, state: &'static str) -> io::Result<()> {
        UnixDatagram::unbound()?
            .send_to_addr(state.as_bytes(), &self.addr)
            .map(|_| ())
    }

    /// A lost notification is not worth stopping for: systemd's own timeouts cover it.
    fn send(&self, state: &'static str) {
        let _ = self.try_send(state);
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::MutexGuard;
    use std::sync::atomic::{AtomicU32, Ordering};

    use ime_core::{CtxId, KeyEvent, Mods, keysym};
    use rustix::process::{Signal, getpid, kill_process};

    use super::*;

    /// SIGTERM reaches every `serve` of the process: tests that run `serve`
    /// take this lock so the signal of one cannot end another.
    static SERVE: Mutex<()> = Mutex::new(());

    fn serve_alone() -> MutexGuard<'static, ()> {
        SERVE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()
            .unwrap()
    }

    fn memory_store() -> Store {
        Arc::new(MemoryStateStore::new(Mode::Vi))
    }

    fn ime() -> SharedIme {
        SharedIme::new(Ime::new(memory_store().as_ref()))
    }

    fn unique(kind: &str) -> PathBuf {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        std::env::temp_dir().join(format!(
            "vr-telex-test-{}-{}.{kind}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    /// Lets the tasks of the current-thread runtime run up to their next wait.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    /// A datagram socket standing in for systemd, removed on drop.
    struct Listener {
        socket: UnixDatagram,
        path: PathBuf,
    }

    impl Listener {
        fn new() -> Self {
            let path = unique("sock");
            let _ = std::fs::remove_file(&path);
            let socket = UnixDatagram::bind(&path).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            Self { socket, path }
        }

        fn notifier(&self) -> Notifier {
            Notifier::parse(self.path.as_os_str()).unwrap()
        }

        fn next(&self) -> String {
            let mut buf = [0u8; 64];
            let len = self.socket.recv(&mut buf).unwrap();
            String::from_utf8(buf[..len].to_vec()).unwrap()
        }

        /// What arrived so far, without waiting.
        fn arrived(&self) -> Vec<String> {
            self.socket.set_nonblocking(true).unwrap();
            let mut all = Vec::new();
            let mut buf = [0u8; 64];
            while let Ok(len) = self.socket.recv(&mut buf) {
                all.push(String::from_utf8(buf[..len].to_vec()).unwrap());
            }
            self.socket.set_nonblocking(false).unwrap();
            all
        }
    }

    impl Drop for Listener {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    /// A frontend that serves forever and is ready at once.
    fn serving(name: &'static str) -> Frontend {
        Frontend::new(name, |ready| async move {
            ready.notify();
            std::future::pending().await
        })
    }

    /// A frontend that serves forever; the test decides when it is ready.
    fn starting(name: &'static str) -> (Frontend, Ready) {
        let (ready, watch) = Ready::channel();
        let frontend = Frontend {
            name,
            run: Box::pin(std::future::pending()),
            ready: watch,
        };
        (frontend, ready)
    }

    fn tap_ctrl_shift(ime: &SharedIme, id: CtxId) {
        let both = Mods::CONTROL | Mods::SHIFT;
        for ev in [
            KeyEvent::press(keysym::CONTROL_L, Mods::NONE),
            KeyEvent::press(keysym::SHIFT_L, Mods::CONTROL),
            KeyEvent::release(keysym::SHIFT_L, both),
            KeyEvent::release(keysym::CONTROL_L, Mods::CONTROL),
        ] {
            ime.process_key(id, ev);
        }
    }

    #[test]
    fn hardening_switches_off_core_dumps() {
        harden().unwrap();
        assert_eq!(
            rustix::process::dumpable_behavior().unwrap(),
            DumpableBehavior::NotDumpable
        );
        let core = rustix::process::getrlimit(Resource::Core);
        assert_eq!((core.current, core.maximum), (Some(0), Some(0)));
        // The limit cannot be raised again by this process or its children.
        assert!(
            rustix::process::setrlimit(
                Resource::Core,
                Rlimit {
                    current: Some(1),
                    maximum: Some(1)
                }
            )
            .is_err()
        );
    }

    #[test]
    fn the_panic_line_names_only_the_place() {
        let here = Location::caller();
        let line = panic_line(Some(here));
        assert_eq!(
            line,
            format!(
                "vr-telex: internal error at {}:{}:{}",
                file!(),
                here.line(),
                here.column()
            )
        );
        assert_eq!(panic_line(None), "vr-telex: internal error");
    }

    #[test]
    fn watchdog_period_is_half_the_interval_systemd_asks_for() {
        let os = OsStr::new;
        let half = Some(Duration::from_secs(5));
        assert_eq!(watchdog_period(Some(os("10000000")), None, 42), half);
        assert_eq!(
            watchdog_period(Some(os("10000000")), Some(os("42")), 42),
            half
        );
        assert_eq!(
            watchdog_period(Some(os("10000000")), Some(os("7")), 42),
            None
        );
        assert_eq!(
            watchdog_period(Some(os("10000000")), Some(os("x")), 42),
            None
        );
        assert_eq!(watchdog_period(None, None, 42), None);
        assert_eq!(watchdog_period(Some(os("0")), None, 42), None);
        assert_eq!(watchdog_period(Some(os("soon")), None, 42), None);
        assert_eq!(
            watchdog_period(Some(os("1")), None, 42),
            Some(Duration::from_millis(1))
        );
    }

    #[test]
    fn notify_socket_must_be_absolute_or_abstract() {
        assert!(Notifier::parse(OsStr::new("/run/user/1000/systemd/notify")).is_some());
        assert!(Notifier::parse(OsStr::new("@vr-telex-test")).is_some());
        assert!(Notifier::parse(OsStr::new("relative/notify")).is_none());
        assert!(Notifier::parse(OsStr::new("@")).is_none());
        assert!(Notifier::parse(OsStr::new("")).is_none());
        // No listener: sending fails quietly.
        let nobody = Notifier::parse(OsStr::new("/nonexistent/vr-telex/notify")).unwrap();
        assert!(nobody.try_send("READY=1").is_err());
        nobody.send("READY=1");
    }

    #[test]
    fn notifications_reach_a_path_and_an_abstract_socket() {
        let listener = Listener::new();
        listener.notifier().send("READY=1");
        assert_eq!(listener.next(), "READY=1");

        let name = format!("vr-telex-test-{}", std::process::id());
        let addr = SocketAddr::from_abstract_name(name.as_bytes()).unwrap();
        let socket = UnixDatagram::bind_addr(&addr).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let notifier = Notifier::parse(OsStr::new(&format!("@{name}"))).unwrap();
        notifier.send("WATCHDOG=1");
        let mut buf = [0u8; 64];
        let len = socket.recv(&mut buf).unwrap();
        assert_eq!(&buf[..len], b"WATCHDOG=1");
    }

    #[test]
    fn the_watchdog_pings_while_the_key_thread_is_free() {
        let listener = Listener::new();
        let notifier = listener.notifier();
        runtime().block_on(async {
            let pings = watchdog(notifier, Duration::from_millis(5), ime());
            let _ = tokio::time::timeout(Duration::from_millis(200), pings).await;
        });
        for _ in 0..3 {
            assert_eq!(listener.next(), "WATCHDOG=1");
        }
    }

    #[test]
    fn sigterm_stops_the_daemon_cleanly() {
        let _alone = serve_alone();
        let listener = Listener::new();
        let notifier = listener.notifier();
        let status = runtime().block_on(async {
            let frontends = vec![serving("never")];
            let serving = tokio::spawn(serve(frontends, ime(), memory_store(), Some(notifier)));
            // Signal only after the handler is in place, or the test dies:
            // let `serve` run up to its first wait.
            settle().await;
            assert_eq!(listener.next(), "READY=1");
            kill_process(getpid(), Signal::TERM).unwrap();
            tokio::time::timeout(Duration::from_secs(10), serving)
                .await
                .expect("the daemon stopped in time")
                .unwrap()
        });
        assert_eq!(status, ExitCode::SUCCESS);
        assert_eq!(listener.next(), "STOPPING=1");
    }

    #[test]
    fn the_daemon_ends_when_no_frontend_is_left() {
        let _alone = serve_alone();
        let listener = Listener::new();
        let done = |name| Frontend::new(name, |_ready| async { Ok(()) });
        let status = runtime().block_on(serve(
            vec![done("a"), done("b")],
            ime(),
            memory_store(),
            Some(listener.notifier()),
        ));
        assert_eq!(status, ExitCode::SUCCESS);
        // Frontends that are not needed do not hold back the start report.
        assert_eq!(listener.arrived(), ["READY=1", "STOPPING=1"]);
    }

    /// Runs `serve` with one broken frontend beside one that would serve forever.
    fn serve_with_broken_frontend(broken: Frontend) -> (ExitCode, Listener) {
        let _alone = serve_alone();
        let listener = Listener::new();
        let notifier = listener.notifier();
        let status = runtime().block_on(async {
            let frontends = vec![broken, serving("never")];
            tokio::time::timeout(
                Duration::from_secs(2),
                serve(frontends, ime(), memory_store(), Some(notifier)),
            )
            .await
            .expect("the daemon must stop when a frontend fails")
        });
        (status, listener)
    }

    #[test]
    fn a_failed_frontend_ends_the_daemon_so_systemd_restarts_it() {
        let failed = Frontend::new("broken", |ready| async {
            ready.notify();
            Err("frontend error".into())
        });
        let (status, listener) = serve_with_broken_frontend(failed);
        assert_eq!(status, ExitCode::FAILURE);
        assert_eq!(listener.arrived().last().unwrap(), "STOPPING=1");
    }

    #[test]
    fn a_panicked_frontend_ends_the_daemon_too() {
        async fn panics() -> ime_core::Result<()> {
            panic!("injected frontend panic")
        }
        let panicked = Frontend::new("broken", |_ready| panics());
        let (status, _listener) = serve_with_broken_frontend(panicked);
        assert_eq!(status, ExitCode::FAILURE);
    }

    #[test]
    fn ready_is_reported_only_when_every_frontend_is_ready() {
        let _alone = serve_alone();
        let listener = Listener::new();
        let notifier = listener.notifier();
        runtime().block_on(async {
            let (ibus, ibus_ready) = starting("ibus");
            let (fcitx, fcitx_ready) = starting("fcitx");
            let not_needed = Frontend::new("xim", |_ready| async { Ok(()) });
            let frontends = vec![ibus, fcitx, not_needed];
            let daemon = tokio::spawn(serve(frontends, ime(), memory_store(), Some(notifier)));

            settle().await;
            assert!(listener.arrived().is_empty(), "nobody is ready yet");
            ibus_ready.notify();
            settle().await;
            assert!(listener.arrived().is_empty(), "fcitx is still starting");
            fcitx_ready.notify();
            settle().await;
            assert_eq!(listener.arrived(), ["READY=1"]);

            daemon.abort();
            let _ = daemon.await;
        });
    }

    #[test]
    fn a_frontend_that_never_gets_ready_keeps_the_start_report_back() {
        let _alone = serve_alone();
        let listener = Listener::new();
        let notifier = listener.notifier();
        runtime().block_on(async {
            let (stuck, stuck_ready) = starting("ibus");
            let frontends = vec![stuck, serving("fcitx")];
            let daemon = tokio::spawn(serve(frontends, ime(), memory_store(), Some(notifier)));
            settle().await;
            // Dropping the handle unused is not "ready" either.
            drop(stuck_ready);
            settle().await;
            assert!(listener.arrived().is_empty());
            daemon.abort();
            let _ = daemon.await;
        });
    }

    /// A state directory under the temp dir, removed on drop.
    struct StateDir(PathBuf);

    impl Drop for StateDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_toggle_is_saved_off_the_key_path_and_survives_a_restart() {
        let _alone = serve_alone();
        let dir = StateDir(unique("state"));
        let store: Store = Arc::new(FileStateStore::new(dir.0.clone()));
        let ime = SharedIme::new(Ime::new(store.as_ref()));
        let id = ime.create_context();

        runtime().block_on(async {
            let frontends = vec![serving("never")];
            let daemon = tokio::spawn(serve(frontends, ime.clone(), Arc::clone(&store), None));
            settle().await;

            tap_ctrl_shift(&ime, id);
            assert_eq!(ime.mode(), Mode::En);
            assert_eq!(store.load(), Mode::Vi, "the key itself wrote nothing");

            // The saver task picks the change up and writes on the blocking pool.
            let saved = async {
                while store.load() != Mode::En {
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
            };
            tokio::time::timeout(Duration::from_secs(5), saved)
                .await
                .expect("the mode file was written");

            daemon.abort();
            let _ = daemon.await;
        });

        let restarted = Ime::new(&FileStateStore::new(dir.0.clone()));
        assert_eq!(restarted.mode(), Mode::En, "AC-8: EN after the restart");
    }

    #[test]
    fn a_toggle_right_before_the_stop_is_still_saved() {
        let _alone = serve_alone();
        let dir = StateDir(unique("state"));
        let store: Store = Arc::new(FileStateStore::new(dir.0.clone()));
        let ime = SharedIme::new(Ime::new(store.as_ref()));
        let id = ime.create_context();

        // The frontend toggles and returns at once: the saver task gets no turn.
        let toggling = ime.clone();
        let frontend = Frontend::new("once", move |_ready| async move {
            tap_ctrl_shift(&toggling, id);
            Ok(())
        });
        let status = runtime().block_on(serve(vec![frontend], ime, Arc::clone(&store), None));
        assert_eq!(status, ExitCode::SUCCESS);
        assert_eq!(store.load(), Mode::En);
    }
}
