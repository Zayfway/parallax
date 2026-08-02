//! Installation d'un IPA, de bout en bout et sans ordinateur.
//!
//! Quatre gestes, dans cet ordre, et l'ordre n'est pas négociable :
//!
//!   1. `ensure_device_registered` — l'appareil doit appartenir à l'équipe
//!      **avant** toute signature. Sinon Apple refuse le profil de
//!      provisionnement avec l'erreur **8220**, dont le message ne dit rien.
//!   2. `sign_app` — enregistre l'App ID, récupère ou crée le certificat, écrit
//!      le profil, signe. Rend le bundle signé et, accessoirement, l'app
//!      spéciale détectée (SideStore, LiveContainer…).
//!   3. AFC — pousse le bundle vers `PublicStaging` par le tunnel.
//!   4. `installation_proxy` — demande l'installation de ce qui a été poussé.
//!
//! Les étapes 3 et 4 sont assurées par `idevice::utils::installation`, dont les
//! variantes `*_rsd` prennent exactement `(&mut impl RsdProvider, &mut
//! RsdHandshake)` — soit ce que détient déjà notre tunnel, `AdapterHandle`
//! implémentant `RsdProvider`.
//!
//! ── CE QU'ON N'UTILISE PAS, ET POURQUOI ───────────────────────────────────
//!
//! **`isideload::install_app`** exige un `IdeviceProvider`, donc un
//! `PairingFile` **lockdown**, que notre jumelage RPPairing ne produit pas.
//! Elle est structurellement hors de portée, pas seulement peu pratique.
//!
//! **`isideload::install_app_rsd`** existe pourtant et ferait l'affaire — sauf
//! que ses types viennent d'`idevice` 0.1.65 (crates.io, tiré par isideload)
//! alors que le tunnel produit ceux d'`idevice` git. Deux crates distincts,
//! types non interchangeables : c'est exactement ce que l'étape CI « symboles
//! dupliqués » veille à préserver. Un pont coûterait une seconde pile RSD pour
//! économiser quarante lignes.
//!
//! **`Sideloader::install_app`** ne fait qu'enchaîner ; son premier geste est
//! de lire l'appareil par lockdown. On reprend donc son enchaînement à la main.
//!
//! ── DEUX RUNTIMES, ET C'EST VOULU ─────────────────────────────────────────
//!
//! La signature s'exécute sur le runtime de la session Apple, l'installation
//! sur celui du tunnel — parce que les tâches de fond de la pile TCP y vivent.
//! Les deux phases sont séquentielles, donc jamais concurrentes sur la même
//! ressource.

use crate::account::PxSignSession;
use crate::tunnel::PxTunnel;
use crate::*;

/// Progression, de 0 à 100. Appelé depuis des threads Rust — l'implémentation
/// Swift doit donc être une fonction de **portée fichier**, sans quoi le
/// runtime trappe sur l'isolation d'acteur.
pub type PxProgressCallback = extern "C" fn(u32, *const c_char);

/// Installe un `.ipa` : enregistrement de l'appareil, signature, transfert,
/// installation.
///
/// `udid` vient du fichier d'identité écrit au moment du jumelage — le
/// `RpPairingFile` ne le contient pas.
///
/// Rend le nom de l'app spéciale détectée (« SideStore », « SideStore+
/// LiveContainer »…) ou une chaîne vide si l'IPA n'en est pas une. NULL en cas
/// d'échec. À libérer par `px_string_free`.
///
/// **Bloquant**, et longuement : plusieurs allers-retours chez Apple puis un
/// transfert de fichier. À appeler depuis `DispatchQueue.global`.
///
/// # Safety
/// `session` issu de `px_apple_signin`, `tunnel` de `px_tunnel_connect`, tous
/// deux encore vivants. Chaînes UTF-8 terminées par NUL.
#[no_mangle]
pub unsafe extern "C" fn px_install_ipa(
    session: *mut PxSignSession,
    tunnel: *mut PxTunnel,
    ipa_path: *const c_char,
    udid: *const c_char,
    device_name: *const c_char,
    dylib_paths: *const *const c_char,
    dylib_count: usize,
    injection_path: *const c_char,
    injection_folder: *const c_char,
    inject_into_extensions: bool,
    on_progress: PxProgressCallback,
) -> *mut c_char {
    clear_last_error();

    if session.is_null() || tunnel.is_null() {
        set_last_error("px_install_ipa : session ou tunnel nul");
        return ptr::null_mut();
    }
    let (Some(ipa), Some(udid)) = (cstr(ipa_path), cstr(udid)) else {
        set_last_error("px_install_ipa : chemin d'IPA ou UDID nul");
        return ptr::null_mut();
    };
    if udid.is_empty() {
        set_last_error(
            "px_install_ipa : UDID vide — refais le jumelage, l'identité de l'appareil est écrite à ce moment-là",
        );
        return ptr::null_mut();
    }
    let name = cstr(device_name).unwrap_or_else(|| "iPhone".to_string());

    // Tweaks (.dylib) à injecter avant signature. Tableau vide = installation
    // normale, chemin inchangé.
    let dylibs: Vec<String> = if dylib_paths.is_null() || dylib_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(dylib_paths, dylib_count)
            .iter()
            .filter_map(|&p| unsafe { cstr(p) })
            .collect()
    };

    // Options d'injection façon Feather ; valeurs par défaut si non fournies.
    let inject_path = cstr(injection_path).unwrap_or_default();
    let inject_folder = cstr(injection_folder).unwrap_or_default();

    #[cfg(all(feature = "device-account", feature = "device-pairing"))]
    {
        guard("px_install_ipa", ptr::null_mut(), || {
            match imp::install(
                session, tunnel, &ipa, &udid, &name, &dylibs,
                &inject_path, &inject_folder, inject_into_extensions, on_progress,
            ) {
                Ok(special) => CString::new(special)
                    .map(|c| c.into_raw())
                    .unwrap_or(ptr::null_mut()),
                Err(e) => {
                    set_last_error(e);
                    ptr::null_mut()
                }
            }
        })
    }
    #[cfg(not(all(feature = "device-account", feature = "device-pairing")))]
    {
        let _ = (ipa, udid, name, dylibs, inject_path, inject_folder,
                 inject_into_extensions, on_progress);
        set_last_error(
            "px_install_ipa : compilé sans --features device-account,device-pairing",
        );
        ptr::null_mut()
    }
}

/// Installe un `.ipa` signé **hors-ligne** avec un certificat importé
/// (`.p12` + `.mobileprovision`) — sans compte Apple. Injecte les tweaks
/// éventuels, signe, transfère et installe par le tunnel.
///
/// Rend une chaîne vide en cas de succès (pas de détection d'app spéciale ici),
/// NULL en cas d'échec. À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` issu de `px_tunnel_connect`, encore vivant. Chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_install_ipa_p12(
    tunnel: *mut PxTunnel,
    ipa_path: *const c_char,
    p12_path: *const c_char,
    p12_password: *const c_char,
    profile_path: *const c_char,
    dylib_paths: *const *const c_char,
    dylib_count: usize,
    injection_path: *const c_char,
    injection_folder: *const c_char,
    inject_into_extensions: bool,
    on_progress: PxProgressCallback,
) -> *mut c_char {
    clear_last_error();

    if tunnel.is_null() {
        set_last_error("px_install_ipa_p12 : tunnel nul");
        return ptr::null_mut();
    }
    let (Some(ipa), Some(p12p), Some(profp)) =
        (cstr(ipa_path), cstr(p12_path), cstr(profile_path))
    else {
        set_last_error("px_install_ipa_p12 : chemin IPA, p12 ou profil nul");
        return ptr::null_mut();
    };
    let password = cstr(p12_password).unwrap_or_default();

    let dylibs: Vec<String> = if dylib_paths.is_null() || dylib_count == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(dylib_paths, dylib_count)
            .iter()
            .filter_map(|&p| unsafe { cstr(p) })
            .collect()
    };
    let inject_path = cstr(injection_path).unwrap_or_default();
    let inject_folder = cstr(injection_folder).unwrap_or_default();

    #[cfg(all(feature = "device-account", feature = "device-pairing"))]
    {
        let p12_bytes = match std::fs::read(&p12p) {
            Ok(b) => b,
            Err(e) => {
                set_last_error(format!("p12 illisible : {e}"));
                return ptr::null_mut();
            }
        };
        let profile_bytes = match std::fs::read(&profp) {
            Ok(b) => b,
            Err(e) => {
                set_last_error(format!("profil illisible : {e}"));
                return ptr::null_mut();
            }
        };
        guard("px_install_ipa_p12", ptr::null_mut(), || {
            match imp::install_offline(
                tunnel, &ipa, &p12_bytes, &password, &profile_bytes, &dylibs,
                &inject_path, &inject_folder, inject_into_extensions, on_progress,
            ) {
                Ok(name) => CString::new(name)
                    .map(|c| c.into_raw())
                    .unwrap_or(ptr::null_mut()),
                Err(e) => {
                    set_last_error(e);
                    ptr::null_mut()
                }
            }
        })
    }
    #[cfg(not(all(feature = "device-account", feature = "device-pairing")))]
    {
        let _ = (ipa, p12p, profp, password, dylibs, inject_path, inject_folder,
                 inject_into_extensions, on_progress);
        set_last_error("px_install_ipa_p12 : compilé sans --features device-account,device-pairing");
        ptr::null_mut()
    }
}

#[cfg(all(feature = "device-account", feature = "device-pairing"))]
mod imp {
    use super::PxProgressCallback;
    use crate::account::PxSignSession;
    use crate::tunnel::PxTunnel;
    use isideload::dev::devices::DevicesApi;
    use std::ffi::CString;
    use std::path::Path;

    /// Étape franchie, poussée à Swift avec la progression. Les bornes de
    /// pourcentage sont arbitraires mais monotones : une barre qui recule est
    /// pire que pas de barre du tout.
    fn step(cb: PxProgressCallback, percent: u32, label: &str) {
        tracing::info!("[{percent}%] {label}");
        if let Ok(c) = CString::new(label) {
            cb(percent, c.as_ptr());
        }
    }

    /// Zippe le dossier `Payload` en un IPA en mémoire.
    ///
    /// Sans compression, délibérément : le transfert est local, par le tunnel,
    /// et compresser un bundle de plusieurs dizaines de mégaoctets coûterait
    /// plus de temps processeur qu'il n'en ferait gagner en transfert.
    ///
    /// Les permissions Unix sont reportées telles quelles — l'exécutable
    /// principal doit rester exécutable, sinon `installd` refuse le paquet.
    fn zip_payload(payload: &Path) -> Result<Vec<u8>, String> {
        use std::io::{Cursor, Write};
        use zip::write::SimpleFileOptions;

        let root = payload
            .parent()
            .ok_or_else(|| "Payload sans parent".to_string())?;

        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::<u8>::new()));
        let mut stack = vec![payload.to_path_buf()];

        while let Some(dir) = stack.pop() {
            let entries = std::fs::read_dir(&dir)
                .map_err(|e| format!("lecture de {} : {e}", dir.display()))?;

            for entry in entries {
                let entry = entry.map_err(|e| format!("entree illisible : {e}"))?;
                let path = entry.path();
                let name = path
                    .strip_prefix(root)
                    .map_err(|e| format!("chemin hors Payload : {e}"))?
                    .to_string_lossy()
                    .replace('\\', "/");

                let meta = std::fs::symlink_metadata(&path)
                    .map_err(|e| format!("metadonnees de {} : {e}", path.display()))?;

                if meta.is_dir() {
                    writer
                        .add_directory(format!("{name}/"), SimpleFileOptions::default())
                        .map_err(|e| format!("zip dossier {name} : {e}"))?;
                    stack.push(path);
                    continue;
                }

                // Les liens symboliques existent dans certains bundles ; les
                // suivre dupliquerait le contenu et casserait la signature.
                if meta.file_type().is_symlink() {
                    let target = std::fs::read_link(&path)
                        .map_err(|e| format!("lien {} : {e}", path.display()))?;
                    writer
                        .add_symlink(&name, target.to_string_lossy(), SimpleFileOptions::default())
                        .map_err(|e| format!("zip lien {name} : {e}"))?;
                    continue;
                }

                use std::os::unix::fs::PermissionsExt;
                let options = SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored)
                    .unix_permissions(meta.permissions().mode())
                    .large_file(true);

                writer
                    .start_file(&name, options)
                    .map_err(|e| format!("zip fichier {name} : {e}"))?;
                let bytes = std::fs::read(&path)
                    .map_err(|e| format!("lecture de {} : {e}", path.display()))?;
                writer
                    .write_all(&bytes)
                    .map_err(|e| format!("ecriture de {name} : {e}"))?;
            }
        }

        let cursor = writer.finish().map_err(|e| format!("cloture du zip : {e}"))?;
        Ok(cursor.into_inner())
    }

    #[allow(clippy::too_many_arguments)]
    pub unsafe fn install(
        session: *mut PxSignSession,
        tunnel: *mut PxTunnel,
        ipa: &str,
        udid: &str,
        device_name: &str,
        dylibs: &[String],
        inject_path: &str,
        inject_folder: &str,
        inject_into_extensions: bool,
        on_progress: PxProgressCallback,
    ) -> Result<String, String> {
        let sign = crate::account::session_inner(session);
        let tun = crate::tunnel::tunnel_inner(tunnel);

        // ── 1. Enregistrement de l'appareil ───────────────────────────────
        // Avant la signature, jamais après : le profil de provisionnement est
        // émis pour un ensemble d'appareils figé au moment de son émission.
        step(on_progress, 5, "Enregistrement de l'appareil chez Apple");
        sign.runtime.block_on(async {
            let team = sign
                .sideloader
                .get_team()
                .await
                .map_err(|e| format!("equipe : {e}"))?;
            sign.sideloader
                .get_dev_session()
                .ensure_device_registered(&team, device_name, udid, None)
                .await
                .map_err(|e| format!("enregistrement de l appareil (erreur 8220 si absent) : {e}"))
        })?;

        // ── 1.5. Injection de tweaks (si demandé) ─────────────────────────
        // On injecte AVANT de signer : sign_app signera aussi les dylibs
        // ajoutés. Rend un IPA temporaire modifié, qu'on nettoie après.
        let ipa_to_sign = if dylibs.is_empty() {
            ipa.to_string()
        } else {
            step(on_progress, 12, "Injection des tweaks");
            let mut opts = crate::inject::InjectOptions::default();
            if !inject_path.is_empty() {
                opts.path_prefix = inject_path.to_string();
            }
            if !inject_folder.is_empty() {
                opts.folder = inject_folder.to_string();
            }
            opts.into_extensions = inject_into_extensions;
            crate::inject::inject_dylibs(ipa, dylibs, &opts)?
        };

        // ── 2. Signature ──────────────────────────────────────────────────
        step(on_progress, 20, "Signature de l'application");
        let signed = sign.runtime.block_on(async {
            sign.sideloader
                .sign_app(ipa_to_sign.as_str().into(), None, false)
                .await
        });
        if !dylibs.is_empty() {
            let _ = std::fs::remove_file(&ipa_to_sign);
        }
        let (signed_path, special) = signed.map_err(|e| format!("signature : {e}"))?;

        let special_name = special.map(|s| s.to_string()).unwrap_or_default();
        if !special_name.is_empty() {
            tracing::info!("application reconnue : {special_name}");
        }

        // ── 3. Reconstitution de l'IPA ────────────────────────────────────
        //
        // `sign_app` rend un **dossier** `.app`. Et c'est précisément là qu'un
        // piège se cache : `install_package_with_callback_rsd`, pour un
        // dossier, appelle `upgrade_with_callback` et non
        // `install_with_callback` (utils/installation/mod.rs:107). On demande
        // alors à `installd` de *mettre à jour* une app qui n'est pas
        // installée — l'appel rend `Ok`, et rien n'apparaît sur l'écran
        // d'accueil. AltStore, SideStore et isideload utilisent tous `Install`.
        //
        // Le chemin `install_bytes_with_callback_rsd`, lui, appelle bien
        // `install_with_callback`. Il prend des octets d'IPA, d'où ce
        // rezippage du dossier `Payload` produit par la signature.
        step(on_progress, 35, "Préparation du paquet");
        let payload = signed_path
            .parent()
            .ok_or_else(|| "bundle signé sans dossier Payload".to_string())?;
        let ipa = zip_payload(payload)?;
        tracing::info!("IPA reconstitué : {} octets", ipa.len());

        // ── 4. Transfert AFC puis installation ────────────────────────────
        // Sur le runtime du TUNNEL : c'est lui qui fait tourner les tâches de
        // fond de la pile TCP, et l'adaptateur ne se pilote que de là.
        step(on_progress, 40, "Transfert vers l'appareil");

        let result = tun.runtime.block_on(async {
            idevice::utils::installation::install_bytes_with_callback_rsd(
                &mut tun.adapter,
                &mut tun.rsd,
                &ipa,
                // `None` : le helper pose lui-même PackageType = Developer.
                // Le renseigner nous obligerait à dépendre de `plist`, qu'idevice
                // ne réexporte pas.
                None,
                |(percent, cb): (u64, PxProgressCallback)| async move {
                    // 40 → 100 : le transfert et l'installation occupent la
                    // seconde moitié de la barre.
                    let scaled = 40 + (percent.min(100) as u32 * 60 / 100);
                    if let Ok(c) = CString::new("Installation") {
                        cb(scaled, c.as_ptr());
                    }
                },
                on_progress,
            )
            .await
        });

        // Le bundle signé est volumineux et ne resservira pas : on le retire,
        // que l'installation ait abouti ou non.
        let _ = std::fs::remove_dir_all(payload);

        result.map_err(|e| format!("installation : {e}"))?;

        step(on_progress, 100, "Installation terminée");
        Ok(special_name)
    }

    /// Chemin **hors-ligne** : signe avec un p12 importé, sans compte Apple ni
    /// enregistrement d'appareil (le profil fourni déclare déjà ses appareils,
    /// ou est un profil entreprise). Injection → signature p12 → transfert.
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn install_offline(
        tunnel: *mut PxTunnel,
        ipa: &str,
        p12_bytes: &[u8],
        password: &str,
        profile_bytes: &[u8],
        dylibs: &[String],
        inject_path: &str,
        inject_folder: &str,
        inject_into_extensions: bool,
        on_progress: PxProgressCallback,
    ) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);

        // 1. Injection éventuelle des tweaks (avant signature).
        let ipa_to_use = if dylibs.is_empty() {
            ipa.to_string()
        } else {
            step(on_progress, 10, "Injection des tweaks");
            let mut opts = crate::inject::InjectOptions::default();
            if !inject_path.is_empty() {
                opts.path_prefix = inject_path.to_string();
            }
            if !inject_folder.is_empty() {
                opts.folder = inject_folder.to_string();
            }
            opts.into_extensions = inject_into_extensions;
            crate::inject::inject_dylibs(ipa, dylibs, &opts)?
        };

        // 2. Extraction vers un dossier de travail.
        step(on_progress, 25, "Préparation du bundle");
        let work = std::env::temp_dir().join(format!("px-p12-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).map_err(|e| format!("dossier de travail : {e}"))?;
        crate::inject::extract_ipa(Path::new(&ipa_to_use), &work)?;
        if !dylibs.is_empty() {
            let _ = std::fs::remove_file(&ipa_to_use);
        }
        let app = crate::inject::find_app_dir(&work)?;

        // 3. Signature hors-ligne avec le certificat importé.
        step(on_progress, 40, "Signature avec le certificat importé");
        crate::sign_offline::sign_bundle_offline(&app, p12_bytes, password, profile_bytes)?;

        // 4. Reconstitution de l'IPA (même raison qu'au chemin en ligne :
        //    installer un dossier ferait un Upgrade silencieux, pas un Install).
        step(on_progress, 55, "Préparation du paquet");
        let payload = app
            .parent()
            .ok_or_else(|| "bundle signé sans dossier Payload".to_string())?;
        let ipa_bytes = zip_payload(payload)?;

        // 5. Transfert + installation par le tunnel.
        step(on_progress, 60, "Transfert vers l'appareil");
        let result = tun.runtime.block_on(async {
            idevice::utils::installation::install_bytes_with_callback_rsd(
                &mut tun.adapter,
                &mut tun.rsd,
                &ipa_bytes,
                None,
                |(percent, cb): (u64, PxProgressCallback)| async move {
                    let scaled = 60 + (percent.min(100) as u32 * 40 / 100);
                    if let Ok(c) = CString::new("Installation") {
                        cb(scaled, c.as_ptr());
                    }
                },
                on_progress,
            )
            .await
        });

        let _ = std::fs::remove_dir_all(&work);
        result.map_err(|e| format!("installation : {e}"))?;

        step(on_progress, 100, "Installation terminée");
        Ok(String::new())
    }
}
