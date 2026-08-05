//! Prism — cœur hôte (surface FFI `pr_*`). Structure calquée sur
//! `rust-core/src/lib.rs` de Parallax : codes d'erreur, canal d'erreur unique,
//! gardes anti-panique, profil de compilation.
//!
//! Hors feature `agent-link`, tout est stub : les fonctions rendant `c_int`
//! rendent `PR_ERR_NOT_BUILT`, celles rendant un pointeur rendent `NULL` +
//! `set_last_error`. Exactement l'asymétrie Parallax.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::sync::Mutex;

mod link;
mod scan;

pub use link::PrSession;

// ── Codes d'erreur (mêmes familles numériques que Parallax) ─────────────────
pub const PR_OK: c_int = 0;
pub const PR_ERR_ARG: c_int = -1;
pub const PR_ERR_INTERNAL: c_int = -2;
/// La fonctionnalité existe mais le crate a été compilé sans `agent-link`.
/// Swift l'affiche tel quel : « module natif non compilé ».
pub const PR_ERR_NOT_BUILT: c_int = -3;
pub const PR_ERR_NO_AGENT: c_int = -4; // session nulle / jamais ouverte
pub const PR_ERR_AGENT_PROTO: c_int = -5; // réponse hors protocole
pub const PR_ERR_REGION: c_int = -10; // énumération des régions refusée
pub const PR_ERR_READ: c_int = -11; // lecture mémoire refusée
pub const PR_ERR_WRITE: c_int = -12; // écriture / vm_protect refusée
pub const PR_ERR_SESSION_DEAD: c_int = -13; // canal fermé sous nos pieds
pub const PR_ERR_NO_MATCH: c_int = -20; // ensemble de candidats vide
pub const PR_ERR_SCAN_STATE: c_int = -21; // affinage avant recherche initiale
pub const PR_ERR_PATCH_FAILED: c_int = -22; // RÉSERVÉ patch Mach-O (jalon 2)

// ── Opérations d'affinage (GameGuardian), exposées à Swift ──────────────────
pub const PR_REFINE_EQ: c_int = 0;
pub const PR_REFINE_INCREASED: c_int = 1;
pub const PR_REFINE_DECREASED: c_int = 2;
pub const PR_REFINE_UNCHANGED: c_int = 3;

pub type PrLogCallback = extern "C" fn(*const c_char);

// ── Canal d'erreur unique ───────────────────────────────────────────────────
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);

pub(crate) fn set_last_error(msg: impl AsRef<str>) {
    let text = msg.as_ref();
    tracing::error!("{text}");
    let c = CString::new(text)
        .unwrap_or_else(|_| CString::new("erreur non représentable").unwrap());
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = Some(c);
    }
}

#[allow(dead_code)]
pub(crate) fn clear_last_error() {
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = None;
    }
}

/// Dernier message d'erreur (emprunté, NE PAS libérer).
#[no_mangle]
pub extern "C" fn pr_last_error() -> *const c_char {
    match LAST_ERROR.lock() {
        Ok(slot) => slot.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
        Err(_) => ptr::null(),
    }
}

// ── Gardes ──────────────────────────────────────────────────────────────────
#[allow(dead_code)]
pub(crate) fn guard<T>(name: &str, fallback: T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_last_error(format!("{name} : panique interne du cœur natif"));
            fallback
        }
    }
}

#[allow(dead_code)]
pub(crate) fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
}

/// Unique libérateur de chaînes. # Safety : `s` null ou issu de ce module.
#[no_mangle]
pub unsafe extern "C" fn pr_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

// ── Vie / diagnostic ────────────────────────────────────────────────────────
#[no_mangle]
pub extern "C" fn pr_ping() -> c_int {
    tracing::info!("pr_ping");
    PR_OK
}

static LOG_CB: Mutex<Option<PrLogCallback>> = Mutex::new(None);

/// Installe un pont de log Rust -> Swift. Idempotent.
#[no_mangle]
pub extern "C" fn pr_log_init(cb: PrLogCallback) -> c_int {
    if let Ok(mut slot) = LOG_CB.lock() {
        *slot = Some(cb);
    }
    PR_OK
}

#[allow(dead_code)]
pub(crate) fn log_line(msg: &str) {
    if let Ok(slot) = LOG_CB.lock() {
        if let Some(cb) = *slot {
            if let Ok(c) = CString::new(msg) {
                cb(c.as_ptr());
            }
        }
    }
}

// ── Profil de compilation ───────────────────────────────────────────────────
// Doit reconnaître CHAQUE combinaison, sinon les Réglages affichent « stub »
// alors que le natif est là (piège Parallax).
fn build_profile() -> &'static str {
    #[cfg(feature = "full")]
    {
        "prism: complet"
    }
    #[cfg(all(not(feature = "full"), feature = "agent-link"))]
    {
        "prism: lien agent (mémoire vive)"
    }
    #[cfg(all(
        not(feature = "full"),
        not(feature = "agent-link"),
        feature = "static-macho"
    ))]
    {
        "prism: analyse statique seule"
    }
    #[cfg(all(
        not(feature = "full"),
        not(feature = "agent-link"),
        not(feature = "static-macho")
    ))]
    {
        "stub: aucun module natif compilé"
    }
}

/// Profil de compilation (emprunté, caché en static, NE PAS libérer).
#[no_mangle]
pub extern "C" fn pr_build_profile() -> *const c_char {
    static PROFILE: Mutex<Option<CString>> = Mutex::new(None);
    let mut slot = match PROFILE.lock() {
        Ok(s) => s,
        Err(_) => return ptr::null(),
    };
    if slot.is_none() {
        *slot = CString::new(build_profile()).ok();
    }
    slot.as_ref().map_or(ptr::null(), |c| c.as_ptr())
}
