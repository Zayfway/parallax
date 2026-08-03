//! Bibliothèque : gestion des apps installées, par le tunnel.
//!
//! `installation_proxy` est un service RSD de base (présent sans image
//! développeur, contrairement à Instruments). On s'y connecte comme le fait
//! `location.rs` — port résolu dans `rsd.services`, flux ouvert par l'adaptateur,
//! puis `from_stream` — plutôt que le `connect::<T>()` générique qui bute sur
//! « RsdService is not general enough ».
//!
//! Deux gestes ponctuels, pas de session persistante : on ouvre, on interroge
//! (ou on désinstalle), on referme. On réutilise le runtime du tunnel.

#![cfg(all(feature = "device-account", feature = "device-pairing"))]

use crate::tunnel::PxTunnel;
use crate::*;

/// Liste les apps **utilisateur** installées. Rend un JSON
/// `[{"bundleId","name","version","build","type"}]`, NULL en cas d'échec.
/// À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` issu de `px_tunnel_connect`, encore vivant.
#[no_mangle]
pub unsafe extern "C" fn px_apps_list(tunnel: *mut PxTunnel) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_apps_list : tunnel nul");
        return ptr::null_mut();
    }
    guard("px_apps_list", ptr::null_mut(), || match imp::list(tunnel) {
        Ok(json) => CString::new(json)
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

/// Désinstalle l'app d'identifiant `bundle_id`. `PX_OK`, ou un code d'erreur.
///
/// # Safety
/// `tunnel` valide ; `bundle_id` UTF-8 terminé par NUL.
#[no_mangle]
pub unsafe extern "C" fn px_app_uninstall(
    tunnel: *mut PxTunnel,
    bundle_id: *const c_char,
) -> c_int {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_app_uninstall : tunnel nul");
        return PX_ERR_ARG;
    }
    let Some(bid) = cstr(bundle_id) else {
        set_last_error("px_app_uninstall : identifiant nul");
        return PX_ERR_ARG;
    };
    if bid.is_empty() {
        set_last_error("px_app_uninstall : identifiant vide");
        return PX_ERR_ARG;
    }
    guard("px_app_uninstall", PX_ERR_INTERNAL, || match imp::uninstall(tunnel, &bid) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

mod imp {
    use super::*;
    use idevice::provider::RsdProvider;
    use idevice::services::installation_proxy::InstallationProxyClient;
    use idevice::RsdService;

    /// Nom du service RSD d'installation_proxy.
    fn service_name() -> String {
        <InstallationProxyClient as RsdService>::rsd_service_name().to_string()
    }

    pub unsafe fn list(tunnel: *mut PxTunnel) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        // `browse` avec ReturnAttributes plutôt que `get_apps` : on demande
        // explicitement l'usage disque et l'identité du signataire, qui ne sont
        // pas garantis dans un Lookup par défaut.
        let list = tun.runtime.block_on(async {
            let name = service_name();
            let port = tun
                .rsd
                .services
                .get(&name)
                .map(|s| s.port)
                .ok_or_else(|| format!("service {name} absent de RSD — tunnel établi ?"))?;
            let stream = tun
                .adapter
                .connect_to_service_port(port)
                .await
                .map_err(|e| format!("connexion à installation_proxy : {e}"))?;
            let mut client = InstallationProxyClient::from_stream(stream)
                .await
                .map_err(|e| format!("canal installation_proxy : {e}"))?;

            let attrs = [
                "CFBundleIdentifier",
                "CFBundleDisplayName",
                "CFBundleName",
                "CFBundleShortVersionString",
                "CFBundleVersion",
                "ApplicationType",
                "SignerIdentity",
                "StaticDiskUsage",
                "DynamicDiskUsage",
            ];
            let mut opts = plist::Dictionary::new();
            opts.insert("ApplicationType".into(), plist::Value::String("User".into()));
            opts.insert(
                "ReturnAttributes".into(),
                plist::Value::Array(
                    attrs.iter().map(|s| plist::Value::String(s.to_string())).collect(),
                ),
            );
            client
                .browse(Some(plist::Value::Dictionary(opts)))
                .await
                .map_err(|e| format!("liste des apps : {e}"))
        })?;

        let mut out: Vec<serde_json::Value> = Vec::with_capacity(list.len());
        for value in &list {
            let dict = match value.as_dictionary() {
                Some(d) => d,
                None => continue,
            };
            let text = |key: &str| -> Option<String> {
                dict.get(key).and_then(|v| v.as_string()).map(|s| s.to_string())
            };
            let uint = |key: &str| -> u64 {
                dict.get(key)
                    .and_then(|v| v.as_unsigned_integer().or_else(|| v.as_signed_integer().map(|i| i.max(0) as u64)))
                    .unwrap_or(0)
            };

            let bundle_id = match text("CFBundleIdentifier") {
                Some(b) if !b.is_empty() => b,
                _ => continue,
            };
            let name = text("CFBundleDisplayName")
                .filter(|s| !s.is_empty())
                .or_else(|| text("CFBundleName"))
                .unwrap_or_else(|| bundle_id.clone());

            // App Store ⟺ signataire « Apple iPhone OS Application Signing ».
            // Le reste des apps utilisateur est sideloadé (dev, entreprise, IPA).
            let signer = text("SignerIdentity").unwrap_or_default();
            let app_type = text("ApplicationType").unwrap_or_default();
            let source = if app_type == "System" {
                "system"
            } else if signer.contains("Apple iPhone OS Application Signing") {
                "store"
            } else {
                "sideloaded"
            };

            let size = uint("StaticDiskUsage") + uint("DynamicDiskUsage");

            out.push(serde_json::json!({
                "bundleId": bundle_id,
                "name": name,
                "version": text("CFBundleShortVersionString").unwrap_or_default(),
                "build": text("CFBundleVersion").unwrap_or_default(),
                "source": source,
                "sizeBytes": size,
            }));
        }
        out.sort_by(|a, b| {
            a["name"]
                .as_str()
                .unwrap_or("")
                .to_lowercase()
                .cmp(&b["name"].as_str().unwrap_or("").to_lowercase())
        });
        serde_json::to_string(&out).map_err(|e| format!("sérialisation JSON : {e}"))
    }

    pub unsafe fn uninstall(tunnel: *mut PxTunnel, bundle_id: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let name = service_name();
            let port = tun
                .rsd
                .services
                .get(&name)
                .map(|s| s.port)
                .ok_or_else(|| format!("service {name} absent de RSD — tunnel établi ?"))?;
            let stream = tun
                .adapter
                .connect_to_service_port(port)
                .await
                .map_err(|e| format!("connexion à installation_proxy : {e}"))?;
            let mut client = InstallationProxyClient::from_stream(stream)
                .await
                .map_err(|e| format!("canal installation_proxy : {e}"))?;
            client
                .uninstall(bundle_id, None)
                .await
                .map_err(|e| format!("désinstallation de {bundle_id} : {e}"))
        })
    }
}
