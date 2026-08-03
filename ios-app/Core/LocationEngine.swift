import Foundation
import CoreLocation
import Combine
import Network

/// Superviseur de la simulation de localisation.
///
/// Raison d'être : la position simulée disparaît dès que le canal DVT se ferme.
/// Une micro-coupure du tunnel LocalDevVPN — bascule Wi-Fi, veille, changement de
/// réseau — suffit à faire réapparaître la vraie position en une seconde. Ce
/// n'est donc pas un mécanisme de confort mais la condition pour que la
/// fonctionnalité tienne plus de quelques minutes.
///
/// Modèle : une seule tâche détient la session ; toute reprise passe par elle.
/// Une reconnexion réussie réapplique le dernier fix connu avant de reprendre
/// la source active (joystick ou trace GPX), de sorte que l'utilisateur ne voit
/// qu'un bref passage en `degraded`.
@MainActor
final class LocationEngine: ObservableObject {

    enum State: Equatable {
        case idle
        case mountingDDI
        case connecting
        case simulating
        /// Canal perdu, reprise en cours. La vraie position est visible pendant
        /// ce temps — c'est irréductible, on ne peut que raccourcir la fenêtre.
        case degraded(attempt: Int)
        /// Canal perdu **et** appareil en cellulaire. iOS refuse de démarrer le
        /// service de localisation hors Wi-Fi / partage de connexion / USB, donc
        /// réessayer ne sert à rien : on attend le retour du Wi-Fi.
        case waitingForWiFi
        case failed(String)
    }

    /// Ce qui pilote la position quand la session est vivante.
    enum Source: Equatable {
        case fixed(CLLocationCoordinate2D)
        case joystick(CLLocationCoordinate2D)
        case track(GPXTrack)

        static func == (a: Source, b: Source) -> Bool {
            switch (a, b) {
            case let (.fixed(l), .fixed(r)), let (.joystick(l), .joystick(r)):
                return l.latitude == r.latitude && l.longitude == r.longitude
            case let (.track(l), .track(r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentFix: CLLocationCoordinate2D?
    @Published private(set) var log: [String] = []
    /// Trace en cours de lecture, pour l'affichage. `nil` si aucune.
    @Published private(set) var playingTrack: GPXTrack?
    /// Lecture GPX en pause : la position est figée, la session reste ouverte.
    @Published private(set) var trackPaused = false
    /// Avancement de la trace en cours, de 0 à 1. Alimente la barre du panneau.
    @Published private(set) var trackProgress: Double = 0
    /// Rejoue la trace en boucle. Modifiable pendant la lecture ; prend effet
    /// au bout de la trace.
    @Published var loopTrack = false

    /// **Mode furtif.** Une position parfaitement immobile trahit un spoof : un
    /// vrai GPS bruite toujours de quelques mètres. Quand c'est actif, un point
    /// fixe reçoit un léger bruit à chaque tick, pour « respirer » comme un vrai
    /// relevé. Sans effet sur une trace ou le joystick, déjà en mouvement.
    @Published var stealthMode = false

    /// **Mode flânerie.** Au lieu de rester figé, le point se **promène** autour
    /// de son ancre : il choisit un lieu au hasard dans un rayon, y marche à
    /// allure piétonne, s'arrête parfois, repart. On ne ressemble plus à une
    /// épingle gelée mais à quelqu'un qui vit sur place — ce que traquent Snap
    /// Map, Life360 & co. Prime sur le mode furtif quand les deux sont actifs.
    @Published var strollMode = false

    /// Ancre de la flânerie (le point posé) et destination courante.
    private var strollAnchor: CLLocationCoordinate2D?
    private var strollWaypoint: CLLocationCoordinate2D?
    /// Rayon de flânerie, en mètres.
    private let strollRadius: Double = 70

    /// Point reçu via un lien `parallax://locate` (partage entre appareils ou
    /// site web), en attente d'être visé par la carte. Consommé puis remis à nil.
    @Published var pendingShare: SharePoint?

    private var session: OpaquePointer?
    private var pump: Task<Void, Never>?
    private var source: Source?
    /// Départ de la trace en cours ; reculé à la reprise pour rattraper la pause.
    private var trackStartedAt: Date = .now
    /// Non-nil ⟺ en pause : temps écoulé figé au moment de la mise en pause.
    private var trackPausedElapsed: TimeInterval?

    private let connection: DeviceConnection

    /// Surveille le type d'interface. Une session déjà ouverte survit au passage
    /// en cellulaire ; seule la (re)connexion exige du Wi-Fi.
    private let pathMonitor = NWPathMonitor()
    private var canOpenSession = true

    /// 1 Hz. Le système lisse déjà les fixes ; monter plus haut sature le canal
    /// DVT sans rien améliorer de visible.
    private let pumpInterval: Duration = .milliseconds(1000)

    /// Plafonnée à 8 s : au-delà, l'utilisateur croit l'app plantée.
    private let maxBackoff: Duration = .seconds(8)

    init(connection: DeviceConnection) {
        self.connection = connection

        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Wi-Fi, partage de connexion et USB conviennent ; le cellulaire seul
            // ne permet pas d'ouvrir une session (voir README).
            let ok = path.status == .satisfied && !path.usesInterfaceType(.cellular)
            Task { @MainActor in self?.canOpenSession = ok }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sidespoofer.path"))
    }

    deinit { pathMonitor.cancel() }

    // MARK: - Cycle de vie

    func start(at coordinate: CLLocationCoordinate2D) async {
        guard case .idle = state else { return }
        source = .fixed(coordinate)
        await openAndRun()
    }

    func stop() async {
        pump?.cancel()
        pump = nil
        source = nil
        playingTrack = nil
        trackPaused = false
        trackPausedElapsed = nil
        trackProgress = 0
        strollAnchor = nil
        strollWaypoint = nil

        if let session {
            // clear() avant close() : rendre le GPS réel explicitement plutôt que
            // de compter sur l'effet de bord de la fermeture. Le résultat est le
            // même, mais l'intention est lisible dans les logs de support.
            _ = px_location_clear(session)
            px_location_close(session)
        }
        session = nil
        currentFix = nil
        state = .idle
        note("simulation arrêtée")
    }

    // MARK: - Sources

    func teleport(to coordinate: CLLocationCoordinate2D) {
        source = .fixed(coordinate)
        Task { await applyNow(coordinate) }
    }

    /// Le joystick intègre un déplacement : la vue fournit un cap et une vitesse,
    /// on avance depuis la position courante à chaque tick.
    func joystick(bearingDegrees: Double, metersPerSecond: Double) {
        guard let from = currentFix else { return }
        let next = from.advanced(byMeters: metersPerSecond, bearing: bearingDegrees)
        source = .joystick(next)
    }

    func play(track: GPXTrack) {
        playingTrack = track
        trackStartedAt = .now
        trackPausedElapsed = nil
        trackPaused = false
        trackProgress = 0
        source = .track(track)
        note("lecture GPX : \(track.points.count) points, \(Int(track.duration))s")
    }

    /// Fige la lecture sans fermer la session : reprendre doit être instantané.
    func pauseTrack() {
        guard case .track = source, !trackPaused else { return }
        trackPausedElapsed = Date.now.timeIntervalSince(trackStartedAt)
        trackPaused = true
        note("lecture GPX en pause")
    }

    /// Reprend là où la pause s'était arrêtée, en reculant le départ d'autant.
    func resumeTrack() {
        guard case .track = source, trackPaused,
              let elapsed = trackPausedElapsed else { return }
        trackStartedAt = Date.now.addingTimeInterval(-elapsed)
        trackPausedElapsed = nil
        trackPaused = false
        note("lecture GPX reprise")
    }

    /// Arrête la lecture GPX et fige la position courante.
    /// La session reste ouverte : couper le spoof pour arrêter un trajet
    /// obligerait à tout relancer, ce qui n'est jamais ce qu'on veut.
    func stopTrack() {
        playingTrack = nil
        trackPaused = false
        trackPausedElapsed = nil
        trackProgress = 0
        if let fix = currentFix { source = .fixed(fix) }
        note("lecture GPX arrêtée")
    }

    // MARK: - Boucle supervisée

    private func openAndRun() async {
        // Monter le lien AVANT tout le reste. L'écran Carte ne le faisait pas,
        // contrairement à l'écran Installer : si le tunnel avait été fermé
        // entre-temps, `ensureDDIMounted` levait une erreur qui accusait le VPN
        // — alors que le VPN allait très bien et qu'il ne manquait que le lien.
        state = .connecting
        do {
            try await connection.connect()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        state = .mountingDDI

        // Gate DDI en premier. Sans ça, l'échec DVT remonte une erreur opaque et
        // l'utilisateur ira chercher du côté du VPN.
        do {
            try await connection.ensureDDIMounted { [weak self] message in
                Task { @MainActor in self?.note(message) }
            }
        } catch {
            state = .failed("Image développeur non montée : \(error.localizedDescription)")
            return
        }

        state = .connecting
        guard let rsd = connection.rsdHandle, let adapter = connection.adapterHandle else {
            state = .failed("Tunnel non établi. Passe par l'onglet Jumelage.")
            return
        }

        // L'adaptateur est le premier argument : `imp::open` rejette un nul.
        guard let opened = px_location_open(adapter, rsd) else {
            state = .failed(lastRustError() ?? "Ouverture du canal DVT impossible")
            return
        }

        session = opened
        state = .simulating
        note("canal DVT ouvert")
        startPump()
    }

    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            var attempt = 0

            while !Task.isCancelled {
                guard let self else { return }

                let ok = await self.tick()
                if ok {
                    if attempt > 0 {
                        attempt = 0
                        await MainActor.run { self.state = .simulating }
                        await self.noteAsync("canal rétabli")
                    }
                    try? await Task.sleep(for: self.pumpInterval)
                    continue
                }

                // Échec : canal probablement mort.
                attempt += 1

                // En cellulaire seul, réessayer est garanti inutile : iOS refuse
                // d'ouvrir le service hors Wi-Fi. On attend, sans brûler la
                // batterie ni empiler des essais qui échoueront tous.
                let reachable = await MainActor.run { self.canOpenSession }
                guard reachable else {
                    await MainActor.run { self.state = .waitingForWiFi }
                    await self.noteAsync("données cellulaires — reprise impossible, en attente du Wi-Fi")
                    while !Task.isCancelled, await !MainActor.run(body: { self.canOpenSession }) {
                        try? await Task.sleep(for: .seconds(3))
                    }
                    attempt = 0
                    await self.reopen()
                    continue
                }

                await MainActor.run { self.state = .degraded(attempt: attempt) }

                let backoff = min(
                    Duration.milliseconds(250 * (1 << min(attempt, 5))),
                    self.maxBackoff
                )
                await self.noteAsync("canal perdu (essai \(attempt)), reprise dans \(backoff.seconds)s")
                try? await Task.sleep(for: backoff)

                await self.reopen()
            }
        }
    }

    /// Un cycle : calcule la position voulue, l'applique. `false` = session morte.
    private func tick() async -> Bool {
        guard let session, let source else { return false }

        let target: CLLocationCoordinate2D
        switch source {
        case .fixed(let c):
            // Flânerie > furtif > figé. La flânerie promène le point ; le furtif
            // le fait juste vibrer ; sinon il reste fixe.
            if strollMode {
                target = nextStroll(around: c)
            } else if stealthMode {
                target = c.jittered(radiusMeters: 3.5)
            } else {
                target = c
            }
        case .joystick(let c):
            target = c
        case .track(let track):
            let duration = max(track.duration, 0.001)
            if let paused = trackPausedElapsed {
                // En pause : position figée, session maintenue vivante.
                target = track.coordinate(atElapsed: paused)
                    ?? currentFix ?? track.points.first?.coordinate ?? track.points.last!.coordinate
                trackProgress = min(1, max(0, paused / duration))
            } else {
                let elapsed = Date.now.timeIntervalSince(trackStartedAt)
                if let c = track.coordinate(atElapsed: elapsed) {
                    target = c
                    trackProgress = min(1, max(0, elapsed / duration))
                } else if loopTrack {
                    // Reboucle sans couper la session : le trajet reprend au départ.
                    trackStartedAt = .now
                    trackProgress = 0
                    note("trace rejouée en boucle")
                    target = track.points.first?.coordinate
                        ?? currentFix ?? track.points.last!.coordinate
                } else {
                    note("fin de la trace GPX")
                    playingTrack = nil
                    trackProgress = 1
                    let last = currentFix ?? track.points.last!.coordinate
                    // `self.` obligatoire : `guard let source` a introduit une
                    // constante locale qui masque la propriété d'instance.
                    self.source = .fixed(last)
                    target = last
                }
            }
        }

        let rc = px_location_set(session, target.latitude, target.longitude)
        guard rc == PX_OK else { return false }

        currentFix = target
        return true
    }

    /// Reconstruit la session et restaure l'état. Le point clé est la
    /// restauration : sans elle, la reprise laisse l'utilisateur à sa vraie
    /// position jusqu'au tick suivant, ce qui est exactement le symptôme qu'on
    /// cherche à supprimer.
    private func reopen() async {
        if let old = session {
            px_location_close(old)
            session = nil
        }

        // Le tunnel lui-même a pu tomber : le remonter d'abord.
        do {
            try await connection.reconnectIfNeeded()
        } catch {
            await noteAsync("tunnel indisponible : \(error.localizedDescription)")
            return
        }

        guard let rsd = connection.rsdHandle, let adapter = connection.adapterHandle,
              let opened = px_location_open(adapter, rsd) else {
            await noteAsync(lastRustError() ?? "réouverture DVT échouée")
            return
        }

        session = opened

        // Réapplique immédiatement, sans attendre le prochain tick.
        if let fix = await MainActor.run(body: { self.currentFix }) {
            _ = px_location_set(opened, fix.latitude, fix.longitude)
        }
    }

    /// Un pas de flânerie autour de `anchor`. Marche vers une destination tirée
    /// au hasard dans le rayon ; en arrivant, en choisit une autre (avec une
    /// chance de « faire une pause » sur place). Re-ancre si l'utilisateur a
    /// changé de point.
    private func nextStroll(around anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if strollAnchor == nil || strollAnchor!.distance(to: anchor) > strollRadius * 1.5 {
            strollAnchor = anchor
            strollWaypoint = anchor.jittered(radiusMeters: strollRadius)
        }
        let base = strollAnchor ?? anchor
        let from = currentFix ?? anchor
        let waypoint = strollWaypoint ?? base

        if from.distance(to: waypoint) < 2 {
            // Arrivé : une pause de temps en temps, sinon nouvelle destination.
            if Double.random(in: 0 ... 1) < 0.25 { return from }
            strollWaypoint = base.jittered(radiusMeters: strollRadius)
            return from
        }

        // ~1,3 m/s à 1 Hz : allure de marche. Un léger bruit latéral évite la
        // ligne droite parfaite.
        let step = min(1.3, from.distance(to: waypoint))
        let stepped = from.advanced(byMeters: step, bearing: from.bearing(to: waypoint))
        return stepped.jittered(radiusMeters: 0.6)
    }

    private func applyNow(_ coordinate: CLLocationCoordinate2D) async {
        guard let session else { return }
        if px_location_set(session, coordinate.latitude, coordinate.longitude) == PX_OK {
            currentFix = coordinate
        }
    }

    // MARK: - Divers

    private func lastRustError() -> String? {
        guard let ptr = px_last_error() else { return nil }
        return String(cString: ptr)
    }

    private func note(_ message: String) {
        log.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }

    private func noteAsync(_ message: String) async {
        await MainActor.run { self.note(message) }
    }
}

// MARK: - Géodésie

extension CLLocationCoordinate2D {
    /// Avance de `meters` selon un cap, en projection plane locale.
    /// Suffisant pour un joystick : l'erreur reste sous le mètre par pas à ces
    /// distances, et le système reçoit de toute façon des fixes discrets.
    func advanced(byMeters meters: Double, bearing degrees: Double) -> CLLocationCoordinate2D {
        let rad = degrees * .pi / 180
        let dLat = (meters * cos(rad)) / 111_320
        let dLon = (meters * sin(rad)) / (111_320 * cos(latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: latitude + dLat, longitude: longitude + dLon)
    }

    /// Un point tiré au hasard dans un disque de rayon `radiusMeters` autour de
    /// soi — le bruit du mode furtif. Distribution en surface (racine du rayon)
    /// pour ne pas s'agglutiner au centre.
    func jittered(radiusMeters: Double) -> CLLocationCoordinate2D {
        let angle = Double.random(in: 0 ..< (2 * .pi))
        let distance = radiusMeters * Double.random(in: 0 ... 1).squareRoot()
        return advanced(byMeters: distance, bearing: angle * 180 / .pi)
    }

    /// Distance en mètres (géodésique, via CLLocation).
    func distance(to other: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    /// Cap initial (degrés) vers un autre point.
    func bearing(to other: CLLocationCoordinate2D) -> Double {
        let dLon = (other.longitude - longitude) * .pi / 180
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }
}

private extension Duration {
    var seconds: String {
        String(format: "%.1f", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}
