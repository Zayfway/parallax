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
pub unsafe extern "C" fn px_location_open(
    adapter: *mut c_void,
    rsd: *mut c_void,
) -> *mut PxLocationSession {
    clear_last_error();

    #[cfg(feature = "device-location")]
    {
        match imp::open(adapter, rsd) {
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
    use idevice::rsd::RsdHandshake;
    use idevice::tcp::handle::AdapterHandle;
    use idevice::RsdService;
    use idevice::provider::RsdProvider;
    use std::ffi::c_void;
    use tokio::sync::{mpsc, oneshot};

    // LocationSimulationClient<'a, R> EMPRUNTE le RemoteServerClient, donc on
    // ne peut pas ranger les deux dans une struct. Une tache asynchrone les
    // possede tous les deux et recoit des ordres par messages : l'emprunt vit
    // dans une seule portee async. Tant que la tache tourne, le canal DVT
    // reste ouvert, ce qui est l'invariant n1 de ce module.
    //
    // Le montage DDI est volontairement absent : a verifier d'abord s'il est
    // seulement necessaire (la doc de Mirage n'en parle jamais).

    pub enum Cmd {
        Set(f64, f64, oneshot::Sender<Result<(), String>>),
        Clear(oneshot::Sender<Result<(), String>>),
    }

    pub struct Session {
        pub tx: mpsc::UnboundedSender<Cmd>,
        pub runtime: tokio::runtime::Runtime,
    }

    struct SendPtr(*mut c_void);
    unsafe impl Send for SendPtr {}

    /// Le service Instruments n'est annonce par RSD qu'une fois la DDI
    /// montee : sa presence dans la liste *est* la reponse. Aucun appel
    /// reseau, contrairement a un montage speculatif.
    pub unsafe fn ddi_is_mounted(rsd: *mut c_void) -> i32 {
        if rsd.is_null() {
            crate::set_last_error("px_ddi_is_mounted : poignee RSD nulle");
            return crate::PX_ERR_ARG;
        }
        let rsd: &RsdHandshake = unsafe { &*(rsd as *const RsdHandshake) };
        let name = <RemoteServerClient<Box<dyn idevice::ReadWrite>> as RsdService>::rsd_service_name();
        if rsd.services.contains_key(name.as_ref()) {
            crate::PX_OK
        } else {
            crate::set_last_error("image developpeur non montee : service Instruments absent de RSD");
            crate::PX_ERR_DDI_NOT_MOUNTED
        }
    }
    pub unsafe fn ddi_mount(_p: *mut c_void, _i: &str, _m: &str) -> i32 { crate::PX_OK }

    pub unsafe fn open(adapter: *mut c_void, ptr: *mut c_void) -> Result<Session, String> {
        if adapter.is_null() || ptr.is_null() { return Err("handle nul".into()); }
        let raw_ad = SendPtr(adapter);
        let raw = SendPtr(ptr);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2).enable_all().build()
            .map_err(|e| format!("runtime tokio : {e}"))?;

        let (tx, mut rx) = mpsc::unbounded_channel::<Cmd>();
        let (ready_tx, ready_rx) = oneshot::channel::<Result<(), String>>();

        runtime.spawn(async move {
            let (raw, raw_ad) = (raw, raw_ad);
            let rsd: &'static mut RsdHandshake = unsafe { &mut *(raw.0 as *mut RsdHandshake) };
            let adapter: &'static mut AdapterHandle = unsafe { &mut *(raw_ad.0 as *mut AdapterHandle) };

            // On contourne `connect_rsd`. Son corps appelle `handshake.connect::<T>()`
            // avec `T: RsdService` générique, et la contrainte remonte en
            // « implementation of RsdService is not general enough » dès que le
            // futur passe par `runtime.spawn`. Ni `&'static mut` ni un turbofish
            // avec `+ 'static` n'y changent quoi que ce soit : la contrainte est
            // d'ordre supérieur et naît *dans* le corps, pas à l'appel.
            //
            // `rsd.services` étant public, on fait nous-mêmes les deux gestes que
            // `connect_rsd` enchaîne : chercher le port, ouvrir le flux.
            let name = <RemoteServerClient<Box<dyn idevice::ReadWrite>> as RsdService>::rsd_service_name().to_string();
            let port = match rsd.services.get(&name) {
                Some(s) => s.port,
                None => {
                    // Ce service n'apparaît qu'une fois la DDI montée : c'est
                    // exactement le diagnostic utile, autant le dire ici.
                    let _ = ready_tx.send(Err(format!(
                        "service {name} absent de RSD — image développeur non montée"
                    )));
                    return;
                }
            };
            let stream = match adapter.connect_to_service_port(port).await {
                Ok(s) => s,
                Err(e) => { let _ = ready_tx.send(Err(format!("connexion au port {port} : {e}"))); return; }
            };
            let mut server = RemoteServerClient::new(stream);
            let mut client = match LocationSimulationClient::new(&mut server).await {
                Ok(c) => c,
                Err(e) => { let _ = ready_tx.send(Err(format!("canal LocationSimulation : {e}"))); return; }
            };

            let _ = ready_tx.send(Ok(()));
            tracing::info!("canal DVT LocationSimulation ouvert");

            while let Some(cmd) = rx.recv().await {
                match cmd {
                    Cmd::Set(lat, lon, reply) => {
                        let _ = reply.send(client.set(lat, lon).await.map_err(|e| e.to_string()));
                    }
                    Cmd::Clear(reply) => {
                        let _ = reply.send(client.clear().await.map_err(|e| e.to_string()));
                    }
                }
            }
            tracing::info!("tache DVT terminee");
        });

        match runtime.block_on(ready_rx) {
            Ok(Ok(())) => Ok(Session { tx, runtime }),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("tache DVT interrompue".into()),
        }
    }

    fn request<F>(s: &mut Session, build: F) -> Result<(), String>
    where F: FnOnce(oneshot::Sender<Result<(), String>>) -> Cmd {
        let (reply_tx, reply_rx) = oneshot::channel();
        s.tx.send(build(reply_tx)).map_err(|_| "session DVT fermee".to_string())?;
        match s.runtime.block_on(reply_rx) {
            Ok(r) => r,
            Err(_) => Err("aucune reponse de la tache DVT".into()),
        }
    }

    pub fn set(s: &mut Session, lat: f64, lon: f64) -> Result<(), String> {
        request(s, |reply| Cmd::Set(lat, lon, reply))
    }

    pub fn clear(s: &mut Session) -> Result<(), String> { request(s, Cmd::Clear) }
}
