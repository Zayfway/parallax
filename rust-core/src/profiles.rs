//! Profils : gestion des profils de provisionnement, par misagent.
//!
//! `com.apple.misagent` liste et retire les `.mobileprovision` installés — un
//! service RSD de base, sans image développeur. Utile pour un sideloader : un
//! profil expiré ou en trop bloque parfois l'installation, et jusqu'ici il n'y
//! avait aucun moyen de les voir ni d'en retirer un sans ordinateur.
//!
//! `copy_all` rend des blobs bruts (CMS) ; le plist est en clair dedans, entre
//! `<plist>` et `</plist>` — on l'extrait comme pour le profil de signature.

#![cfg(all(feature = "device-account", feature = "device-pairing"))]

use crate::tunnel::PxTunnel;
use crate::*;

/// Liste les profils installés. JSON `[{uuid,name,team,appId,daysRemaining,
/// expires}]`, NULL sinon. À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide.
#[no_mangle]
pub unsafe extern "C" fn px_profiles_list(tunnel: *mut PxTunnel) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_profiles_list : tunnel nul");
        return ptr::null_mut();
    }
    guard("px_profiles_list", ptr::null_mut(), || match imp::list(tunnel) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

/// Retire le profil d'UUID `uuid`. `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; `uuid` UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_profile_remove(tunnel: *mut PxTunnel, uuid: *const c_char) -> c_int {
    clear_last_error();
    let Some(id) = cstr(uuid).filter(|s| !s.is_empty()) else {
        set_last_error("px_profile_remove : UUID nul");
        return PX_ERR_ARG;
    };
    guard("px_profile_remove", PX_ERR_INTERNAL, || match imp::remove(tunnel, &id) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Extrait le plist en clair d'un `.mobileprovision` (CMS).
fn parse_profile(blob: &[u8]) -> Option<serde_json::Value> {
    let start = blob.windows(6).position(|w| w == b"<plist")?;
    let end = blob.windows(8).rposition(|w| w == b"</plist>")? + 8;
    let value = plist::Value::from_reader_xml(&blob[start..end]).ok()?;
    let dict = value.as_dictionary()?;

    let s = |k: &str| dict.get(k).and_then(|v| v.as_string()).map(str::to_string);
    let uuid = s("UUID")?;
    let name = s("Name").unwrap_or_else(|| uuid.clone());
    let team = s("TeamName").unwrap_or_default();

    // application-identifier vit dans Entitlements.
    let app_id = dict
        .get("Entitlements")
        .and_then(|v| v.as_dictionary())
        .and_then(|e| e.get("application-identifier"))
        .and_then(|v| v.as_string())
        .map(str::to_string)
        .unwrap_or_default();

    let (days, expires) = match dict.get("ExpirationDate").and_then(|v| v.as_date()) {
        Some(date) => {
            let expires = date.to_xml_format();
            let exp: std::time::SystemTime = date.into();
            let now = std::time::SystemTime::now();
            let days = match exp.duration_since(now) {
                Ok(d) => (d.as_secs() / 86_400) as i64,
                Err(e) => -((e.duration().as_secs() / 86_400) as i64),
            };
            (days, expires)
        }
        None => (0, String::new()),
    };

    Some(serde_json::json!({
        "uuid": uuid,
        "name": name,
        "team": team,
        "appId": app_id,
        "daysRemaining": days,
        "expires": expires,
    }))
}

mod imp {
    use super::*;
    use idevice::provider::RsdProvider;
    use idevice::services::misagent::MisagentClient;
    use idevice::RsdService;

    async fn connect(
        rsd: &mut idevice::rsd::RsdHandshake,
        adapter: &mut idevice::tcp::handle::AdapterHandle,
    ) -> Result<MisagentClient, String> {
        let name = <MisagentClient as RsdService>::rsd_service_name().to_string();
        let port = rsd
            .services
            .get(&name)
            .map(|s| s.port)
            .ok_or_else(|| format!("service {name} absent de RSD — tunnel établi ?"))?;
        let stream = adapter
            .connect_to_service_port(port)
            .await
            .map_err(|e| format!("connexion à misagent : {e}"))?;
        <MisagentClient as RsdService>::from_stream(stream)
            .await
            .map_err(|e| format!("canal misagent : {e}"))
    }

    pub unsafe fn list(tunnel: *mut PxTunnel) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let blobs = tun.runtime.block_on(async {
            let mut client = connect(&mut tun.rsd, &mut tun.adapter).await?;
            client
                .copy_all()
                .await
                .map_err(|e| format!("lecture des profils : {e}"))
        })?;

        let mut out: Vec<serde_json::Value> =
            blobs.iter().filter_map(|b| super::parse_profile(b)).collect();
        out.sort_by(|a, b| {
            a["name"]
                .as_str()
                .unwrap_or("")
                .to_lowercase()
                .cmp(&b["name"].as_str().unwrap_or("").to_lowercase())
        });
        serde_json::to_string(&out).map_err(|e| format!("JSON : {e}"))
    }

    pub unsafe fn remove(tunnel: *mut PxTunnel, uuid: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let mut client = connect(&mut tun.rsd, &mut tun.adapter).await?;
            client
                .remove(uuid)
                .await
                .map_err(|e| format!("retrait du profil : {e}"))
        })
    }
}
