//! Tunnel RPPairing → RSD.
//!
//! La pièce qui manquait : le jumelage écrivait un fichier que rien ne
//! consommait. Ce module le relit, monte le tunnel TLS-PSK, et rend un
//! `AdapterHandle` plus un `RsdHandshake` — les deux poignées dont dépendent
//! l'installation *et* le GPS.
//!
//! ── CE QUI SE PASSE, DANS L'ORDRE ─────────────────────────────────────────
//!
//!   TCP vers le service `_remotepairing._tcp` de l'appareil
//!     → `RemotePairingClient::connect` (pair-verify sur le fichier existant)
//!     → `create_tcp_listener` : l'appareil ouvre un port pour le tunnel
//!     → `connect_tls_psk_tunnel_native` : TLS-PSK + poignée de main CDTunnel
//!     → pile TCP logicielle par-dessus les paquets IPv6 du tunnel
//!     → `RsdHandshake` sur le port RSD annoncé par le tunnel
//!
//! Cette séquence est calquée sur `ffi/src/tunnel_provider.rs` d'idevice à la
//! révision épinglée — c'est la même que `tunnel_create_rppairing`. Ne pas la
//! réinventer : chaque étape dépend d'un état laissé par la précédente.
//!
//! ── UN SEUL RUNTIME ───────────────────────────────────────────────────────
//!
//! `to_async_handle()` lance des tâches de fond qui pilotent la pile TCP. Elles
//! doivent tourner tant que le tunnel vit, donc le runtime est **détenu par la
//! session** et non recréé à chaque appel. Corollaire : tout ce qui parle à
//! l'appareil doit s'exécuter sur *ce* runtime-là. Deux runtimes sur le même
//! adaptateur, c'est la pile TCP pilotée depuis deux endroits.
//!
//! ── OÙ EST BONJOUR ────────────────────────────────────────────────────────
//!
//! Nulle part ici, et c'est délibéré. Swift découvre l'adresse et le port du
//! service par `NetService`, et nous les passe. Une bibliothèque mDNS pure
//! publie et résout sur toutes les interfaces — un iPhone en a cinq, dont le
//! tunnel VPN — et on retombe sur l'entrée grise avec un rouet.

use crate::*;
use std::ffi::c_void;

/// Tunnel vivant. Opaque côté Swift.
pub struct PxTunnel {
    #[cfg(feature = "device-pairing")]
    inner: imp::Tunnel,
    #[cfg(not(feature = "device-pairing"))]
    _private: (),
}

/// Monte le tunnel et effectue la poignée de main RSD. **Bloquant** — compter
/// plusieurs secondes. NULL en cas d'échec, lire `px_last_error`.
///
/// `host` et `port` viennent de la découverte Bonjour faite côté Swift.
/// `pairing_path` est le fichier écrit par `px_pairing_run_host`.
///
/// # Safety
/// Chaînes UTF-8 terminées par NUL. Le handle rendu ne se libère qu'avec
/// `px_tunnel_free`.
#[no_mangle]
pub unsafe extern "C" fn px_tunnel_connect(
    pairing_path: *const c_char,
    host: *const c_char,
    port: u16,
) -> *mut PxTunnel {
    clear_last_error();

    let (Some(path), Some(host)) = (cstr(pairing_path), cstr(host)) else {
        set_last_error("px_tunnel_connect : chemin ou hôte nul");
        return ptr::null_mut();
    };
    if port == 0 {
        set_last_error("px_tunnel_connect : port nul — la découverte Bonjour n'a rien rendu");
        return ptr::null_mut();
    }

    // Même garde-fou que px_pairing_validate : idevice mappe toute io::Error
    // sur sa variante Socket, donc un fichier absent remonte en Socket(ENOENT)
    // et ressemble à s'y méprendre à un échec de socket.
    match std::fs::metadata(&path) {
        Ok(m) if m.len() > 0 => {}
        _ => {
            set_last_error("px_tunnel_connect : fichier de jumelage absent ou vide — refais le jumelage");
            return ptr::null_mut();
        }
    }

    #[cfg(feature = "device-pairing")]
    {
        guard("px_tunnel_connect", ptr::null_mut(), || {
            match imp::connect(&path, &host, port) {
                Ok(inner) => Box::into_raw(Box::new(PxTunnel { inner })),
                Err(msg) => { set_last_error(msg); ptr::null_mut() }
            }
        })
    }
    #[cfg(not(feature = "device-pairing"))]
    {
        let _ = (path, host);
        set_last_error("px_tunnel_connect : compilé sans --features device-pairing");
        ptr::null_mut()
    }
}

/// Adaptateur TCP logiciel, à passer à `px_location_open`.
/// Emprunté au tunnel : **ne pas libérer**, et ne pas utiliser après
/// `px_tunnel_free`.
///
/// # Safety
/// `tunnel` valide, non libéré.
#[no_mangle]
pub unsafe extern "C" fn px_tunnel_adapter(tunnel: *mut PxTunnel) -> *mut c_void {
    if tunnel.is_null() { return ptr::null_mut(); }
    #[cfg(feature = "device-pairing")]
    { imp::adapter_ptr(&mut (*tunnel).inner) }
    #[cfg(not(feature = "device-pairing"))]
    { ptr::null_mut() }
}

/// Poignée RSD, à passer à `px_location_open`. Mêmes règles que
/// `px_tunnel_adapter`.
///
/// # Safety
/// `tunnel` valide, non libéré.
#[no_mangle]
pub unsafe extern "C" fn px_tunnel_rsd(tunnel: *mut PxTunnel) -> *mut c_void {
    if tunnel.is_null() { return ptr::null_mut(); }
    #[cfg(feature = "device-pairing")]
    { imp::rsd_ptr(&mut (*tunnel).inner) }
    #[cfg(not(feature = "device-pairing"))]
    { ptr::null_mut() }
}

/// Services annoncés par RSD, en JSON `{ "nom": port }`.
///
/// C'est la preuve de vie du tunnel, et elle est utile en soi : la présence de
/// `com.apple.instruments.dtservicehub` dit que la DDI est montée, celle de
/// `com.apple.mobile.installation_proxy.shim.remote` que l'installation est
/// possible. À libérer par `px_string_free`.
///
/// # Safety
/// `tunnel` valide, non libéré.
#[no_mangle]
pub unsafe extern "C" fn px_tunnel_services(tunnel: *mut PxTunnel) -> *mut c_char {
    clear_last_error();
    if tunnel.is_null() {
        set_last_error("px_tunnel_services : tunnel nul");
        return ptr::null_mut();
    }
    #[cfg(feature = "device-pairing")]
    {
        guard("px_tunnel_services", ptr::null_mut(), || {
            match imp::services_json(&mut (*tunnel).inner) {
                Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
                Err(e) => { set_last_error(e); ptr::null_mut() }
            }
        })
    }
    #[cfg(not(feature = "device-pairing"))]
    {
        set_last_error("px_tunnel_services : compilé sans --features device-pairing");
        ptr::null_mut()
    }
}

/// Accès interne au tunnel, pour `install.rs`. Même contrat que
/// `account::session_inner`.
///
/// # Safety
/// `tunnel` non nul, issu de `px_tunnel_connect`, non libéré.
#[cfg(feature = "device-pairing")]
pub(crate) unsafe fn tunnel_inner(tunnel: *mut PxTunnel) -> &'static mut imp::Tunnel {
    &mut (*tunnel).inner
}

/// Ferme le tunnel et **consomme** le pointeur.
///
/// Toute session GPS ouverte dessus doit être fermée **avant** : elle emprunte
/// l'adaptateur et la poignée RSD que ceci détruit.
///
/// # Safety
/// `tunnel` issu de `px_tunnel_connect`, libéré exactement une fois.
#[no_mangle]
pub unsafe extern "C" fn px_tunnel_free(tunnel: *mut PxTunnel) {
    if tunnel.is_null() { return; }
    drop(Box::from_raw(tunnel));
    tracing::info!("tunnel ferme");
}

#[cfg(feature = "device-pairing")]
mod imp {
    use idevice::remote_pairing::{
        RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
    };
    use idevice::rsd::RsdHandshake;
    use idevice::tcp::handle::AdapterHandle;
    use std::ffi::c_void;
    use std::net::SocketAddr;

    #[allow(dead_code)] // `runtime` n est jamais lu : il est detenu pour que les
    // taches de fond de la pile TCP vivent aussi longtemps que le tunnel.
    pub struct Tunnel {
        pub adapter: AdapterHandle,
        pub rsd: RsdHandshake,
        /// Détenu, jamais recréé : les tâches de fond de la pile TCP tournent
        /// dessus tant que le tunnel vit. Déclaré en dernier — l'ordre de
        /// destruction d'une struct est celui des champs, donc le runtime meurt
        /// après ce qui s'exécute dessus.
        pub runtime: tokio::runtime::Runtime,
    }

    pub fn connect(pairing_path: &str, host: &str, port: u16) -> Result<Tunnel, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2).enable_all().build()
            .map_err(|e| format!("runtime tokio : {e}"))?;

        let addr: SocketAddr = format!("{host}:{port}").parse()
            .map_err(|e| format!("adresse {host}:{port} invalide : {e}"))?;
        let path = pairing_path.to_string();

        let (adapter, rsd) = runtime.block_on(async move {
            let mut pairing_file = RpPairingFile::read_from_file(&path).await
                .map_err(|e| format!("lecture du fichier de jumelage : {e}"))?;

            let stream = tokio::net::TcpStream::connect(addr).await
                .map_err(|e| format!("connexion a {addr} : {e}"))?;
            let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "Parallax");

            // Le PIN n'est jamais redemande sur ce chemin : le fichier existe,
            // donc pair-verify suffit. Le rappel n'est la que parce que la
            // signature l'exige, et rendre une chaine vide fait echouer
            // proprement si l'appareil reclamait malgre tout un appairage.
            client.connect(&mut pairing_file, async || String::new()).await
                .map_err(|e| format!("pair-verify : {e} — le jumelage est peut-etre perime"))?;
            tracing::info!("pair-verify accepte");

            let tunnel_port = client.create_tcp_listener().await
                .map_err(|e| format!("ouverture du port de tunnel : {e}"))?;
            let tunnel_stream =
                tokio::net::TcpStream::connect(SocketAddr::new(addr.ip(), tunnel_port)).await
                    .map_err(|e| format!("connexion au tunnel : {e}"))?;

            let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key())
                .await
                .map_err(|e| format!("tunnel TLS-PSK : {e}"))?;

            let client_ip = tunnel.info.client_address.parse()
                .map_err(|e| format!("adresse hote du tunnel : {e}"))?;
            let server_ip = tunnel.info.server_address.parse()
                .map_err(|e| format!("adresse appareil du tunnel : {e}"))?;
            let mtu = tunnel.info.mtu as usize;
            let rsd_port = tunnel.info.server_rsd_port;
            tracing::info!("tunnel etabli, port RSD {rsd_port}, MTU {mtu}");

            let raw = tunnel.into_inner();
            let mut adapter =
                idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
            // 60 octets : en-tete IPv6 (40) + en-tete TCP (20). Sans ca les
            // segments depassent le MTU du tunnel et sont silencieusement
            // perdus — symptome : la poignee RSD reste bloquee.
            adapter.set_mss(mtu.saturating_sub(60));
            let mut adapter = adapter.to_async_handle();

            let rsd_stream = adapter.connect(rsd_port).await
                .map_err(|e| format!("connexion au port RSD {rsd_port} : {e}"))?;
            let rsd = RsdHandshake::new(rsd_stream).await
                .map_err(|e| format!("poignee de main RSD : {e}"))?;

            tracing::info!("RSD pret : {} service(s) annonce(s)", rsd.services.len());
            Ok::<_, String>((adapter, rsd))
        })?;

        Ok(Tunnel { adapter, rsd, runtime })
    }

    pub fn adapter_ptr(t: &mut Tunnel) -> *mut c_void {
        &mut t.adapter as *mut AdapterHandle as *mut c_void
    }

    pub fn rsd_ptr(t: &mut Tunnel) -> *mut c_void {
        &mut t.rsd as *mut RsdHandshake as *mut c_void
    }

    pub fn services_json(t: &mut Tunnel) -> Result<String, String> {
        let mut entries: Vec<(String, u16)> = t.rsd.services.iter()
            .map(|(name, service)| (name.clone(), service.port))
            .collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0));

        let body = entries.iter()
            .map(|(name, port)| format!("{}:{}", escape(name), port))
            .collect::<Vec<_>>()
            .join(",");
        Ok(format!("{{{body}}}"))
    }

    /// Sérialisation JSON à la main : serde_json n'est activé que par
    /// `device-account`, et ce module vit sous `device-pairing`.
    fn escape(s: &str) -> String {
        let mut out = String::with_capacity(s.len() + 2);
        out.push('"');
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
        out
    }
}
