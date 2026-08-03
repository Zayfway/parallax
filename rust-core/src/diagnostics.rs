//! Diagnostic appareil : batterie et infos système, par diagnostics_relay.
//!
//! `com.apple.mobile.diagnostics_relay` rend la jauge de batterie (GasGauge) et
//! les clés MobileGestalt (modèle, version iOS, nom…). Service RSD de base, sans
//! image développeur. Les réponses arrivent enveloppées dans un dictionnaire
//! `Diagnostics` (parfois lui-même sous « GasGauge » / « MobileGestalt ») — on
//! cherche donc chaque clé à plat puis un niveau plus bas.

#![cfg(all(feature = "device-account", feature = "device-pairing"))]

use crate::tunnel::PxTunnel;
use crate::*;

/// Infos appareil : JSON `{battery,model,iosVersion,build,name}`. NULL sinon.
/// À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide.
#[no_mangle]
pub unsafe extern "C" fn px_device_info(tunnel: *mut PxTunnel) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_device_info : tunnel nul");
        return ptr::null_mut();
    }
    guard("px_device_info", ptr::null_mut(), || match imp::info(tunnel) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

mod imp {
    use super::*;
    use idevice::provider::RsdProvider;
    use idevice::services::diagnostics_relay::DiagnosticsRelayClient;
    use idevice::RsdService;

    /// Cherche une clé à plat, puis un niveau sous les dictionnaires enfants.
    fn find<'a>(dict: &'a plist::Dictionary, key: &str) -> Option<&'a plist::Value> {
        if let Some(v) = dict.get(key) {
            return Some(v);
        }
        for (_, v) in dict {
            if let Some(sub) = v.as_dictionary() {
                if let Some(found) = sub.get(key) {
                    return Some(found);
                }
            }
        }
        None
    }

    fn text(dict: &plist::Dictionary, key: &str) -> String {
        find(dict, key).and_then(|v| v.as_string()).map(str::to_string).unwrap_or_default()
    }

    fn int(dict: &plist::Dictionary, key: &str) -> i64 {
        find(dict, key)
            .and_then(|v| v.as_signed_integer().or_else(|| v.as_unsigned_integer().map(|u| u as i64)))
            .unwrap_or(-1)
    }

    pub unsafe fn info(tunnel: *mut PxTunnel) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let name = <DiagnosticsRelayClient as RsdService>::rsd_service_name().to_string();
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
                .map_err(|e| format!("connexion à diagnostics_relay : {e}"))?;
            let mut client = <DiagnosticsRelayClient as RsdService>::from_stream(stream)
                .await
                .map_err(|e| format!("canal diagnostics_relay : {e}"))?;

            let gauge = client.gasguage().await.ok().flatten().unwrap_or_default();
            let keys = vec![
                "ProductType".to_string(),
                "ProductVersion".to_string(),
                "BuildVersion".to_string(),
                "DeviceName".to_string(),
            ];
            let gestalt = client.mobilegestalt(Some(keys)).await.ok().flatten().unwrap_or_default();

            Ok::<_, String>(
                serde_json::json!({
                    "battery": int(&gauge, "CurrentCapacity"),
                    "model": text(&gestalt, "ProductType"),
                    "iosVersion": text(&gestalt, "ProductVersion"),
                    "build": text(&gestalt, "BuildVersion"),
                    "name": text(&gestalt, "DeviceName"),
                })
                .to_string(),
            )
        })
    }
}
