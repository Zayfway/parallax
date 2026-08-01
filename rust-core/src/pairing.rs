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

/// Previent Swift que l hote ecoute : identifiant, port, enregistrements TXT.
/// C est Swift qui publie en Bonjour — le demon systeme connait les bonnes
/// interfaces, mdns-sd non.
pub type PxReadyCallback = extern "C" fn(*const c_char, u16, *const *const c_char, *const *const c_char, usize);

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
    on_ready: PxReadyCallback,
) -> c_int {
    clear_last_error();

    let (Some(name), Some(path)) = (cstr(service_name), cstr(out_path)) else {
        set_last_error("px_pairing_run_host : argument nul ou non-UTF-8");
        return PX_ERR_ARG;
    };

    #[cfg(feature = "device-pairing")]
    { imp::run_host(&name, &path, on_pin, on_ready) }
    #[cfg(not(feature = "device-pairing"))]
    {
        let _ = (name, path, on_pin, on_ready);
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

#[cfg(feature = "device-pairing")]
mod imp {
    use super::{PxPinCallback, PxReadyCallback};
    use idevice::remote_pairing::{
        PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
    };
    use std::ffi::{CString, c_char};
    use std::net::Ipv4Addr;
    fn emit_ready(cb: PxReadyCallback, id: &str, port: u16, info: &PairableHostInfo) {
        let records = info.mdns_txt_records(id);
        let keys: Vec<CString> = records.iter()
            .map(|(k, _)| CString::new(k.as_str()).unwrap_or_default()).collect();
        let vals: Vec<CString> = records.iter()
            .map(|(_, v)| CString::new(v.as_str()).unwrap_or_default()).collect();
        let kp: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
        let vp: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();
        if let Ok(id_c) = CString::new(id) {
            cb(id_c.as_ptr(), port, kp.as_ptr(), vp.as_ptr(), records.len());
        }
    }
    pub fn run_host(
        name: &str, out_path: &str, on_pin: PxPinCallback, on_ready: PxReadyCallback,
    ) -> i32 {
        let rt = match tokio::runtime::Runtime::new() {
            Ok(r) => r,
            Err(e) => { crate::set_last_error(format!("runtime tokio : {e}")); return crate::PX_ERR_INTERNAL; }
        };
        let name = name.to_string();
        let out_path = out_path.to_string();
        let result: Result<usize, String> = rt.block_on(async move {
            let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
                .await.map_err(|e| format!("bind : {e}"))?;
            let port = listener.local_addr().map_err(|e| format!("adresse : {e}"))?.port();
            let mut pairing_file = RpPairingFile::generate(&name);
            let host_info = PairableHostInfo::generate(&name, "Mac17,7");
            let service_id = pairing_file.identifier.clone();
            emit_ready(on_ready, &service_id, port, &host_info);
            tracing::info!("hote pret sur le port {port}, annonce deleguee a Swift");
            let (stream, _peer) = listener.accept().await
                .map_err(|e| format!("accept : {e}"))?;
            tracing::info!("appareil connecte, debut de l appairage");
            let socket = RpPairingSocket::new_device(stream);
            let mut host = PairableHost::new(socket, host_info);
            host.accept(&mut pairing_file, move |pin| async move {
                if let Ok(c) = CString::new(pin) { on_pin(c.as_ptr()); }
            }).await.map_err(|e| format!("hote de jumelage : {e}"))?;
            let bytes = pairing_file.to_bytes();
            let len = bytes.len();
            tokio::fs::write(&out_path, &bytes).await
                .map_err(|e| format!("ecriture : {e}"))?;
            tracing::info!("jumelage termine : {} -> {} o", out_path, len);
            Ok(len)
        });
        match result {
            Ok(_) => crate::PX_OK,
            Err(e) => { crate::set_last_error(e); crate::PX_ERR_INTERNAL }
        }
    }
}
