//! vr-talex daemon: wires every frontend to one shared IME.
#![forbid(unsafe_code)]

use std::process::ExitCode;

use ime_core::SharedIme;
use tokio::task::JoinSet;

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().build() {
        Ok(rt) => rt,
        Err(_) => {
            eprintln!("vr-talex: cannot start the async runtime");
            return ExitCode::FAILURE;
        }
    };
    runtime.block_on(serve(SharedIme::new()))
}

async fn serve(ime: SharedIme) -> ExitCode {
    let mut frontends = JoinSet::new();
    frontends.spawn(async_named("ibus", fe_ibus::run(ime.clone())));
    frontends.spawn(async_named("fcitx", fe_fcitx::run(ime.clone())));
    frontends.spawn(async_named("xim", fe_xim::run(ime)));

    let mut status = ExitCode::SUCCESS;
    while let Some(joined) = frontends.join_next().await {
        match joined {
            Ok((_, Ok(()))) => {}
            Ok((name, Err(err))) => {
                // Frontend errors carry no typed text by contract (SEC-1).
                eprintln!("vr-talex: frontend {name} failed: {err}");
                status = ExitCode::FAILURE;
            }
            Err(_) => {
                eprintln!("vr-talex: a frontend task panicked");
                status = ExitCode::FAILURE;
            }
        }
    }
    status
}

async fn async_named<F>(name: &'static str, fut: F) -> (&'static str, ime_core::Result<()>)
where
    F: Future<Output = ime_core::Result<()>>,
{
    (name, fut.await)
}
