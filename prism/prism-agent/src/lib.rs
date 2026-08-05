//! Agent Prism — dylib injecté dans l'app cible (palier 1 autonome).
//!
//! Au chargement du dylib (constructeurs exécutés avant `main` — injection via
//! `LC_LOAD_DYLIB`), un thread lève le serveur loopback `127.0.0.1:PR_AGENT_PORT`.
//! Il ne bloque **jamais** le démarrage de la cible. L'agent scanne
//! `mach_task_self()` — sa propre tâche, aucun entitlement privilégié.

mod vm;

use prism_proto::{Cmd, Reply, PR_AGENT_PORT};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};

#[ctor::ctor]
fn prism_agent_boot() {
    // Ne jamais bloquer le chargement : tout part sur un thread détaché.
    std::thread::spawn(|| {
        let _ = serve();
    });
}

fn serve() -> std::io::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", PR_AGENT_PORT))?;
    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                // Une connexion = une session = un ScanState indépendant.
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
            break; // canal fermé par l'hôte
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
        Cmd::Regions => Reply::Regions {
            regions: vm::regions(),
        },
        Cmd::ScanI32 { value } => {
            vm::scan_i32(st, value);
            Reply::Scan {
                count: st.cands.len(),
                sample: sample(st),
            }
        }
        Cmd::Refine { op, value } => {
            vm::refine(st, op, value);
            Reply::Scan {
                count: st.cands.len(),
                sample: sample(st),
            }
        }
        Cmd::ReadI32 { addr } => match vm::read_i32(addr) {
            Some(value) => Reply::Value { addr, value },
            None => Reply::Err {
                message: "lecture refusée".into(),
            },
        },
        Cmd::WriteI32 { addr, value } => {
            if vm::write_i32(addr, value) {
                Reply::Ok
            } else {
                Reply::Err {
                    message: "écriture refusée".into(),
                }
            }
        }
    }
}

fn sample(st: &vm::ScanState) -> Vec<u64> {
    st.cands.iter().take(64).copied().collect()
}
