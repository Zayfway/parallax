//! Sauvegardes : archiver et restaurer les **données** d'une app sideloadée.
//!
//! Une signature gratuite expire en 7 jours ; à la réinstallation, iOS efface
//! le conteneur. On perd sa progression, ses réglages, ses fichiers. Ce module
//! copie le conteneur d'une app dans un `.zip` local (à garder, à partager),
//! puis le réinjecte après réinstallation.
//!
//! `house_arrest.vend_container(bundle_id)` rend un **`AfcClient`** enraciné sur
//! le conteneur de l'app — le même client que l'explorateur Fichiers, aux mêmes
//! opérations éprouvées. Rien de neuf côté transport, juste une racine
//! différente. Marche pour les apps qui l'autorisent (dev / get-task-allow),
//! pas pour l'App Store.

#![cfg(all(feature = "device-account", feature = "device-pairing"))]

use crate::tunnel::PxTunnel;
use crate::*;

/// Sauvegarde le conteneur de `bundle_id` dans le `.zip` local `dest`. Rend un
/// JSON `{files,bytes}`, NULL sinon. À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide ; chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_backup_create(
    tunnel: *mut PxTunnel,
    bundle_id: *const c_char,
    dest: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let (Some(bid), Some(d)) = (
        cstr(bundle_id).filter(|s| !s.is_empty()),
        cstr(dest).filter(|s| !s.is_empty()),
    ) else {
        set_last_error("px_backup_create : argument nul");
        return ptr::null_mut();
    };
    guard("px_backup_create", ptr::null_mut(), || match imp::create(tunnel, &bid, &d) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

/// Restaure le `.zip` local `src` dans le conteneur de `bundle_id`. Rend un JSON
/// `{files}`, NULL sinon. À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide ; chaînes UTF-8 NUL.
#[no_mangle]
pub unsafe extern "C" fn px_backup_restore(
    tunnel: *mut PxTunnel,
    bundle_id: *const c_char,
    src: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let (Some(bid), Some(s)) = (
        cstr(bundle_id).filter(|s| !s.is_empty()),
        cstr(src).filter(|s| !s.is_empty()),
    ) else {
        set_last_error("px_backup_restore : argument nul");
        return ptr::null_mut();
    };
    guard("px_backup_restore", ptr::null_mut(), || match imp::restore(tunnel, &bid, &s) {
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
    use idevice::services::house_arrest::HouseArrestClient;
    use idevice::tcp::handle::AdapterHandle;
    use idevice::RsdService;
    use std::io::{Read, Write};

    /// Ouvre house_arrest (service RSD, même patron que partout) puis fait vendre
    /// le conteneur de l'app — on récupère un `AfcClient` enraciné dessus.
    async fn vend_container(
        rsd: &mut RsdHandshake,
        adapter: &mut AdapterHandle,
        bundle_id: &str,
    ) -> Result<AfcClient, String> {
        let name = <HouseArrestClient as RsdService>::rsd_service_name().to_string();
        let port = rsd
            .services
            .get(&name)
            .map(|s| s.port)
            .ok_or_else(|| format!("service {name} absent de RSD — tunnel établi ?"))?;
        let stream = adapter
            .connect_to_service_port(port)
            .await
            .map_err(|e| format!("connexion à house_arrest : {e}"))?;
        let ha = <HouseArrestClient as RsdService>::from_stream(stream)
            .await
            .map_err(|e| format!("canal house_arrest : {e}"))?;
        ha.vend_container(bundle_id)
            .await
            .map_err(|e| format!("conteneur de {bundle_id} inaccessible : {e}"))
    }

    fn join(base: &str, name: &str) -> String {
        if base.ends_with('/') {
            format!("{base}{name}")
        } else {
            format!("{base}/{name}")
        }
    }

    pub unsafe fn create(tunnel: *mut PxTunnel, bundle_id: &str, dest: &str) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let (files, bytes) = tun.runtime.block_on(async {
            let mut afc = vend_container(&mut tun.rsd, &mut tun.adapter, bundle_id).await?;

            let file = std::fs::File::create(dest).map_err(|e| format!("création du zip : {e}"))?;
            let mut zip = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);

            // Parcours itératif (pas de récursion async) : une pile de dossiers.
            let mut stack = vec!["/".to_string()];
            let mut count: u64 = 0;
            let mut total: u64 = 0;
            while let Some(dir) = stack.pop() {
                let names = match afc.list_dir(dir.as_str()).await {
                    Ok(n) => n,
                    Err(_) => continue, // dossier illisible : on saute, on ne casse pas tout
                };
                for name in names {
                    if name == "." || name == ".." {
                        continue;
                    }
                    let full = join(&dir, &name);
                    let info = match afc.get_file_info(full.as_str()).await {
                        Ok(i) => i,
                        Err(_) => continue,
                    };
                    let rel = full.trim_start_matches('/');
                    if info.st_ifmt == "S_IFDIR" {
                        let _ = zip.add_directory(format!("{rel}/"), opts);
                        stack.push(full);
                    } else {
                        let mut fd = match afc.open(full.as_str(), AfcFopenMode::RdOnly).await {
                            Ok(f) => f,
                            Err(_) => continue,
                        };
                        let data = match fd.read_entire().await {
                            Ok(d) => d,
                            Err(_) => {
                                let _ = fd.close().await;
                                continue;
                            }
                        };
                        let _ = fd.close().await;
                        zip.start_file(rel, opts).map_err(|e| format!("zip {rel} : {e}"))?;
                        zip.write_all(&data).map_err(|e| format!("écriture zip : {e}"))?;
                        count += 1;
                        total += data.len() as u64;
                    }
                }
            }
            zip.finish().map_err(|e| format!("finalisation du zip : {e}"))?;
            Ok::<_, String>((count, total))
        })?;

        Ok(serde_json::json!({ "files": files, "bytes": bytes }).to_string())
    }

    pub unsafe fn restore(tunnel: *mut PxTunnel, bundle_id: &str, src: &str) -> Result<String, String> {
        let tun = crate::tunnel::tunnel_inner(tunnel);
        let count = tun.runtime.block_on(async {
            let mut afc = vend_container(&mut tun.rsd, &mut tun.adapter, bundle_id).await?;

            let file = std::fs::File::open(src).map_err(|e| format!("ouverture du zip : {e}"))?;
            let mut archive =
                zip::ZipArchive::new(file).map_err(|e| format!("archive illisible : {e}"))?;

            let mut count: u64 = 0;
            for i in 0..archive.len() {
                // On extrait tout de l'entrée avant les appels AFC, pour ne pas
                // tenir le prêt de `archive` à travers un `await`.
                let (name, is_dir, buf) = {
                    let mut entry = archive
                        .by_index(i)
                        .map_err(|e| format!("entrée {i} : {e}"))?;
                    let name = entry.name().to_string();
                    let is_dir = entry.is_dir();
                    let buf = if is_dir {
                        Vec::new()
                    } else {
                        let mut b = Vec::with_capacity(entry.size() as usize);
                        entry.read_to_end(&mut b).map_err(|e| format!("lecture zip : {e}"))?;
                        b
                    };
                    (name, is_dir, buf)
                };

                let dest = format!("/{}", name.trim_end_matches('/'));
                if dest == "/" {
                    continue;
                }
                if is_dir {
                    let _ = afc.mk_dir(dest.as_str()).await;
                } else {
                    // S'assure que le dossier parent existe.
                    if let Some((parent, _)) = dest.rsplit_once('/') {
                        if !parent.is_empty() {
                            let _ = afc.mk_dir(parent).await;
                        }
                    }
                    let mut fd = afc
                        .open(dest.as_str(), AfcFopenMode::WrOnly)
                        .await
                        .map_err(|e| format!("écriture de {dest} : {e}"))?;
                    fd.write_entire(&buf)
                        .await
                        .map_err(|e| format!("transfert de {dest} : {e}"))?;
                    fd.close().await.map_err(|e| format!("fermeture : {e}"))?;
                    count += 1;
                }
            }
            Ok::<_, String>(count)
        })?;

        Ok(serde_json::json!({ "files": count }).to_string())
    }
}
