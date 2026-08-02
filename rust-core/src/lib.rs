//! Parallax — cœur natif.
//!
//! Ce crate est une **fine couche FFI**, pas une réimplémentation de protocole.
//! Décision d'architecture explicite : lockdownd, RSD, XPC, le tunnel et la
//! signature sont assurés par `idevice` (jkcoxson) et `isideload` (nab138).
//! Réécrire à la main le tunnel RSD, sensible au threading, serait
//! invérifiable et à haut risque — c'est le même arbitrage que SideInstaller,
//! dont le code n'est qu'à 2,4 % en Rust.
//!
//! Chaque module suit le même patron :
//!
//! ```text
//! #[cfg(feature = "device-x")]  → implémentation réelle
//! #[cfg(not(...))]              → stub renvoyant PX_ERR_NOT_BUILT
//! ```
//!
//! La surface C est identique dans les deux cas. Swift n'a rien à savoir de
//! la configuration de compilation ; il lit le code d'erreur.

use std::ffi::{c_char, c_int, CStr, CString};
use std::ptr;
use std::sync::Mutex;

pub mod account;
pub mod inject;
pub mod install;
pub mod location;
pub mod pairing;
pub mod tunnel;

// Réexporte les symboles #[no_mangle] d'idevice-ffi dans notre staticlib unique.
// Cargo unifie l'instance d'idevice ; vérifier l'absence de doublons avec `nm`
// (la CI le fait).
#[cfg(feature = "device")]
const _: () = ();

// ═══════════════════════════════════════════════════════════════════════════
// Codes d'erreur — stables, mappés vers des messages par la couche Swift.
// ═══════════════════════════════════════════════════════════════════════════

pub const PX_OK: c_int = 0;
pub const PX_ERR_ARG: c_int = -1;
pub const PX_ERR_INTERNAL: c_int = -2;
/// La fonctionnalité existe mais le crate a été compilé sans le flag `device`.
/// Swift l'affiche tel quel : « module natif non compilé ».
pub const PX_ERR_NOT_BUILT: c_int = -3;
pub const PX_ERR_NO_TUNNEL: c_int = -4;
pub const PX_ERR_NO_PAIRING: c_int = -5;
pub const PX_ERR_DDI_NOT_MOUNTED: c_int = -10;
pub const PX_ERR_DDI_MOUNT_FAILED: c_int = -11;
pub const PX_ERR_DVT_OPEN_FAILED: c_int = -12;
pub const PX_ERR_SESSION_DEAD: c_int = -13;
pub const PX_ERR_AUTH_FAILED: c_int = -20;
pub const PX_ERR_2FA_REQUIRED: c_int = -21;
pub const PX_ERR_SIGN_FAILED: c_int = -22;

// ═══════════════════════════════════════════════════════════════════════════
// Dernière erreur
//
// Un slot global plutôt qu'un `out_error: **c_char` sur chaque fonction :
// ça garde la surface C lisible, et Swift n'a jamais à libérer de mémoire
// qu'il n'a pas allouée. Valide jusqu'au prochain appel FFI.
// ═══════════════════════════════════════════════════════════════════════════

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

pub(crate) fn clear_last_error() {
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = None;
    }
}

/// Message de la dernière erreur, ou NULL. **Ne pas libérer côté Swift.**
#[no_mangle]
pub extern "C" fn px_last_error() -> *const c_char {
    match LAST_ERROR.lock() {
        Ok(slot) => slot.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
        Err(_) => ptr::null(),
    }
}

/// Exécute `f` en interceptant les paniques.
///
/// Une panique qui traverse la frontière FFI devient un `abort` : l'app meurt
/// sans message, sans journal, sans rien à montrer à l'utilisateur. Toute
/// entrée qui appelle du code `imp::` doit passer par ici.
///
/// `AssertUnwindSafe` est assumé : on ne reprend jamais l'exécution sur l'état
/// qui a paniqué, on rend une valeur de repli et on remonte l'erreur.
#[allow(dead_code)] // Utilise uniquement depuis les modules sous features.
pub(crate) fn guard<T>(name: &str, fallback: T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(value) => value,
        Err(_) => {
            set_last_error(format!("{name} : panique interne du cœur natif"));
            fallback
        }
    }
}

/// Lit une chaîne C en `String`, ou `None` si nulle ou non-UTF-8.
///
/// # Safety
/// `ptr` doit être nul ou pointer sur une chaîne UTF-8 terminée par NUL.
pub(crate) unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(str::to_owned)
}

// ═══════════════════════════════════════════════════════════════════════════
// Spine de log
// ═══════════════════════════════════════════════════════════════════════════

pub type PxLogCallback = extern "C" fn(*const c_char);

static LOG_SINK: Mutex<Option<PxLogCallback>> = Mutex::new(None);

struct SwiftWriter;

impl std::io::Write for SwiftWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if let Ok(slot) = LOG_SINK.lock() {
            if let Some(cb) = *slot {
                let line = String::from_utf8_lossy(buf);
                if let Ok(c) = CString::new(line.trim_end()) {
                    cb(c.as_ptr());
                }
            }
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}

/// Redirige tout le `tracing` — le nôtre **et celui d'idevice** — vers Swift.
///
/// C'est le premier appel à faire, avant tout le reste : sans lui, les erreurs
/// d'idevice disparaissent dans le vide et le débogage sur appareil devient
/// impossible. Idempotent.
#[no_mangle]
pub extern "C" fn px_log_init(callback: PxLogCallback) -> c_int {
    if let Ok(mut slot) = LOG_SINK.lock() {
        *slot = Some(callback);
    }

    use tracing_subscriber::fmt;
    let result = fmt()
        .with_writer(|| SwiftWriter)
        .with_ansi(false)
        .with_target(true)
        .with_level(true)
        .without_time() // Swift horodate déjà côté console.
        .try_init();

    match result {
        Ok(()) => {
            tracing::info!("px_log_init: cœur Rust vivant ({})", build_profile());
            PX_OK
        }
        // Déjà initialisé : ce n'est pas une erreur, le sink a été remplacé.
        Err(_) => PX_OK,
    }
}

/// Décrit ce qui a réellement été compilé. Swift l'affiche dans les réglages ;
/// c'est la première chose à vérifier quand une fonctionnalité ne répond pas.
#[no_mangle]
pub extern "C" fn px_build_profile() -> *const c_char {
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

fn build_profile() -> &'static str {
    #[cfg(feature = "device")]
    { "device: complet" }
    #[cfg(all(not(feature = "device"), feature = "device-location", not(feature = "device-account")))]
    { "device: location seule" }
    #[cfg(all(not(feature = "device"), not(feature = "device-location"), not(feature = "device-account"), feature = "device-pairing"))]
    { "device: jumelage seul" }
    #[cfg(all(not(feature = "device"), not(feature = "device-location"), not(feature = "device-account"), not(feature = "device-pairing")))]
    { "stub: aucun module natif compilé" }
    #[cfg(all(not(feature = "device"), feature = "device-account"))]
    { "device: sideloading (jumelage + compte)" }
}

/// Test de vie de bout en bout : Swift appelle, Rust journalise, Swift reçoit
/// la ligne dans sa console. Si ça marche, le pont FFI est sain.
#[no_mangle]
pub extern "C" fn px_ping() -> c_int {
    tracing::info!("px_ping: pont FFI opérationnel");
    PX_OK
}
