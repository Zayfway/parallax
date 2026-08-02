import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

/// Onglet Carte.
///
/// La carte occupe tout l'écran et les panneaux flottent dessus en verre : le
/// sujet, c'est le territoire, pas les contrôles. Chaque panneau n'apparaît
/// que quand il a quelque chose à dire — un écran couvert de commandes inertes
/// est ce qu'on cherche à éviter.
///
/// ── POURQUOI PAS DE BANDEAU NI DE RAIL ────────────────────────────────────
///
/// Les trois autres écrans partagent une machine à phases, un bandeau coloré
/// et un rail numéroté. Pas celui-ci, et c'est délibéré : ces éléments servent
/// à conduire quelqu'un à travers une suite d'étapes. Ici il n'y a pas de
/// suite — on regarde un territoire et on y pose un point.
///
/// ── DEUX FAÇONS DE MENTIR ─────────────────────────────────────────────────
///
/// Se **téléporter** : un appui pose un point, la position y saute.
/// **Parcourir** : on choisit un profil et une arrivée, et la position suit un
/// trajet réel dans le temps. Voiture et marche empruntent les vraies routes
/// via `MKDirections` ; l'avion suit une orthodromie. La vitesse n'accélère que
/// le temps, jamais la trajectoire.
///
/// L'état est donc porté par `StatusBar`, qui remplit exactement le même rôle
/// dans un vocabulaire adapté à la carte, et par le marqueur lui-même. C'est
/// aussi le seul écran où **l'ambre a le droit d'exister** : quand la position
/// est simulée, le marqueur, la bande d'instruments et la barre d'onglets
/// virent ensemble. Un bandeau supplémentaire diluerait ce signal, qui est la
/// chose la plus importante que cette app ait à dire.
struct MapScreen: View {

    @EnvironmentObject private var engine: LocationEngine

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var pendingDrop: CLLocationCoordinate2D?
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var fixCount = 0
    @State private var shown = false

    // ── Itinéraire ────────────────────────────────────────────────────────
    @State private var routeDestination: CLLocationCoordinate2D?
    @State private var routeProfile: RouteProfile = .driving
    @State private var routeSpeed: Double = 1
    @State private var routePlan: RoutePlanner.Plan?
    @State private var planning = false
    @State private var routeError: String?
    /// Quand il est actif, un appui long sur la carte pose l'arrivée au lieu
    /// de téléporter. Deux gestes distincts pour deux intentions distinctes.
    @State private var routeMode = false

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            overlays
        }
        .onAppear { shown = true }
        .safeAreaInset(edge: .top) { toolbar.appear(0, shown) }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]
        ) { handleImport($0) }
        .alert("Import GPX", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        // Le fix acquis se sent avant de se voir.
        .sensoryFeedback(.success, trigger: fixCount)
    }

    // MARK: - Carte

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let fix = engine.currentFix {
                    Annotation("Position simulée", coordinate: fix) {
                        ZStack {
                            FixAcquiredRing(trigger: fixCount)
                            SimulatedMarker(live: engine.state == .simulating,
                                            degraded: isDegraded)
                        }
                    }
                }
                if let plan = routePlan {
                    MapPolyline(coordinates: plan.polyline)
                        .stroke(PX.Color.azimuth.opacity(0.85), style:
                            StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if let destination = routeDestination {
                    Annotation("Arrivée", coordinate: destination) {
                        ZStack {
                            Circle()
                                .fill(PX.Color.azimuth.opacity(0.22))
                                .frame(width: 30, height: 30)
                            Image(systemName: routeProfile.icon)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(PX.Color.azimuth)
                        }
                    }
                }
                if let pending = pendingDrop {
                    Annotation("Nouveau point", coordinate: pending) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(PX.Color.azimuth)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            .mapStyle(style.mapStyle)
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                // Deux intentions, deux comportements : en mode trajet on pose
                // une arrivée, sinon on téléporte. Mélanger les deux sur le même
                // geste rendrait chaque appui ambigu.
                if routeMode {
                    withAnimation(PX.Motion.tap) { routeDestination = coordinate }
                    recomputeRoute()
                } else {
                    withAnimation(PX.Motion.tap) { pendingDrop = coordinate }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Panneaux

    private var overlays: some View {
        VStack(spacing: PX.Space.snug) {
            if let track = engine.playingTrack {
                trackCard(track)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if routeMode {
                routePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pending = pendingDrop {
                DropConfirmation(coordinate: pending) {
                    Task { await activate(at: pending) }
                    withAnimation(PX.Motion.acquire) { pendingDrop = nil }
                    fixCount += 1
                } cancel: {
                    withAnimation(PX.Motion.tap) { pendingDrop = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: PX.Space.snug) {
                StatusBar(state: engine.state)
                    .appear(1, shown)

                if engine.state == .simulating || isDegraded {
                    Joystick { bearing, speed in
                        engine.joystick(bearingDegrees: bearing, metersPerSecond: speed)
                    }
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .padding(PX.Space.base)
        .animation(PX.Motion.settle, value: engine.state)
        .animation(PX.Motion.settle, value: pendingDrop != nil)
        .animation(PX.Motion.settle, value: routeMode)
        .animation(PX.Motion.settle, value: routePlan?.distance)
    }

    // MARK: - Itinéraire

    /// Un trajet n'est pas une téléportation : on choisit un profil, une
    /// arrivée, une vitesse, et la position **parcourt** la trace. Le tracé
    /// s'affiche avant qu'on ne lance quoi que ce soit, parce que la première
    /// question est toujours « il passe par où ? ».
    private var routePanel: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack {
                SectionLabel("Trajet")
                Spacer()
                Button {
                    withAnimation(PX.Motion.tap) {
                        routeMode = false; routePlan = nil
                        routeDestination = nil; routeError = nil
                    }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PX.Color.inkFaint)
            }

            SegmentedRow(selection: $routeProfile, options: RouteProfile.allCases) {
                $0.rawValue
            }
            .onChange(of: routeProfile) { _, _ in recomputeRoute() }

            // Vitesse : n'accélère que le temps, jamais la trajectoire.
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Vitesse")
                        .font(PX.Font.mono(10, .semibold))
                        .tracking(0.9)
                        .foregroundStyle(PX.Color.inkFaint)
                    Spacer()
                    Text(routeSpeed == 1 ? "réelle" : String(format: "× %.0f", routeSpeed))
                        .font(PX.Font.mono(11, .semibold))
                        .foregroundStyle(PX.Color.azimuth)
                        .contentTransition(.numericText())
                }
                Slider(value: $routeSpeed, in: 1...60, step: 1)
                    .tint(PX.Color.azimuth)
                    .onChange(of: routeSpeed) { _, _ in recomputeRoute() }
            }

            if let plan = routePlan {
                HStack(spacing: PX.Space.snug) {
                    Label(plan.distanceLabel, systemImage: "ruler")
                    Label(plan.durationLabel, systemImage: "clock")
                    Spacer()
                }
                .font(PX.Font.mono(11))
                .foregroundStyle(PX.Color.inkMuted)
                .transition(.opacity)
            } else if !planning {
                Text(routeDestination == nil
                     ? "Appui long sur la carte pour poser l'arrivée."
                     : "Calcul impossible pour l'instant.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkFaint)
            }

            if let routeError {
                Text(routeError)
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                guard let plan = routePlan else { return }
                engine.play(track: plan.track)
                withAnimation(PX.Motion.acquire) { routeMode = false }
                fixCount += 1
            } label: {
                HStack(spacing: PX.Space.tight) {
                    if planning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: routeProfile.icon)
                    }
                    Text(planning ? "Calcul du trajet…" : "Lancer le trajet")
                }
            }
            .buttonStyle(ProminentButtonStyle(enabled: routePlan != nil && !planning))
            .disabled(routePlan == nil || planning)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
    }

    /// Recalcule dès qu'un paramètre change. Le départ est la position simulée
    /// courante — c'est là qu'on est, du point de vue de l'appareil.
    private func recomputeRoute() {
        guard let destination = routeDestination,
              let start = engine.currentFix else { return }

        planning = true
        routeError = nil
        Task {
            do {
                let plan = try await RoutePlanner.plan(
                    from: start, to: destination,
                    profile: routeProfile, speedFactor: routeSpeed
                )
                withAnimation(PX.Motion.settle) { routePlan = plan }
            } catch {
                withAnimation(PX.Motion.settle) {
                    routePlan = nil
                    routeError = error.localizedDescription
                }
            }
            planning = false
        }
    }

    private func trackCard(_ track: GPXTrack) -> some View {
        HStack(spacing: PX.Space.snug) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .font(.system(size: 15))
                .foregroundStyle(PX.Color.signal)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(PX.Font.display(13.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text("\(track.points.count) points · \(Int(track.duration)) s")
                    .font(PX.Font.mono(11))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer()

            Button {
                engine.stopTrack()
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PX.Color.inkMuted)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var toolbar: some View {
        HStack(spacing: PX.Space.tight) {
            ForEach(MapStyleChoice.allCases, id: \.self) { choice in
                let active = choice == style
                Text(choice.label)
                    .font(PX.Font.display(12.5, active ? .semibold : .medium))
                    .foregroundStyle(active ? PX.Color.ink : PX.Color.inkFaint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(active ? PX.Color.strata : .clear)
                    )
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(PX.Motion.tap) { style = choice } }
            }

            Spacer()

            // Un trajet part de la position simulée : sans elle, rien à
            // calculer. Le bouton n'apparaît donc qu'une fois un point posé.
            if engine.currentFix != nil {
                Button {
                    withAnimation(PX.Motion.settle) {
                        routeMode.toggle()
                        if !routeMode { routePlan = nil; routeDestination = nil }
                    }
                } label: {
                    Image(systemName: routeMode ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                                                : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(routeMode ? PX.Color.azimuth : PX.Color.inkMuted)
                .padding(.horizontal, 6)
            }

            Button { showingImporter = true } label: {
                Image(systemName: "arrow.down.doc").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PX.Color.inkMuted)
            .padding(.horizontal, 6)

            if engine.state != .idle {
                Button {
                    Task { await engine.stop() }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PX.Color.alert)
            }
        }
        .padding(.horizontal, PX.Space.snug)
        .padding(.vertical, PX.Space.tight)
        .glassCard(radius: PX.Radius.control)
        .padding(.horizontal, PX.Space.base)
    }

    // MARK: -

    private var isDegraded: Bool {
        if case .degraded = engine.state { return true }
        return engine.state == .waitingForWiFi
    }

    private func activate(at coordinate: CLLocationCoordinate2D) async {
        if engine.state == .idle {
            await engine.start(at: coordinate)
        } else {
            engine.teleport(to: coordinate)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Accès au fichier refusé."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let track = try GPXTrack.parse(
                data: try Data(contentsOf: url),
                name: url.deletingPathExtension().lastPathComponent
            )

            Task {
                if engine.state == .idle, let first = track.points.first {
                    await engine.start(at: first.coordinate)
                }
                engine.play(track: track)
                fixCount += 1
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: -

private struct DropConfirmation: View {
    let coordinate: CLLocationCoordinate2D
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: PX.Space.snug) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Se téléporter ici")
                    .font(PX.Font.display(14, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text(String(format: "%+.5f · %+.5f", coordinate.latitude, coordinate.longitude))
                    .font(PX.Font.mono(11.5))
                    .monospacedDigit()
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer(minLength: PX.Space.tight)

            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PX.Color.inkMuted)
            .background(Circle().fill(.white.opacity(0.06)))

            Button(action: confirm) {
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Circle().fill(PX.Color.azimuth))
            .shadow(color: PX.Color.azimuth.opacity(0.4), radius: 10, y: 4)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
    }
}

private enum MapStyleChoice: CaseIterable {
    case standard, hybrid, imagery

    var label: String {
        switch self {
        case .standard: "Plan"
        case .hybrid: "Hybride"
        case .imagery: "Satellite"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .imagery: .imagery(elevation: .realistic)
        }
    }
}
