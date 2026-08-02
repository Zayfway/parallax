//! Signature **hors-ligne** d'un bundle `.app` avec un certificat importé.
//!
//! Pour qui a **acheté** un certificat (un `.p12` + un `.mobileprovision`) et
//! veut signer sans compte Apple. On réutilise le moteur `apple_codesign` (le
//! fork qu'isideload tire déjà, donc éprouvé sur la cible iOS) : il calcule le
//! CodeDirectory, scelle les ressources (`CodeResources`) et pose la signature
//! CMS avec la clé du p12.
//!
//! La recette suit exactement celle d'isideload (`sideload/sign.rs`), à une
//! différence près : la clé et le certificat viennent d'un p12 fourni par
//! l'utilisateur, pas d'une session développeur Apple.

#![cfg(feature = "device-account")]

use apple_codesign::cryptography::parse_pfx_data;
use apple_codesign::{SettingsScope, SigningSettings, UnifiedSigner};
use std::path::{Path, PathBuf};

/// Signe le bundle `.app` sur place, avec le `.p12` (protégé par `password`) et
/// le profil de provisionnement. Embarque le profil, en extrait les
/// entitlements, puis signe les bundles imbriqués avant l'app.
pub fn sign_bundle_offline(
    app_dir: &Path,
    p12_bytes: &[u8],
    password: &str,
    profile_bytes: &[u8],
) -> Result<(), String> {
    // 1. Clé privée + certificat depuis le p12.
    let (cert, key) = parse_pfx_data(p12_bytes, password)
        .map_err(|e| format!("p12 illisible (mot de passe incorrect ?) : {e:?}"))?;

    // 2. Profil : on l'embarque dans le bundle et on en tire les entitlements.
    let entitlements = entitlements_xml(profile_bytes)?;
    embed_profile(app_dir, profile_bytes)?;

    // 3. Réglages de signature. `shallow` : chaque bundle est signé
    //    individuellement (on gère nous-mêmes l'ordre imbriqué → parent).
    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, cert);
    settings.chain_apple_certificates();
    settings.set_shallow(true);
    settings.set_for_notarization(false);
    settings
        .set_entitlements_xml(SettingsScope::Main, entitlements)
        .map_err(|e| format!("entitlements : {e:?}"))?;

    let signer = UnifiedSigner::new(settings);

    // 4. Imbriqués d'abord (frameworks, dylibs, extensions), puis l'app — un
    //    parent signé avant ses enfants scellerait des hachages périmés.
    for nested in nested_signables(app_dir) {
        signer
            .sign_path_in_place(&nested)
            .map_err(|e| format!("signature de {} : {e:?}", nested.display()))?;
    }
    signer
        .sign_path_in_place(app_dir)
        .map_err(|e| format!("signature de l'app : {e:?}"))?;

    Ok(())
}

/// Extrait les entitlements du profil, au format XML plist prêt pour la
/// signature. Le `.mobileprovision` est un CMS ; le plist y est en clair, entre
/// `<plist` et `</plist>` — même repérage qu'isideload.
fn entitlements_xml(profile: &[u8]) -> Result<String, String> {
    let start = profile
        .windows(6)
        .position(|w| w == b"<plist")
        .ok_or_else(|| "profil : bloc plist introuvable".to_string())?;
    let end = profile
        .windows(8)
        .rposition(|w| w == b"</plist>")
        .ok_or_else(|| "profil : fin du plist introuvable".to_string())?
        + 8;

    let value = plist::Value::from_reader_xml(&profile[start..end])
        .map_err(|e| format!("profil illisible : {e}"))?;
    let entitlements = value
        .as_dictionary()
        .and_then(|d| d.get("Entitlements"))
        .ok_or_else(|| "profil sans section Entitlements".to_string())?;

    let mut buf = Vec::new();
    plist::to_writer_xml(&mut buf, entitlements)
        .map_err(|e| format!("sérialisation des entitlements : {e}"))?;
    String::from_utf8(buf).map_err(|e| format!("entitlements non-UTF-8 : {e}"))
}

/// Copie le profil en `embedded.mobileprovision` dans l'app et dans chaque
/// extension — sans lui, installd rejette le paquet signé hors-ligne.
fn embed_profile(app: &Path, profile: &[u8]) -> Result<(), String> {
    std::fs::write(app.join("embedded.mobileprovision"), profile)
        .map_err(|e| format!("écriture du profil : {e}"))?;

    if let Ok(entries) = std::fs::read_dir(app.join("PlugIns")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "appex").unwrap_or(false) {
                let _ = std::fs::write(path.join("embedded.mobileprovision"), profile);
            }
        }
    }
    Ok(())
}

/// Bundles et Mach-O imbriqués à signer avant l'app : dylibs et frameworks de
/// `Frameworks/`, extensions de `PlugIns/`.
fn nested_signables(app: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for sub in ["Frameworks", "PlugIns"] {
        if let Ok(entries) = std::fs::read_dir(app.join(sub)) {
            for entry in entries.flatten() {
                let path = entry.path();
                let ext = path
                    .extension()
                    .map(|e| e.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                if ext == "dylib" || ext == "framework" || ext == "appex" {
                    out.push(path);
                }
            }
        }
    }
    out
}
