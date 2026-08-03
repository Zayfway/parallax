//! Fichiers : explorateur de l'espace **Média** de l'appareil, par AFC.
//!
//! `com.apple.afc` donne accès à `/var/mobile/Media` (photos DCIM, fichiers,
//! téléchargements…) — pas au système complet ni aux conteneurs d'apps (ça, ce
//! serait house_arrest, par identifiant). C'est un service RSD de base, sans
//! image développeur. On s'y connecte comme ailleurs : port résolu dans
//! `rsd.services`, flux ouvert par l'adaptateur, `from_stream`.

#![cfg(all(feature = "device-account", feature = "device-pairing"))]

use crate::tunnel::PxTunnel;
use crate::*;

/// Liste un dossier. Rend un JSON `[{name,path,isDir,size,kind}]`, NULL sinon.
/// À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide ; `path` UTF-8 terminé par NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_list(tunnel: *mut PxTunnel, path: *const c_char) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_fs_list : tunnel nul");
        return ptr::null_mut();
    }
    let dir = cstr(path).filter(|p| !p.is_empty()).unwrap_or_else(|| "/".to_string());
    guard("px_fs_list", ptr::null_mut(), || match imp::list(tunnel, &dir) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

/// Télécharge `remote` vers le chemin local `dest`. `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_download(
    tunnel: *mut PxTunnel,
    remote: *const c_char,
    dest: *const c_char,
) -> c_int {
    clear_last_error();
    let (Some(r), Some(d)) = (cstr(remote), cstr(dest)) else {
        set_last_error("px_fs_download : chemin nul");
        return PX_ERR_ARG;
    };
    guard("px_fs_download", PX_ERR_INTERNAL, || match imp::download(tunnel, &r, &d) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Envoie le fichier local `local` vers `remote`. `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_upload(
    tunnel: *mut PxTunnel,
    local: *const c_char,
    remote: *const c_char,
) -> c_int {
    clear_last_error();
    let (Some(l), Some(r)) = (cstr(local), cstr(remote)) else {
        set_last_error("px_fs_upload : chemin nul");
        return PX_ERR_ARG;
    };
    guard("px_fs_upload", PX_ERR_INTERNAL, || match imp::upload(tunnel, &l, &r) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Supprime `path` (récursivement pour un dossier). `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; `path` UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_delete(tunnel: *mut PxTunnel, path: *const c_char) -> c_int {
    clear_last_error();
    let Some(p) = cstr(path).filter(|p| !p.is_empty()) else {
        set_last_error("px_fs_delete : chemin nul");
        return PX_ERR_ARG;
    };
    guard("px_fs_delete", PX_ERR_INTERNAL, || match imp::delete(tunnel, &p) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Crée le dossier `path`. `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; `path` UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_mkdir(tunnel: *mut PxTunnel, path: *const c_char) -> c_int {
    clear_last_error();
    let Some(p) = cstr(path).filter(|p| !p.is_empty()) else {
        set_last_error("px_fs_mkdir : chemin nul");
        return PX_ERR_ARG;
    };
    guard("px_fs_mkdir", PX_ERR_INTERNAL, || match imp::mkdir(tunnel, &p) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Renomme (ou déplace) `from` vers `to`. `PX_OK` ou code d'erreur.
///
/// # Safety
/// `tunnel` valide ; chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_fs_rename(
    tunnel: *mut PxTunnel,
    from: *const c_char,
    to: *const c_char,
) -> c_int {
    clear_last_error();
    let (Some(f), Some(t)) = (
        cstr(from).filter(|p| !p.is_empty()),
        cstr(to).filter(|p| !p.is_empty()),
    ) else {
        set_last_error("px_fs_rename : chemin nul");
        return PX_ERR_ARG;
    };
    guard("px_fs_rename", PX_ERR_INTERNAL, || match imp::rename(tunnel, &f, &t) {
        Ok(()) => PX_OK,
        Err(e) => {
            set_last_error(e);
            PX_ERR_INTERNAL
        }
    })
}

/// Infos de stockage de l'espace Média : JSON `{model,totalBytes,freeBytes}`.
///
/// # Safety
/// `tunnel` valide.
#[no_mangle]
pub unsafe extern "C" fn px_fs_storage(tunnel: *mut PxTunnel) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_fs_storage : tunnel nul");
        return ptr::null_mut();
    }
    guard("px_fs_storage", ptr::null_mut(), || match imp::storage(tunnel) {
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
    use idevice::rsd::RsdHandshake;
    use idevice::services::afc::opcode::AfcFopenMode;
    use idevice::services::afc::AfcClient;
    use idevice::tcp::handle::AdapterHandle;
    use idevice::RsdService;

    async fn connect_afc(
        rsd: &mut RsdHandshake,
        adapter: &mut AdapterHandle,
    ) -> Result<AfcClient, String> {
        let name = <AfcClient as RsdService>::rsd_service_name().to_string();
        let port = rsd
            .services
            .get(&name)
            .map(|s| s.port)
            .ok_or_else(|| format!("service {name} absent de RSD — tunnel établi ?"))?;
        let stream = adapter
            .connect_to_service_port(port)
            .await
            .map_err(|e| format!("connexion à AFC : {e}"))?;
        <AfcClient as RsdService>::from_stream(stream)
            .await
            .map_err(|e| format!("canal AFC : {e}"))
    }

    fn join(base: &str, name: &str) -> String {
        if base.ends_with('/') {
            format!("{base}{name}")
        } else {
            format!("{base}/{name}")
        }
    }

    pub unsafe fn list(tunnel: *mut PxTunnel, dir: &str) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let entries = tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            let names = afc
                .list_dir(dir)
                .await
                .map_err(|e| format!("lecture de {dir} : {e}"))?;

            let mut out: Vec<serde_json::Value> = Vec::with_capacity(names.len());
            for name in names {
                if name == "." || name == ".." {
                    continue;
                }
                let full = join(dir, &name);
                let (is_dir, size, kind) = match afc.get_file_info(full.as_str()).await {
                    Ok(info) => (info.st_ifmt == "S_IFDIR", info.size as u64, info.st_ifmt),
                    Err(_) => (false, 0u64, String::new()),
                };
                out.push(serde_json::json!({
                    "name": name,
                    "path": full,
                    "isDir": is_dir,
                    "size": size,
                    "kind": kind,
                }));
            }
            Ok::<_, String>(out)
        })?;

        // Dossiers d'abord, puis tri alphabétique.
        let mut entries = entries;
        entries.sort_by(|a, b| {
            let ad = a["isDir"].as_bool().unwrap_or(false);
            let bd = b["isDir"].as_bool().unwrap_or(false);
            bd.cmp(&ad).then_with(|| {
                a["name"]
                    .as_str()
                    .unwrap_or("")
                    .to_lowercase()
                    .cmp(&b["name"].as_str().unwrap_or("").to_lowercase())
            })
        });
        serde_json::to_string(&entries).map_err(|e| format!("JSON : {e}"))
    }

    pub unsafe fn download(tunnel: *mut PxTunnel, remote: &str, dest: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let data = tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            let mut fd = afc
                .open(remote, AfcFopenMode::RdOnly)
                .await
                .map_err(|e| format!("ouverture de {remote} : {e}"))?;
            let bytes = fd
                .read_entire()
                .await
                .map_err(|e| format!("lecture de {remote} : {e}"))?;
            let _ = fd.close().await;
            Ok::<_, String>(bytes)
        })?;
        std::fs::write(dest, &data).map_err(|e| format!("écriture locale : {e}"))
    }

    pub unsafe fn upload(tunnel: *mut PxTunnel, local: &str, remote: &str) -> Result<(), String> {
        let bytes = std::fs::read(local).map_err(|e| format!("lecture locale : {e}"))?;
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            let mut fd = afc
                .open(remote, AfcFopenMode::WrOnly)
                .await
                .map_err(|e| format!("création de {remote} : {e}"))?;
            fd.write_entire(&bytes)
                .await
                .map_err(|e| format!("écriture de {remote} : {e}"))?;
            fd.close().await.map_err(|e| format!("fermeture : {e}"))
        })
    }

    pub unsafe fn delete(tunnel: *mut PxTunnel, path: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            afc.remove_all(path)
                .await
                .map_err(|e| format!("suppression de {path} : {e}"))
        })
    }

    pub unsafe fn mkdir(tunnel: *mut PxTunnel, path: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            afc.mk_dir(path)
                .await
                .map_err(|e| format!("création de {path} : {e}"))
        })
    }

    pub unsafe fn rename(tunnel: *mut PxTunnel, from: &str, to: &str) -> Result<(), String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            afc.rename(from, to)
                .await
                .map_err(|e| format!("renommage de {from} : {e}"))
        })
    }

    pub unsafe fn storage(tunnel: *mut PxTunnel) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let info = tun.runtime.block_on(async {
            let mut afc = connect_afc(&mut tun.rsd, &mut tun.adapter).await?;
            afc.get_device_info()
                .await
                .map_err(|e| format!("infos stockage : {e}"))
        })?;
        Ok(serde_json::json!({
            "model": info.model,
            "totalBytes": info.total_bytes as u64,
            "freeBytes": info.free_bytes as u64,
        })
        .to_string())
    }
}
