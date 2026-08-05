//! Agent Prism — dylib injecté dans l'app cible.
//!
//! Deux faces sur le même moteur mach (vm.rs) :
//!   1. **Overlay in-app** (façon GameGuardian) rendu par `overlay/PrismOverlay.m`,
//!      installé au chargement. Il pilote le moteur via des exports C (engine.rs).
//!   2. **Serveur loopback** `127.0.0.1:PR_AGENT_PORT` pour l'app compagnon Prism
//!      (protocole ligne-JSON, prism-proto).
//!
//! Constructeurs exécutés avant `main` — on ne bloque jamais le démarrage.

mod engine;
mod vm;

use prism_proto::{Cmd, Reply, PR_AGENT_PORT};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};

extern "C" {
    // Défini dans PrismOverlay.m — installe l'overlay quand une scène est prête.
    fn prism_overlay_bootstrap();
}

#[ctor::ctor]
fn prism_agent_boot() {
    // Overlay in-app (l'ObjC diffère l'installation sur le thread principal).
    unsafe { prism_overlay_bootstrap() };
    // Boucle de gel pour l'overlay.
    engine::start_freeze_thread();
    // Serveur loopback pour l'app compagnon (conservé, thread détaché).
    std::thread::spawn(|| {
        let _ = serve();
    });
}

fn serve() -> std::io::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", PR_AGENT_PORT))?;
    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                std::thread::spawn(move || {
                    let _ = handle(stream);
                });
            }
            Err(_) => continue,
        }
    }
    Ok(())
}

fn handle(stream: TcpStream) -> std::io::Result<()> {
    stream.set_nodelay(true).ok();
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut st = vm::ScanState::default();
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let reply = match serde_json::from_str::<Cmd>(line.trim_end()) {
            Ok(cmd) => dispatch(&mut st, cmd),
            Err(e) => Reply::Err {
                message: format!("cmd invalide : {e}"),
            },
        };
        let mut out = serde_json::to_string(&reply)
            .unwrap_or_else(|_| String::from(r#"{"reply":"err","message":"encode"}"#));
        out.push('\n');
        writer.write_all(out.as_bytes())?;
        writer.flush().ok();
    }
    Ok(())
}

fn dispatch(st: &mut vm::ScanState, cmd: Cmd) -> Reply {
    match cmd {
        Cmd::Regions => Reply::Regions { regions: vm::regions() },
        Cmd::ScanI32 { value } => {
            vm::scan_i32(st, value);
            Reply::Scan { count: st.cands.len(), sample: sample(st) }
        }
        Cmd::Refine { op, value } => {
            vm::refine(st, op, value);
            Reply::Scan { count: st.cands.len(), sample: sample(st) }
        }
        Cmd::ReadI32 { addr } => match vm::read_i32(addr) {
            Some(value) => Reply::Value { addr, value },
            None => Reply::Err { message: "lecture refusée".into() },
        },
        Cmd::WriteI32 { addr, value } => {
            if vm::write_i32(addr, value) {
                Reply::Ok
            } else {
                Reply::Err { message: "écriture refusée".into() }
            }
        }
    }
}

fn sample(st: &vm::ScanState) -> Vec<u64> {
    st.cands.iter().take(64).copied().collect()
}
