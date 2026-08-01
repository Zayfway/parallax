//! Simulation de localisation via DVT / Instruments.
//!
//! Chaîne : RPPairing → tunnel loopback → RSD
//!   → mobile_image_mounter (DDI, personnalisée via TSS sur iOS 17+)
//!   → `com.apple.instruments.server.services.LocationSimulation`
//!
//! ── DEUX INVARIANTS ────────────────────────────────────────────────────────
//!
//! 1. La localisation simulée **ne survit pas** à la fermeture du canal DVT.
//!    La session doit rester vivante tant que le spoof est actif — d'où le
//!    runtime Tokio détenu par la session et non recréé à chaque appel. C'est
//!    la raison pour laquelle `pymobiledevice3 simulate-location` reste bloqué
//!    jusqu'au Ctrl+C. Corollaire : le « self-healing » n'est pas un confort,
//!    c'est structurel.
//!
//! 2. Le canal DVT exige potentiellement une DDI montée. Teste
//!    `px_ddi_is_mounted` **avant** d'écrire l'écran de montage : la doc de
//!    Mirage ne mentionne aucune étape DDI côté utilisateur, donc soit elle
//!    monte en silence, soit le chemin RSD moderne s'en passe. Si l'image est
//!    déjà là, tu économises l'étape la plus lourde du projet.
//! ──────────────────────────────────────────────────────────────────────────

use crate::*;
use std::ffi::{c_double, c_void};

/// Handle opaque côté Swift.
pub struct PxLocationSession {
    #[cfg(feature = "device-location")]
    inner: imp::Session,
    last_fix: Option<(f64, f64)>,
}

/// `PX_OK` si la DDI est montée, `PX_ERR_DDI_NOT_MOUNTED` sinon.
///
/// # Safety
/// `rsd` : handle RSD valide issu de `tunnel_create_rppairing`, ou nul.
#[no_mangle]
pub unsafe extern "C" fn px_ddi_is_mounted(rsd: *mut c_void) -> c_int {
    clear_last_error();
    #[cfg(feature = "device-location")]
    { imp::ddi_is_mounted(rsd) }
    #[cfg(not(feature = "device-location"))]
    {
        let _ = rsd;
        set_last_error("px_ddi_is_mounted : compilé sans --features device-location");
        PX_ERR_NOT_BUILT
    }
}

/// Monte la DDI personnalisée. Déclenche une requête TSS chez Apple — appel
/// réseau comptable en secondes, à signaler comme tel dans l'interface.
///
/// # Safety
/// Pointeurs valides ; chaînes UTF-8 terminées par NUL.
#[no_mangle]
pub unsafe extern "C" fn px_ddi_mount(
    rsd: *mut c_void,
    image_path: *const c_char,
    manifest_path: *const c_char,
) -> c_int {
    clear_last_error();

    let (Some(image), Some(manifest)) = (cstr(image_path), cstr(manifest_path)) else {
        set_last_error("px_ddi_mount : chemin nul ou non-UTF-8");
        return PX_ERR_ARG;
    };

    #[cfg(feature = "device-location")]
    { imp::ddi_mount(rsd, &image, &manifest) }
    #[cfg(not(feature = "device-location"))]
    {
        let _ = (rsd, image, manifest);
        set_last_error("px_ddi_mount : compilé sans --features device-location");
        PX_ERR_NOT_BUILT
    }
}

/// Ouvre le canal DVT. NULL en cas d'échec — lire `px_last_error`.
///
/// Tant que le handle n'est pas passé à `px_location_close`, la session
/// maintient le canal ouvert, donc le spoof actif.
///
/// # Safety
/// `rsd` valide. Le handle retourné ne se libère qu'avec `px_location_close`.
#[no_mangle]
pub unsafe extern "C" fn px_location_open(rsd: *mut c_void) -> *mut PxLocationSession {
    clear_last_error();

    #[cfg(feature = "device-location")]
    {
        match imp::open(rsd) {
            Ok(inner) => Box::into_raw(Box::new(PxLocationSession { inner, last_fix: None })),
            Err(msg) => {
                // Cause n°1 en pratique : DDI absente. Le dire ici, sinon
                // l'utilisateur cherchera du côté du VPN pendant une heure.
                set_last_error(format!("{msg} — vérifie d'abord px_ddi_is_mounted"));
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "device-location"))]
    {
        let _ = rsd;
        // Le stub retourne une session utilisable : l'interface reste
        // pilotable en démo — marqueur, joystick et GPX compris — ce qui
        // permet de juger l'ergonomie avant que le natif ne soit branché.
        Box::into_raw(Box::new(PxLocationSession { last_fix: None }))
    }
}

/// Applique une position. Idempotent, appelable à haute fréquence.
///
/// Joystick et lecture GPX passent par ici, à 1–5 Hz. Au-delà le canal sature
/// sans bénéfice : le système lisse déjà les fixes.
///
/// # Safety
/// `handle` issu de `px_location_open`, non fermé.
#[no_mangle]
pub unsafe extern "C" fn px_location_set(
    handle: *mut PxLocationSession,
    latitude: c_double,
    longitude: c_double,
) -> c_int {
    clear_last_error();

    if handle.is_null() {
        set_last_error("px_location_set : session nulle");
        return PX_ERR_ARG;
    }
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        set_last_error(format!("coordonnées hors bornes : {latitude}, {longitude}"));
        return PX_ERR_ARG;
    }

    let session = &mut *handle;

    #[cfg(feature = "device-location")]
    {
        match imp::set(&mut session.inner, latitude, longitude) {
            Ok(()) => { session.last_fix = Some((latitude, longitude)); PX_OK }
            Err(msg) => {
                // Un échec ici signifie presque toujours canal fermé sous nos
                // pieds. SESSION_DEAD dit au superviseur de reconnecter plutôt
                // que de réessayer sur un canal mort.
                set_last_error(format!("px_location_set : {msg}"));
                PX_ERR_SESSION_DEAD
            }
        }
    }
    #[cfg(not(feature = "device-location"))]
    {
        session.last_fix = Some((latitude, longitude));
        PX_OK
    }
}

/// Dernier fix appliqué, pour restauration après reconnexion.
///
/// # Safety
/// `handle` valide ; `out_lat` / `out_lon` inscriptibles.
#[no_mangle]
pub unsafe extern "C" fn px_location_last_fix(
    handle: *mut PxLocationSession,
    out_lat: *mut c_double,
    out_lon: *mut c_double,
) -> c_int {
    if handle.is_null() || out_lat.is_null() || out_lon.is_null() {
        return PX_ERR_ARG;
    }
    match (*handle).last_fix {
        Some((lat, lon)) => { *out_lat = lat; *out_lon = lon; PX_OK }
        None => PX_ERR_ARG,
    }
}

/// Rend la main au GPS réel sans fermer la session.
///
/// # Safety
/// `handle` valide, non fermé.
#[no_mangle]
pub unsafe extern "C" fn px_location_clear(handle: *mut PxLocationSession) -> c_int {
    clear_last_error();
    if handle.is_null() { return PX_ERR_ARG; }

    let session = &mut *handle;
    session.last_fix = None;

    #[cfg(feature = "device-location")]
    {
        match imp::clear(&mut session.inner) {
            Ok(()) => { tracing::info!("simulation arrêtée, GPS réel rendu"); PX_OK }
            Err(msg) => { set_last_error(msg); PX_ERR_SESSION_DEAD }
        }
    }
    #[cfg(not(feature = "device-location"))]
    { PX_OK }
}

/// Ferme la session et **consomme** le pointeur.
/// Fermer le canal rend le GPS réel — comportement système, pas un choix.
///
/// # Safety
/// `handle` issu de `px_location_open`, fermé exactement une fois.
/// Ne jamais réutiliser le pointeur après cet appel.
#[no_mangle]
pub unsafe extern "C" fn px_location_close(handle: *mut PxLocationSession) {
    if handle.is_null() { return; }
    drop(Box::from_raw(handle));
    tracing::info!("session DVT fermée");
}

// ═══════════════════════════════════════════════════════════════════════════
// Implémentation réelle
//
// ⚠️ JAMAIS COMPILÉE. Les signatures suivent la documentation d'idevice, pas
// son code source. Confirme-les avec `cargo doc -p idevice --open` sur la
// révision épinglée, puis active `--features device-location` seul, avant les
// deux autres modules.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(feature = "device-location")]
mod imp {
    use idevice::dvt::location_simulation::LocationSimulationClient;
    use idevice::dvt::remote_server::RemoteServerClient;
    use idevice::mobile_image_mounter::ImageMounter;
    use idevice::rsd::RsdHandshake;
    use idevice::RsdService;
    use std::ffi::c_void;
    use tokio::sync::{mpsc, oneshot};

    // -- POURQUOI UNE TACHE DEDIEE ---------------------------------------
    //
    // `LocationSimulationClient<'a, R>` **emprunte** le RemoteServerClient :
    //
    //     pub async fn new(client: &'a mut RemoteServerClient<R>) -> ...
    //
    // Impossible de ranger les deux dans une meme struct : ce serait une
    // structure auto-referentielle, que Rust refuse.
    //
    // Recreer le client a chaque appel ouvrirait un canal DVT par seconde :
    // inacceptable sur une session longue. Un Box::leak marcherait mais
    // demande de l'unsafe qu'on ne pourrait pas verifier sans materiel.
    //
    // Retenu : **une tache asynchrone possede les deux**, et l'exterieur lui
    // parle par messages. L'emprunt vit dans une seule portee async, donc il
    // est naturellement valide. Bonus : tant que la tache tourne, le canal
    // DVT reste ouvert, ce qui est exactement l'invariant n1 de ce module.
    // --------------------------------------------------------------------

    pub enum Cmd {
        Set(f64, f64, oneshot::Sender<Result<(), String>>),
        Clear(oneshot::Sender<Result<(), String>>),
    }

    pub struct Session {
        pub tx: mpsc::UnboundedSender<Cmd>,
        pub runtime: tokio::runtime::Runtime,
    }

    /// Le handle RSD appartient a Swift et traverse une frontiere de tache.
    /// Contrat : il doit rester valide jusqu'a `px_location_close`.
    struct SendPtr(*mut c_void);
    unsafe impl Send for SendPtr {}

    fn rt() -> Result<tokio::runtime::Runtime, String> {
        tokio::runtime::Runtime::new().map_err(|e| format!("runtime tokio : {e}"))
    }

    pub unsafe fn ddi_is_mounted(ptr: *mut c_void) -> i32 {
        if ptr.is_null() {
            crate::set_last_error("handle RSD nul");
            return crate::PX_ERR_ARG;
        }
        let rsd = &mut *(ptr as *mut RsdHandshake);
        let rt = match rt() {
            Ok(r) => r,
            Err(e) => { crate::set_last_error(e); return crate::PX_ERR_INTERNAL; }
        };

        rt.block_on(async {
            let mut m = match ImageMounter::connect(rsd).await {
                Ok(m) => m,
                Err(e) => {
                    crate::set_last_error(format!("mobile_image_mounter : {e}"));
                    return crate::PX_ERR_INTERNAL;
                }
            };
            match m.copy_devices().await {
                Ok(d) if !d.is_empty() => {
                    tracing::info!("DDI montee ({} entree(s))", d.len());
                    crate::PX_OK
                }
                Ok(_) => { tracing::info!("aucune DDI montee"); crate::PX_ERR_DDI_NOT_MOUNTED }
                Err(e) => {
                    crate::set_last_error(format!("interrogation DDI : {e}"));
                    crate::PX_ERR_INTERNAL
                }
            }
        })
    }

    pub unsafe fn ddi_mount(ptr: *mut c_void, image: &str, manifest: &str) -> i32 {
        if ptr.is_null() {
            crate::set_last_error("handle RSD nul");
            return crate::PX_ERR_ARG;
        }
        let rsd = &mut *(ptr as *mut RsdHandshake);
        let rt = match rt() {
            Ok(r) => r,
            Err(e) => { crate::set_last_error(e); return crate::PX_ERR_INTERNAL; }
        };

        rt.block_on(async {
            let mut mounter = match ImageMounter::connect(rsd).await {
                Ok(m) => m,
                Err(e) => {
                    crate::set_last_error(format!("mobile_image_mounter : {e}"));
                    return crate::PX_ERR_DDI_MOUNT_FAILED;
                }
            };
            let (img, man) = match (
                tokio::fs::read(image).await,
                tokio::fs::read(manifest).await,
            ) {
            ) {
      


                (Ok(i), Ok(m)) => (i, m),
                (Err(e), _) | (_, Err(e)) => {
                    crate::set_last_error(format!("lecture DDI : {e}"));
                    return crate::PX_ERR_DDI_MOUNT_FAILED;
                }
            };

            tracing::info!("montage DDI : {} o, requete TSS en cours", img.len());

            match mounter.mount_personalized(&img, &man, None).await {
                Ok(()) => { tracing::info!("DDI montee"); crate::PX_OK }
                Err(e) => {
                    crate::set_last_error(format!("montage DDI : {e}"));
                    crate::PX_ERR_DDI_MOUNT_FAILED
                }
            }
        })
    }

    pub unsafe fn open(ptr: *mut c_void) -> Result<Session, String> {
        if ptr.is_null() { return Err("handle RSD nul".into()); }
        let raw = SendPtr(ptr);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| format!("runtime tokio : {e}"))?;

        let (tx, mut rx) = mpsc::unbounded_channel::<Cmd>();
        let (ready_tx, ready_rx) = oneshot::channel::<Result<(), String>>();

        runtime.spawn(async move {
            let raw = raw;
            let rsd = unsafe { &mut *(raw.0 as *mut RsdHandshake) };

            let mut server = match RemoteServerClient::connect_rsd(rsd).await {
                Ok(s) => s,
                Err(e) => { let _ = ready_tx.send(Err(format!("ouverture DVT : {e}"))); return; }
            };

            let mut client = match LocationSimulationClient::new(&mut server).await {
                Ok(c) => c,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("canal LocationSimulation : {e}")));
                    return;
                }
            };

            let _ = ready_tx.send(Ok(()));
            tracing::info!("canal DVT LocationSimulation ouvert");

            while let Some(cmd) = rx.recv().await {
                match cmd {
                    Cmd::Set(lat, lon, reply) => {
                        let r = client.set(lat, lon).await.map_err(|e| e.to_string());
                        let _ = reply.send(r);
                    }
                    Cmd::Clear(reply) => {
                        let r = client.clear().await.map_err(|e| e.to_string());
                        let _ = reply.send(r);
                    }
                }
            }
            // Canal ferme = session fermee. client puis server tombent ici,
            // et c'est la fermeture du serveur qui rend le GPS reel.
            tracing::info!("tache DVT terminee");
        });

        match runtime.block_on(ready_rx) {
            Ok(Ok(())) => Ok(Session { tx, runtime }),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("tache DVT interrompue avant d'etre prete".into()),
        }
    }

    fn request<F>(s: &mut Session, build: F) -> Result<(), String>
    where
        F: FnOnce(oneshot::Sender<Result<(), String>>) -> Cmd,
    {
        let (reply_tx, reply_rx) = oneshot::channel();
        s.tx.send(build(reply_tx))
            .map_err(|_| "session DVT fermee".to_string())?;
        match s.runtime.block_on(reply_rx) {
            Ok(r) => r,
            Err(_) => Err("aucune reponse de la tache DVT".into()),
        }
    }

    pub fn set(s: &mut Session, lat: f64, lon: f64) -> Result<(), String> {
        request(s, |reply| Cmd::Set(lat, lon, reply))
    }

    pub fn clear(s: &mut Session) -> Result<(), String> {
        request(s, Cmd::Clear)
    }
}
