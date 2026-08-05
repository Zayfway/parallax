//! Handle de session + transport loopback vers l'agent injecté.
//! Réel sous `agent-link`, stub sinon.

use crate::*;
use std::os::raw::c_char;
use std::ptr;

/// Handle opaque de session. Créé par `pr_session_open`, détruit par
/// `pr_session_close` (qui consomme le pointeur). Opaque côté cbindgen.
///
/// cbindgen:opaque
pub struct PrSession {
    #[cfg(feature = "agent-link")]
    pub(crate) reader: std::io::BufReader<std::net::TcpStream>,
    #[cfg(feature = "agent-link")]
    pub(crate) scanned: bool,
}

/// Ouvre le canal loopback vers l'agent injecté. NULL en échec (lire
/// `pr_last_error`). À libérer par `pr_session_close`.
/// # Safety : `host` null ou C-string valide.
#[no_mangle]
pub unsafe extern "C" fn pr_session_open(host: *const c_char, port: u16) -> *mut PrSession {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = (host, port);
        set_last_error("pr_session_open : module natif non compilé (agent-link)");
        ptr::null_mut()
    }
    #[cfg(feature = "agent-link")]
    guard("pr_session_open", ptr::null_mut(), || {
        let host = match cstr(host) {
            Some(h) => h,
            None => {
                set_last_error("pr_session_open : hôte nul");
                return ptr::null_mut();
            }
        };
        match std::net::TcpStream::connect((host.as_str(), port)) {
            Ok(stream) => {
                stream.set_nodelay(true).ok();
                log_line("session prism ouverte");
                Box::into_raw(Box::new(PrSession {
                    reader: std::io::BufReader::new(stream),
                    scanned: false,
                }))
            }
            Err(e) => {
                set_last_error(format!("connexion agent échouée : {e}"));
                ptr::null_mut()
            }
        }
    })
}

/// Consomme le pointeur ; libéré exactement une fois.
/// # Safety : issu de `pr_session_open`, ou null.
#[no_mangle]
pub unsafe extern "C" fn pr_session_close(session: *mut PrSession) {
    if session.is_null() {
        return;
    }
    drop(Box::from_raw(session));
    tracing::info!("session prism fermée");
}

/// Un aller-retour ligne-JSON sur le canal persistant de la session.
#[cfg(feature = "agent-link")]
pub(crate) fn roundtrip(
    s: &mut PrSession,
    cmd: &prism_proto::Cmd,
) -> Result<prism_proto::Reply, String> {
    use std::io::{BufRead, Write};
    let mut line = serde_json::to_string(cmd).map_err(|e| format!("encodage cmd : {e}"))?;
    line.push('\n');
    s.reader
        .get_mut()
        .write_all(line.as_bytes())
        .map_err(|e| format!("écriture canal : {e}"))?;
    s.reader.get_mut().flush().ok();
    let mut resp = String::new();
    let n = s
        .reader
        .read_line(&mut resp)
        .map_err(|e| format!("lecture canal : {e}"))?;
    if n == 0 {
        return Err("canal fermé par l'agent".into());
    }
    serde_json::from_str(resp.trim_end()).map_err(|e| format!("réponse hors protocole : {e}"))
}
