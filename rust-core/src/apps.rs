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
        let apps = tun.runtime.block_on(async {
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
                .get_apps(Some("User"), None)
                .await
                .map_err(|e| format!("liste des apps : {e}"))
        })?;

        // Sérialisation : on ne garde que ce que la Bibliothèque affiche.
        let mut out: Vec<serde_json::Value> = Vec::with_capacity(apps.len());
        for (bundle_id, value) in apps {
            let dict = value.as_dictionary();
            let field = |key: &str| -> Option<String> {
                dict.and_then(|d| d.get(key))
                    .and_then(|v| v.as_string())
                    .map(|s| s.to_string())
            };
            let name = field("CFBundleDisplayName")
                .or_else(|| field("CFBundleName"))
                .unwrap_or_else(|| bundle_id.clone());
            out.push(serde_json::json!({
                "bundleId": bundle_id,
                "name": name,
                "version": field("CFBundleShortVersionString").unwrap_or_default(),
                "build": field("CFBundleVersion").unwrap_or_default(),
                "type": field("ApplicationType").unwrap_or_default(),
            }));
        }
        // Tri alphabétique, insensible à la casse — une liste d'apps se lit ainsi.
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
