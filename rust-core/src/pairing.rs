//! Host RPPairing — jumelage sans ordinateur.
//!
//! Ce que fait iOS 27 et que les versions précédentes ne font pas : l'entrée
//! *Jumeler avec…* dans Réglages › Confidentialité et sécurité › Mode
//! développeur permet à l'iPhone de se pairer avec un host tournant **sur
//! lui-même**, via le réseau local. Le protocole RPPairing, lui, date d'iOS
//! 17.4 — ce n'est pas lui qui est neuf, c'est l'entrée dans Réglages.
//!
//! Conséquence : ce module ne sert à rien sous iOS 27. Sous cette version,
//! l'utilisateur doit importer un fichier généré au PC avec `idevice_pair`
//! en mode RPPairing. Prévoir ce chemin de repli n'est pas optionnel si tu
//! vises un public large.
//!
//! ⚠️ Format : le fichier produit est un enregistrement **RPPairing**, pas un
//! `.mobiledevicepairing` lockdown classique. SideStore attend historiquement
//! le second. Les builds récentes utilisant le chemin LocalDevVPN/RSD
//! acceptent peut-être le premier — à confirmer sur appareil.
//!
//! Trois responsabilités restent **côté Swift**, car elles ne sont pas
//! exprimables en Rust :
//!   - demander l'autorisation Réseau local ;
//!   - annoncer le service en Bonjour (`NetService`) ;
//!   - garder l'app vivante pendant que l'utilisateur est dans Réglages.
//!     SideInstaller emploie de l'audio silencieux, qui marche dès 17.4, là
//!     où StikPair utilise un `BGContinuedProcessingTask` réservé à iOS 26.
//!     C'est la cause n°1 d'échec : app suspendue = diffusion arrêtée = rien
//!     n'apparaît sous « Jumeler avec ».

use crate::*;

/// Notifie Swift du code à six chiffres dès qu'il est émis.
pub type PxPinCallback = extern "C" fn(*const c_char);

/// Lance le host de jumelage. **Bloquant** — appeler hors du thread principal.
///
/// Écrit l'enregistrement à `out_path` et retourne `PX_OK`. Un fichier de
/// zéro octet est traité comme un échec : mieux vaut échouer bruyamment ici
/// que produire une erreur `NotFound` incompréhensible à la connexion.
///
/// # Safety
/// Chaînes UTF-8 terminées par NUL ; `on_pin` valide pour la durée de l'appel.
#[no_mangle]
pub unsafe extern "C" fn px_pairing_run_host(
    service_name: *const c_char,
    out_path: *const c_char,
    on_pin: PxPinCallback,
) -> c_int {
    clear_last_error();

    let (Some(name), Some(path)) = (cstr(service_name), cstr(out_path)) else {
        set_last_error("px_pairing_run_host : argument nul ou non-UTF-8");
        return PX_ERR_ARG;
    };

    #[cfg(feature = "device-pairing")]
    { imp::run_host(&name, &path, on_pin) }
    #[cfg(not(feature = "device-pairing"))]
    {
        let _ = (name, path, on_pin);
        set_last_error("px_pairing_run_host : compilé sans --features device-pairing");
        PX_ERR_NOT_BUILT
    }
}

/// Vérifie qu'un enregistrement est lisible et non vide.
/// Appelé avant toute connexion — voir la note sur ENOENT ci-dessous.
///
/// # Safety
/// `path` : chaîne UTF-8 terminée par NUL.
#[no_mangle]
pub unsafe extern "C" fn px_pairing_validate(path: *const c_char) -> c_int {
    clear_last_error();

    let Some(path) = cstr(path) else {
        set_last_error("px_pairing_validate : chemin nul");
        return PX_ERR_ARG;
    };

    // Ce contrôle existe à cause d'un piège documenté par SideInstaller :
    // idevice mappe *toute* io::Error sur sa variante `Socket`, donc un
    // fichier de jumelage absent remonte en `Socket(ENOENT)` — ce qui
    // ressemble à s'y méprendre à un échec de socket usbmuxd, et envoie le
    // débogage dans une direction totalement fausse. On refuse d'appeler
    // idevice avec un fichier manquant.
    match std::fs::metadata(&path) {
        Ok(m) if m.len() > 0 => {
            tracing::info!("fichier de jumelage : {} o", m.len());
            PX_OK
        }
        Ok(_) => {
            set_last_error("fichier de jumelage vide (0 octet) — le jumelage n'a pas abouti");
            PX_ERR_NO_PAIRING
        }
        Err(e) => {
            set_last_error(format!("fichier de jumelage introuvable : {e}"));
            PX_ERR_NO_PAIRING
        }
    }
}

// ⚠️ JAMAIS COMPILÉE — portage de `run_host` de StikPair. Vérifier contre la
// révision épinglée avant d'activer `device-pairing`.
#[cfg(feature = "device-pairing")]
mod imp {
    use super::PxPinCallback;
    use std::ffi::CString;

    pub fn run_host(name: &str, out_path: &str, on_pin: PxPinCallback) -> i32 {
        let rt = match tokio::runtime::Runtime::new() {
            Ok(r) => r,
            Err(e) => { crate::set_last_error(format!("runtime tokio : {e}")); return crate::PX_ERR_INTERNAL; }
        };

        rt.block_on(async {
            let emit = |pin: String| {
                if let Ok(c) = CString::new(pin) { on_pin(c.as_ptr()); }
            };

            match idevice::remote_pairing::host::run(name, emit).await {
                Ok(record) => {
                    if let Err(e) = tokio::fs::write(out_path, &record).await {
                        crate::set_last_error(format!("écriture du fichier : {e}"));
                        return crate::PX_ERR_INTERNAL;
                    }
                    tracing::info!("jumelage terminé : {} → {} o", out_path, record.len());
                    crate::PX_OK
                }
                Err(e) => {
                    crate::set_last_error(format!("host de jumelage : {e}"));
                    crate::PX_ERR_INTERNAL
                }
            }
        })
    }
}
