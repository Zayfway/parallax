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
    use std::ffi::CStr;

    pub struct Session {
        pub sideloader: isideload::Sideloader,
        pub runtime: tokio::runtime::Runtime,
    }

    pub fn sign_in(
        email: &str, password: &str, anisette: &str, storage: &str,
        on_2fa: PxTwoFactorCallback,
    ) -> Result<Session, String> {
        let runtime = tokio::runtime::Runtime::new()
            .map_err(|e| format!("runtime tokio : {e}"))?;

        let sideloader = runtime.block_on(async {
            let account = isideload::AppleAccount::builder()
                .anisette_provider(isideload::anisette::RemoteV3::new(anisette))
                .login(email, password, || {
                    // Pont bloquant vers l'invite Swift.
                    let ptr = on_2fa();
                    if ptr.is_null() { return None; }
                    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(str::to_owned)
                })
                .await?;

            let dev = isideload::DeveloperSession::from_account(&account)?;
            isideload::SideloaderBuilder::new(dev)
                .team(isideload::TeamSelector::First)
                .storage(isideload::FsStorage::new(storage))
                .machine_name("Parallax")
                .build()
        }).map_err(|e| format!("connexion Apple : {e}"))?;

        tracing::info!("compte Apple connecté");
        Ok(Session { sideloader, runtime })
    }

    pub fn sign(s: &mut Session, ipa: &str) -> Result<String, String> {
        s.runtime
            .block_on(async { s.sideloader.sign_app(ipa, None, false).await })
            .map(|p| p.to_string_lossy().into_owned())
            .map_err(|e| format!("signature : {e}"))
    }
}
