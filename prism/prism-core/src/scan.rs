//! Les cinq entrées mémoire de l'hôte. Chaque entrée : `clear_last_error` ->
//! `guard` -> (sous `agent-link`) `roundtrip`, sinon stub `PR_ERR_NOT_BUILT` /
//! `NULL`. Les chaînes rendues sont possédées par l'appelant (`pr_string_free`).

use crate::link::PrSession;
use crate::*;
#[allow(unused_imports)]
use std::ffi::CString;
use std::os::raw::{c_char, c_int};
use std::ptr;

#[cfg(feature = "agent-link")]
fn to_cstring(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => {
            set_last_error("chaîne JSON non représentable");
            ptr::null_mut()
        }
    }
}

/// JSON `[{addr,size,prot,tag}]`. NULL en échec — lire `pr_last_error`.
/// Libérer par `pr_string_free`. # Safety : `session` issu de `pr_session_open`, ou null.
#[no_mangle]
pub unsafe extern "C" fn pr_regions_list(session: *mut PrSession) -> *mut c_char {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = session;
        set_last_error("pr_regions_list : module natif non compilé (agent-link)");
        ptr::null_mut()
    }
    #[cfg(feature = "agent-link")]
    guard("pr_regions_list", ptr::null_mut(), || {
        let Some(s) = session.as_mut() else {
            set_last_error("pr_regions_list : session nulle");
            return ptr::null_mut();
        };
        match crate::link::roundtrip(s, &prism_proto::Cmd::Regions) {
            Ok(prism_proto::Reply::Regions { regions }) => match serde_json::to_string(&regions) {
                Ok(json) => to_cstring(json),
                Err(e) => {
                    set_last_error(format!("sérialisation régions : {e}"));
                    ptr::null_mut()
                }
            },
            Ok(prism_proto::Reply::Err { message }) => {
                set_last_error(message);
                ptr::null_mut()
            }
            Ok(_) => {
                set_last_error("pr_regions_list : réponse inattendue");
                ptr::null_mut()
            }
            Err(e) => {
                set_last_error(e);
                ptr::null_mut()
            }
        }
    })
}

/// Première recherche int32. JSON `{count,sample}`. NULL en échec.
/// Libérer par `pr_string_free`. # Safety : cf. `pr_regions_list`.
#[no_mangle]
pub unsafe extern "C" fn pr_scan_i32(session: *mut PrSession, value: i32) -> *mut c_char {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = (session, value);
        set_last_error("pr_scan_i32 : module natif non compilé (agent-link)");
        ptr::null_mut()
    }
    #[cfg(feature = "agent-link")]
    guard("pr_scan_i32", ptr::null_mut(), || {
        let Some(s) = session.as_mut() else {
            set_last_error("pr_scan_i32 : session nulle");
            return ptr::null_mut();
        };
        match crate::link::roundtrip(s, &prism_proto::Cmd::ScanI32 { value }) {
            Ok(prism_proto::Reply::Scan { count, sample }) => {
                s.scanned = true;
                to_cstring(serde_json::json!({ "count": count, "sample": sample }).to_string())
            }
            Ok(prism_proto::Reply::Err { message }) => {
                set_last_error(message);
                ptr::null_mut()
            }
            Ok(_) => {
                set_last_error("pr_scan_i32 : réponse inattendue");
                ptr::null_mut()
            }
            Err(e) => {
                set_last_error(e);
                ptr::null_mut()
            }
        }
    })
}

/// Une passe d'affinage. `op` = `PR_REFINE_*`. JSON `{count,sample}`. NULL en
/// échec. Libérer par `pr_string_free`. # Safety : cf. `pr_regions_list`.
#[no_mangle]
pub unsafe extern "C" fn pr_scan_refine(
    session: *mut PrSession,
    op: c_int,
    value: i32,
) -> *mut c_char {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = (session, op, value);
        set_last_error("pr_scan_refine : module natif non compilé (agent-link)");
        ptr::null_mut()
    }
    #[cfg(feature = "agent-link")]
    guard("pr_scan_refine", ptr::null_mut(), || {
        let Some(s) = session.as_mut() else {
            set_last_error("pr_scan_refine : session nulle");
            return ptr::null_mut();
        };
        if !s.scanned {
            set_last_error("pr_scan_refine : aucune recherche initiale");
            return ptr::null_mut();
        }
        match crate::link::roundtrip(s, &prism_proto::Cmd::Refine { op: op as u8, value }) {
            Ok(prism_proto::Reply::Scan { count, sample }) => {
                to_cstring(serde_json::json!({ "count": count, "sample": sample }).to_string())
            }
            Ok(prism_proto::Reply::Err { message }) => {
                set_last_error(message);
                ptr::null_mut()
            }
            Ok(_) => {
                set_last_error("pr_scan_refine : réponse inattendue");
                ptr::null_mut()
            }
            Err(e) => {
                set_last_error(e);
                ptr::null_mut()
            }
        }
    })
}

/// Lit un i32 à `addr`. # Safety : `out` non nul, `session` valide ou null.
#[no_mangle]
pub unsafe extern "C" fn pr_mem_read_i32(
    session: *mut PrSession,
    addr: u64,
    out: *mut i32,
) -> c_int {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = (session, addr, out);
        PR_ERR_NOT_BUILT
    }
    #[cfg(feature = "agent-link")]
    guard("pr_mem_read_i32", PR_ERR_INTERNAL, || {
        if out.is_null() {
            set_last_error("pr_mem_read_i32 : out nul");
            return PR_ERR_ARG;
        }
        let Some(s) = session.as_mut() else {
            set_last_error("pr_mem_read_i32 : session nulle");
            return PR_ERR_NO_AGENT;
        };
        match crate::link::roundtrip(s, &prism_proto::Cmd::ReadI32 { addr }) {
            Ok(prism_proto::Reply::Value { value, .. }) => {
                *out = value;
                PR_OK
            }
            Ok(prism_proto::Reply::Err { message }) => {
                set_last_error(message);
                PR_ERR_READ
            }
            Ok(_) => {
                set_last_error("pr_mem_read_i32 : réponse inattendue");
                PR_ERR_AGENT_PROTO
            }
            Err(e) => {
                set_last_error(e);
                PR_ERR_SESSION_DEAD
            }
        }
    })
}

/// L'UNIQUE écriture du jalon. `PR_OK` | `PR_ERR_WRITE`. C'est CETTE fonction
/// qui allume l'ambre côté UI. # Safety : `session` valide ou null.
#[no_mangle]
pub unsafe extern "C" fn pr_mem_write_i32(
    session: *mut PrSession,
    addr: u64,
    value: i32,
) -> c_int {
    clear_last_error();
    #[cfg(not(feature = "agent-link"))]
    {
        let _ = (session, addr, value);
        PR_ERR_NOT_BUILT
    }
    #[cfg(feature = "agent-link")]
    guard("pr_mem_write_i32", PR_ERR_INTERNAL, || {
        let Some(s) = session.as_mut() else {
            set_last_error("pr_mem_write_i32 : session nulle");
            return PR_ERR_NO_AGENT;
        };
        match crate::link::roundtrip(s, &prism_proto::Cmd::WriteI32 { addr, value }) {
            Ok(prism_proto::Reply::Ok) => PR_OK,
            Ok(prism_proto::Reply::Err { message }) => {
                set_last_error(message);
                PR_ERR_WRITE
            }
            Ok(_) => {
                set_last_error("pr_mem_write_i32 : réponse inattendue");
                PR_ERR_AGENT_PROTO
            }
            Err(e) => {
                set_last_error(e);
                PR_ERR_SESSION_DEAD
            }
        }
    })
}
