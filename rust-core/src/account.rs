//! Compte Apple, certificats, signature — via isideload.
//!
//! ── SUR LA CONFIDENTIALITÉ, SANS ENJOLIVER ────────────────────────────────
//!
//! Le mot de passe ne quitte pas l'appareil : il sert localement au login.
//! Mais l'authentification Apple exige des données d'attestation (**Anisette**)
//! impossibles à produire sur un iPhone non jailbreaké. Elles viennent donc
//! d'un **serveur relais tiers** — `ani.sidestore.io` par défaut.
//!
//! Autrement dit : l'identifiant et le contexte d'authentification transitent
//! par une machine que l'utilisateur ne contrôle pas. Ce n'est pas un défaut
//! d'implémentation, c'est structurel à toute la famille AltStore/SideStore.
//! Mais écrire « vos identifiants ne quittent jamais votre appareil » est,
//! à la lettre, faux — et un projet open source s'expose à la critique dès la
//! première lecture attentive. D'où : serveur configurable, et formulation
//! exacte dans l'interface.
//! ──────────────────────────────────────────────────────────────────────────
//!
//! Coexistence de versions : isideload tire idevice 0.1.61 (crates.io, derrière
//! sa feature `install`, obligatoire car son feature-gating est incomplet)
//! tandis que le reste utilise 0.1.63 (git). Les deux coexistent comme crates
//! distincts — hashs de symboles différents, pas de collision. On n'appelle que
//! le chemin sign-only, qui ne touche jamais idevice.

use crate::*;

/// Demande un code 2FA à Swift. **Bloquant** : l'implémentation Swift doit
/// présenter l'invite et attendre la saisie (sémaphore), puis renvoyer une
/// chaîne C de 6 chiffres, ou NULL si l'utilisateur annule.
pub type PxTwoFactorCallback = extern "C" fn() -> *const c_char;

/// Session de signature opaque.
pub struct PxSignSession {
    #[cfg(feature = "device-account")]
    inner: imp::Session,
    #[cfg(not(feature = "device-account"))]
    _private: (),
}

/// Connexion au compte Apple. NULL en cas d'échec — lire `px_last_error`.
///
/// # Safety
/// Chaînes UTF-8 terminées par NUL ; callback valide pendant l'appel.
#[no_mangle]
pub unsafe extern "C" fn px_apple_signin(
    email: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    storage_dir: *const c_char,
    on_2fa: PxTwoFactorCallback,
) -> *mut PxSignSession {
    clear_last_error();

    let (Some(email), Some(password), Some(storage)) =
        (cstr(email), cstr(password), cstr(storage_dir))
    else {
        set_last_error("px_apple_signin : argument nul");
        return ptr::null_mut();
    };
    let anisette = cstr(anisette_url)
        .unwrap_or_else(|| "https://ani.sidestore.io".to_string());

    #[cfg(feature = "device-account")]
    {
        match imp::sign_in(&email, &password, &anisette, &storage, on_2fa) {
            Ok(inner) => Box::into_raw(Box::new(PxSignSession { inner })),
            Err(msg) => { set_last_error(msg); ptr::null_mut() }
        }
    }
    #[cfg(not(feature = "device-account"))]
    {
        let _ = (email, password, anisette, storage, on_2fa);
        set_last_error("px_apple_signin : compilé sans --features device-account");
        ptr::null_mut()
    }
}

/// Signe un `.ipa`. Enregistre l'App ID, crée ou récupère le certificat et le
/// profil, puis signe via `apple-codesign`. Écrit le chemin du bundle `.app`
/// signé dans `out_path` (taille `out_len`).
///
/// # Safety
/// `session` valide ; `out_path` pointe sur un tampon d'au moins `out_len`.
#[no_mangle]
pub unsafe extern "C" fn px_sign_ipa(
    session: *mut PxSignSession,
    ipa_path: *const c_char,
    out_path: *mut c_char,
    out_len: usize,
) -> c_int {
    clear_last_error();

    if session.is_null() || out_path.is_null() || out_len == 0 {
        set_last_error("px_sign_ipa : argument nul");
        return PX_ERR_ARG;
    }
    let Some(ipa) = cstr(ipa_path) else {
        set_last_error("px_sign_ipa : chemin d'IPA nul");
        return PX_ERR_ARG;
    };

    #[cfg(feature = "device-account")]
    {
        match imp::sign(&mut (*session).inner, &ipa) {
            Ok(signed) => {
                let bytes = signed.as_bytes();
                if bytes.len() + 1 > out_len {
                    set_last_error("px_sign_ipa : tampon de sortie trop petit");
                    return PX_ERR_ARG;
                }
                ptr::copy_nonoverlapping(bytes.as_ptr(), out_path as *mut u8, bytes.len());
                *out_path.add(bytes.len()) = 0;
                PX_OK
            }
            Err(msg) => { set_last_error(msg); PX_ERR_SIGN_FAILED }
        }
    }
    #[cfg(not(feature = "device-account"))]
    {
        let _ = ipa;
        set_last_error("px_sign_ipa : compilé sans --features device-account");
        PX_ERR_NOT_BUILT
    }
}

/// Libère la session. **Consomme** le pointeur.
///
/// # Safety
/// `session` issu de `px_apple_signin`, libéré exactement une fois.
#[no_mangle]
pub unsafe extern "C" fn px_sign_session_free(session: *mut PxSignSession) {
    if session.is_null() { return; }
    drop(Box::from_raw(session));
}

// ⚠️ JAMAIS COMPILÉE.
#[cfg(feature = "device-account")]
mod imp {
    use super::PxTwoFactorCallback;
    use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
    use isideload::auth::apple_account::{
        AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
    };
    use isideload::dev::developer_session::DeveloperSession;
    use isideload::sideload::sideloader::Sideloader;
    use isideload::sideload::{SideloaderBuilder, TeamSelection};
    use isideload::util::fs_storage::FsStorage;
    use isideload::util::storage::InMemoryStorage;
    use std::ffi::CStr;
    use std::path::PathBuf;

    pub struct Session {
        pub sideloader: Sideloader,
        pub runtime: tokio::runtime::Runtime,
        /// Même dossier que celui passé au `SideloaderBuilder`. Les champs du
        /// `Sideloader` sont privés, donc pour générer un certificat hors du
        /// chemin `sign_app` il faut reconstruire un `FsStorage` identique —
        /// c'est là que vit la clé privée, indexée par courriel.
        pub storage_dir: PathBuf,
    }

    /// Nom de machine déclaré à Apple. Doit rester identique à
    /// `FFI.machineName` côté Swift, qui s'en sert pour reconnaître, dans la
    /// liste renvoyée par Apple, l'emplacement occupé par cette app.
    pub const MACHINE_NAME: &str = "Parallax";

    pub fn sign_in(
        email: &str, password: &str, _anisette: &str, storage: &str,
        on_2fa: PxTwoFactorCallback,
    ) -> Result<Session, String> {
        let runtime = tokio::runtime::Runtime::new()
            .map_err(|e| format!("runtime tokio : {e}"))?;

        let email = email.to_string();
        let password = password.to_string();
        let storage_path = PathBuf::from(storage);

        let sideloader = runtime.block_on(async move {
            let anisette = RemoteV3AnisetteProvider::default()
                .map_err(|e| format!("anisette : {e}"))?
                .set_storage(Box::new(InMemoryStorage::new()));

            let mut account = AppleAccount::builder(&email)
                .anisette_provider(anisette)
                .login(&password, Box::new(move |_p: TwoFactorCallbackParams| {
                    let ptr = on_2fa();
                    let code = if ptr.is_null() {
                        String::new()
                    } else {
                        unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("").to_owned()
                    };
                    TwoFactorCallbackResponse::SubmitCode(code)
                }))
                .await
                .map_err(|e| format!("connexion Apple : {e}"))?;

            let dev = DeveloperSession::from_account(&mut account)
                .await
                .map_err(|e| format!("session developpeur : {e}"))?;

            Ok::<_, String>(
                SideloaderBuilder::new(dev, email.clone())
                    .team_selection(TeamSelection::PromptOnce(|teams| {
                        teams.first().map(|t| t.team_id.clone())
                    }))
                    .storage(Box::new(FsStorage::new(storage_path)))
                    .machine_name(MACHINE_NAME.to_string())
                    .build(),
            )
        })?;

        tracing::info!("compte Apple connecte");
        Ok(Session { sideloader, runtime, storage_dir: PathBuf::from(storage) })
    }

    /// Récupère le certificat de cette machine, ou en demande un neuf.
    ///
    /// `MaxCertsBehavior::Error` et non `Revoke` : quand le quota est atteint,
    /// c'est à l'utilisateur de choisir ce qu'il sacrifie depuis l'écran, pas
    /// à nous de révoquer dans son dos. Le message d'Apple remonte tel quel.
    ///
    /// Rend le numéro de série, le même que celui listé par `list_certs`.
    pub fn create_cert(s: &mut Session) -> Result<String, String> {
        use isideload::sideload::builder::MaxCertsBehavior;
        use isideload::sideload::cert_identity::CertificateIdentity;

        let dir = s.storage_dir.clone();
        s.runtime.block_on(async {
            let team = s.sideloader.get_team().await
                .map_err(|e| format!("equipe : {e}"))?;
            let email = s.sideloader.get_email().to_string();
            let storage = FsStorage::new(dir);

            let identity = CertificateIdentity::retrieve(
                MACHINE_NAME,
                &email,
                s.sideloader.get_dev_session(),
                &team,
                &storage,
                &MaxCertsBehavior::Error,
            )
            .await
            .map_err(|e| format!("certificat : {e}"))?;

            let serial = identity.get_serial_number();
            tracing::info!("certificat disponible : {serial}");
            Ok::<_, String>(serial)
        })
    }

    pub fn sign(s: &mut Session, ipa: &str) -> Result<String, String> {
        s.runtime
            .block_on(async { s.sideloader.sign_app(ipa.into(), None, false).await })
            .map(|p| p.0.to_string_lossy().into_owned())
            .map_err(|e| format!("signature : {e}"))
    }

    use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
    use isideload::dev::device_type::DeveloperDeviceType;

    #[derive(serde::Serialize)]
    struct CertInfo {
        name: String,
        serial_number: String,
        machine_name: String,
        certificate_id: String,
        status: String,
        expiration: String,
        /// Quota déclaré par Apple pour ce type de certificat. `None` quand
        /// Apple ne le renseigne pas — c'est la seule source honnête du
        /// nombre d'emplacements, qui n'est pas trois sur un compte payant.
        max_active_certs: Option<i64>,
    }

    impl From<&DevelopmentCertificate> for CertInfo {
        fn from(c: &DevelopmentCertificate) -> Self {
            let s = |o: &Option<String>| o.clone().unwrap_or_default();
            CertInfo {
                name: s(&c.name),
                serial_number: s(&c.serial_number),
                machine_name: s(&c.machine_name),
                certificate_id: s(&c.certificate_id),
                status: s(&c.status),
                expiration: c.expiration_date.as_ref()
                    .map(|d| d.to_xml_format()).unwrap_or_default(),
                max_active_certs: c.certificate_type.as_ref()
                    .and_then(|t| t.max_active_certs),
            }
        }
    }

    pub fn list_certs(s: &mut Session) -> Result<String, String> {
        s.runtime.block_on(async {
            let team = s.sideloader.get_team().await
                .map_err(|e| format!("equipe : {e}"))?;
            let certs = s.sideloader.get_dev_session()
                .list_ios_certs(&team).await
                .map_err(|e| format!("liste des certificats : {e}"))?;
            tracing::info!("{} certificat(s) de developpement iOS", certs.len());
            let infos: Vec<CertInfo> = certs.iter().map(CertInfo::from).collect();
            serde_json::to_string(&infos).map_err(|e| format!("json : {e}"))
        })
    }

    pub fn revoke_cert(s: &mut Session, serial: &str) -> Result<(), String> {
        s.runtime.block_on(async {
            let team = s.sideloader.get_team().await
                .map_err(|e| format!("equipe : {e}"))?;
            tracing::info!("revocation du certificat {serial}");
            s.sideloader.get_dev_session()
                .revoke_development_cert(&team, serial, DeveloperDeviceType::Ios)
                .await
                .map_err(|e| format!("revocation : {e}"))
        })
    }
}

/// Accès interne à la session, pour `install.rs`. Les handles restent opaques
/// côté Swift ; c'est le seul endroit du crate qui déballe celui-ci.
///
/// # Safety
/// `session` non nul, issu de `px_apple_signin`, encore vivant.
#[cfg(feature = "device-account")]
pub(crate) unsafe fn session_inner(session: *mut PxSignSession) -> &'static mut imp::Session {
    &mut (*session).inner
}

/// Certificats de developpement iOS de l equipe, en JSON. NULL en cas d echec.
/// La chaine rendue doit etre liberee par `px_string_free`.
///
/// # Safety
/// `session` doit venir de `px_apple_signin`.
#[no_mangle]
pub unsafe extern "C" fn px_cert_list(session: *mut PxSignSession) -> *mut c_char {
    clear_last_error();
    if session.is_null() {
        set_last_error("px_cert_list : session nulle");
        return ptr::null_mut();
    }
    #[cfg(feature = "device-account")]
    {
        guard("px_cert_list", ptr::null_mut(), || {
            match imp::list_certs(&mut (*session).inner) {
                Ok(json) => std::ffi::CString::new(json)
                    .map(|c| c.into_raw())
                    .unwrap_or(ptr::null_mut()),
                Err(e) => { set_last_error(e); ptr::null_mut() }
            }
        })
    }
    #[cfg(not(feature = "device-account"))]
    {
        set_last_error("px_cert_list : compile sans --features device-account");
        ptr::null_mut()
    }
}

/// Revoque un certificat par son numero de serie.
///
/// # Safety
/// `session` doit venir de `px_apple_signin` ; `serial` chaine UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_cert_revoke(
    session: *mut PxSignSession, serial: *const c_char,
) -> c_int {
    clear_last_error();
    let Some(serial) = cstr(serial) else {
        set_last_error("px_cert_revoke : numero de serie nul");
        return PX_ERR_ARG;
    };
    if session.is_null() {
        set_last_error("px_cert_revoke : session nulle");
        return PX_ERR_ARG;
    }
    #[cfg(feature = "device-account")]
    {
        guard("px_cert_revoke", PX_ERR_INTERNAL, || {
            match imp::revoke_cert(&mut (*session).inner, &serial) {
                Ok(()) => PX_OK,
                Err(e) => { set_last_error(e); PX_ERR_INTERNAL }
            }
        })
    }
    #[cfg(not(feature = "device-account"))]
    {
        let _ = serial;
        set_last_error("px_cert_revoke : compile sans --features device-account");
        PX_ERR_NOT_BUILT
    }
}

/// Récupère le certificat de développement de cette machine, ou en demande un
/// neuf à Apple. Rend son numéro de série, à libérer par `px_string_free`.
/// NULL en cas d'échec — lire `px_last_error`.
///
/// Idempotent : si un certificat correspondant à la clé privée locale existe
/// déjà, il est réutilisé plutôt que dupliqué. Quand le quota est atteint,
/// échoue avec le message d'Apple au lieu de révoquer quoi que ce soit.
///
/// # Safety
/// `session` doit venir de `px_apple_signin`.
#[no_mangle]
pub unsafe extern "C" fn px_cert_create(session: *mut PxSignSession) -> *mut c_char {
    clear_last_error();
    if session.is_null() {
        set_last_error("px_cert_create : session nulle");
        return ptr::null_mut();
    }
    #[cfg(feature = "device-account")]
    {
        guard("px_cert_create", ptr::null_mut(), || {
            match imp::create_cert(&mut (*session).inner) {
                Ok(serial) => std::ffi::CString::new(serial)
                    .map(|c| c.into_raw())
                    .unwrap_or(ptr::null_mut()),
                Err(e) => { set_last_error(e); ptr::null_mut() }
            }
        })
    }
    #[cfg(not(feature = "device-account"))]
    {
        set_last_error("px_cert_create : compilé sans --features device-account");
        ptr::null_mut()
    }
}

/// Libere une chaine rendue par le coeur natif.
///
/// # Safety
/// `s` doit etre null ou provenir de ce module.
#[no_mangle]
pub unsafe extern "C" fn px_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(std::ffi::CString::from_raw(s));
    }
}
