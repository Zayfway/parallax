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
    @EnvironmentObject private var favorites: FavoritesStore

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var pendingDrop: CLLocationCoordinate2D?
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var fixCount = 0
    @State private var shown = false
    @State private var showingFavorites = false
    @State private var showingSearch = false
    /// Point à partager (feuille QR + lien). Enveloppé pour `.sheet(item:)`.
    @State private var sharePoint: SharePoint?
    /// Demande l'autorisation « à l'utilisation » pour afficher le point bleu
    /// de la position réelle. Aucun délégué : MapKit gère l'affichage.
    @State private var locationAuth = CLLocationManager()

    // ── Itinéraire ────────────────────────────────────────────────────────
    @State private var routeDestination: CLLocationCoordinate2D?
    @State private var routeDestinationName: String?
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
        .onAppear {
            shown = true
            // Déclenche l'invite de localisation une fois, pour que le point réel
            // s'affiche. Sans autorisation, MapKit n'affiche simplement rien.
            if locationAuth.authorizationStatus == .notDetermined {
                locationAuth.requestWhenInUseAuthorization()
            }
        }
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
        .sheet(isPresented: $showingFavorites) {
            FavoritesSheet(store: favorites, currentFix: engine.currentFix) { coordinate in
                Task { await activate(at: coordinate) }
                fixCount += 1
                showingFavorites = false
            }
        }
        .sheet(isPresented: $showingSearch) {
            SearchSheet(region: searchRegion, routing: routeMode) { name, coordinate in
                selectSearchResult(name: name, coordinate: coordinate)
            }
        }
        .sheet(item: $sharePoint) { point in
            LocationShareSheet(coordinate: point.coordinate)
                .presentationDetents([.medium, .large])
                .presentationBackground(PX.Color.abyss)
        }
        // Un lien parallax://locate ouvert depuis le web ou un ami : on vise le
        // point et on propose de le poser (confirmation, pas de téléportation
        // silencieuse). Consommé par onChange quand la carte est déjà à l'écran,
        // par onAppear quand le lien a fait basculer sur cet onglet.
        .onChange(of: engine.pendingShare) { _, _ in consumePendingShare() }
        .onAppear { consumePendingShare() }
        // Le fix acquis se sent avant de se voir.
        .sensoryFeedback(.success, trigger: fixCount)
    }

    /// Vise le point d'un lien reçu et le prépare à être posé.
    private func consumePendingShare() {
        guard let point = engine.pendingShare else { return }
        engine.pendingShare = nil
        withAnimation(PX.Motion.settle) {
            camera = .region(MKCoordinateRegion(
                center: point.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
            pendingDrop = point.coordinate
        }
    }

    /// Biais de recherche autour de la position simulée si on en a une, pour que
    /// « café » trouve d'abord celui d'à côté et non à l'autre bout du monde.
    private var searchRegion: MKCoordinateRegion? {
        guard let fix = engine.currentFix else { return nil }
        return MKCoordinateRegion(center: fix,
                                  span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4))
    }

    /// Résultat de recherche choisi : en mode trajet il devient l'arrivée, sinon
    /// il prépare une téléportation (mêmes gestes que sur la carte).
    private func selectSearchResult(name: String, coordinate: CLLocationCoordinate2D) {
        showingSearch = false
        withAnimation(PX.Motion.settle) {
            camera = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
        if routeMode {
            routeDestination = coordinate
            routeDestinationName = name
            recomputeRoute()
        } else {
            withAnimation(PX.Motion.tap) { pendingDrop = coordinate }
        }
    }

    // MARK: - Carte

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                // Le point bleu système : la position réelle de l'appareil, pour
                // savoir d'où l'on part avant de mentir. Quand le spoof est actif,
                // le marqueur ambre prend le dessus, juste au-dessus.
                UserAnnotation()

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
            // Pas de `.mapControls` : les boutons système se calent dans le coin
            // haut-droit de la carte, et comme elle déborde sous la barre d'état
            // (ignoresSafeArea .top), ils venaient chevaucher l'heure et la
            // batterie. On recentre depuis la barre d'outils, en zone sûre.
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                // Deux intentions, deux comportements : en mode trajet on pose
                // une arrivée, sinon on téléporte. Mélanger les deux sur le même
                // geste rendrait chaque appui ambigu.
                if routeMode {
                    withAnimation(PX.Motion.tap) {
                        routeDestination = coordinate; routeDestinationName = nil
                    }
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
                        routeDestination = nil; routeDestinationName = nil; routeError = nil
                    }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PX.Color.inkFaint)
            }

            // Arrivée : recherche d'adresse (barre de recherche) ou appui sur la
            // carte. La recherche donne l'adresse exacte, la carte le geste rapide.
            Button { showingSearch = true } label: {
                HStack(spacing: PX.Space.tight) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PX.Color.azimuth)
                    Text(destinationLabel)
                        .font(PX.Font.body(13))
                        .foregroundStyle(hasDestination ? PX.Color.ink : PX.Color.inkFaint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PX.Color.inkFaint)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, PX.Space.base)
                .background(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .fill(PX.Color.night.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .strokeBorder(PX.Color.horizon, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

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
                     ? "Recherche une adresse ou touche la carte pour poser l'arrivée."
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

    private var hasDestination: Bool { routeDestination != nil }
    private var destinationLabel: String {
        if let name = routeDestinationName { return name }
        if routeDestination != nil { return "Point posé sur la carte" }
        return "Rechercher une adresse…"
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

    /// Un trajet en cours n'est plus une carte figée avec un seul bouton stop :
    /// on voit où on en est, on met en pause, on reboucle. La barre d'avancement
    /// est en ambre — c'est la seule couleur qui a le droit d'exister ici, et le
    /// trajet EST une position simulée active.
    private func trackCard(_ track: GPXTrack) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack(spacing: PX.Space.snug) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(PX.Color.signal)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(PX.Font.display(13.5, .semibold))
                        .foregroundStyle(PX.Color.ink)
                        .lineLimit(1)
                    Text("\(track.points.count) points · \(Int(track.duration)) s")
                        .font(PX.Font.mono(11))
                        .foregroundStyle(PX.Color.inkMuted)
                }

                Spacer(minLength: 0)

                if engine.trackPaused {
                    Text("EN PAUSE")
                        .font(PX.Font.mono(9, .semibold))
                        .tracking(0.8)
                        .foregroundStyle(PX.Color.inkFaint)
                        .transition(.opacity)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PX.Color.night.opacity(0.55))
                    Capsule()
                        .fill(PX.Color.signal)
                        .frame(width: geometry.size.width * CGFloat(engine.trackProgress))
                        .signalGlow(true, radius: 8)
                }
            }
            .frame(height: 4)
            .animation(PX.Motion.settle, value: engine.trackProgress)

            HStack(spacing: PX.Space.tight) {
                trackControl(icon: "repeat", label: "Boucle", active: engine.loopTrack) {
                    withAnimation(PX.Motion.tap) { engine.loopTrack.toggle() }
                }
                trackControl(
                    icon: engine.trackPaused ? "play.fill" : "pause.fill",
                    label: engine.trackPaused ? "Reprendre" : "Pause",
                    active: false
                ) {
                    withAnimation(PX.Motion.tap) {
                        if engine.trackPaused { engine.resumeTrack() } else { engine.pauseTrack() }
                    }
                }
                trackControl(icon: "stop.fill", label: "Arrêter", active: false,
                             tint: PX.Color.alert) {
                    engine.stopTrack()
                }
            }
        }
        .padding(PX.Space.base)
        .glassCard()
        .sensoryFeedback(.selection, trigger: engine.trackPaused)
    }

    /// Pastille de contrôle de lecture. Neutre au repos, teintée quand elle
    /// porte un état actif (la boucle) ou un avertissement (l'arrêt).
    private func trackControl(
        icon: String, label: String, active: Bool,
        tint: Color = PX.Color.azimuth, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(PX.Font.display(12, .semibold))
            }
            .foregroundStyle(active ? tint : PX.Color.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.4) : PX.Color.horizon, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            // Style de carte : un menu compact plutôt que trois pastilles texte,
            // qui mangeaient la largeur et repoussaient les boutons de droite
            // hors du cadre sur les petits écrans.
            Menu {
                Picker("Style", selection: $style) {
                    ForEach(MapStyleChoice.allCases, id: \.self) { choice in
                        Label(choice.label, systemImage: choice.icon).tag(choice)
                    }
                }

                Divider()

                // Mode furtif : bruit GPS réaliste sur un point fixe.
                Toggle(isOn: $engine.stealthMode) {
                    Label("Mode furtif", systemImage: "waveform.path.ecg")
                }

                // Partager la position simulée courante (QR + lien parallax://).
                if let fix = engine.currentFix {
                    Button {
                        sharePoint = SharePoint(coordinate: fix)
                    } label: {
                        Label("Partager ce point", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                toolbarIcon(style.icon, tint: PX.Color.ink)
            }

            Spacer(minLength: 0)

            Button { showingSearch = true } label: { toolbarIcon("magnifyingglass") }
                .buttonStyle(.plain)

            // Recentrer sur la position réelle de l'appareil. Remplace le bouton
            // système de MapKit, qui débordait sous la barre d'état.
            Button {
                withAnimation(PX.Motion.settle) {
                    camera = .userLocation(fallback: .automatic)
                }
            } label: { toolbarIcon("location.fill") }
            .buttonStyle(.plain)

            // Un trajet part de la position simulée : le bouton n'apparaît
            // qu'une fois un point posé.
            if engine.currentFix != nil {
                Button {
                    withAnimation(PX.Motion.settle) {
                        routeMode.toggle()
                        if !routeMode {
                            routePlan = nil; routeDestination = nil; routeDestinationName = nil
                        }
                    }
                } label: {
                    toolbarIcon(routeMode
                                ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                                : "point.topleft.down.to.point.bottomright.curvepath",
                                tint: routeMode ? PX.Color.azimuth : PX.Color.inkMuted)
                }
                .buttonStyle(.plain)
            }

            Button { showingFavorites = true } label: {
                toolbarIcon(favorites.places.isEmpty ? "star" : "star.fill",
                            tint: favorites.places.isEmpty ? PX.Color.inkMuted : PX.Color.azimuth)
            }
            .buttonStyle(.plain)

            Button { showingImporter = true } label: { toolbarIcon("arrow.down.doc") }
                .buttonStyle(.plain)

            if engine.state != .idle {
                Button { Task { await engine.stop() } } label: {
                    toolbarIcon("xmark.circle.fill", tint: PX.Color.alert)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PX.Space.tight)
        .padding(.vertical, 5)
        .glassCard(radius: PX.Radius.control)
        .padding(.horizontal, PX.Space.base)
    }

    /// Icône de barre d'outils à gabarit fixe : toutes identiques, régulièrement
    /// espacées, aucune ne colle au bord — c'est ce qui manquait au bouton de
    /// droite qui débordait selon les dimensions de l'écran.
    private func toolbarIcon(_ name: String, tint: Color = PX.Color.inkMuted) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
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

// MARK: - Favoris

/// Le carnet de lieux. On enregistre la position courante, on rappelle un lieu
/// d'un geste. Construit en verre plutôt qu'en `List` système : une liste native
/// jurerait avec le reste, et un rappel n'a pas besoin de swipe — un bouton
/// explicite est plus clair au pouce.
private struct FavoritesSheet: View {
    @ObservedObject var store: FavoritesStore
    let currentFix: CLLocationCoordinate2D?
    let onSelect: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @FocusState private var naming: Bool

    var body: some View {
        ZStack {
            PX.Color.canvas
            ScrollView {
                VStack(alignment: .leading, spacing: PX.Space.snug) {
                    header
                    if currentFix != nil { saveCard }
                    if store.places.isEmpty {
                        emptyState
                    } else {
                        SectionLabel("Enregistrés")
                            .padding(.top, PX.Space.tight)
                        ForEach(store.places) { placeRow($0) }
                    }
                }
                .padding(PX.Space.base)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.clear)
        .presentationCornerRadius(PX.Radius.sheet)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lieux")
                    .font(PX.Font.display(24, .heavy))
                    .foregroundStyle(PX.Color.ink)
                Text("Enregistre une position, retrouve-la d'un geste.")
                    .font(PX.Font.body(12.5))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PX.Color.inkMuted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Position actuelle")
            if let fix = currentFix {
                Text(String(format: "%+.5f · %+.5f", fix.latitude, fix.longitude))
                    .font(PX.Font.mono(12.5))
                    .foregroundStyle(PX.Color.signal)
            }
            TextField("", text: $newName)
                .focused($naming)
                .field("Nom du lieu")
            Button {
                guard let fix = currentFix else { return }
                store.add(name: newName, coordinate: fix)
                newName = ""
                naming = false
            } label: {
                Text("Enregistrer ici")
            }
            .buttonStyle(ProminentButtonStyle())
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
    }

    private func placeRow(_ place: FavoritesStore.Place) -> some View {
        HStack(spacing: PX.Space.snug) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(PX.Color.azimuth)

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(PX.Font.display(14, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                Text(place.coordinateLabel)
                    .font(PX.Font.mono(11))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer(minLength: 0)

            Button { store.remove(place) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(PX.Color.inkFaint)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Button { onSelect(place.coordinate) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(PX.Color.azimuth))
                    .shadow(color: PX.Color.azimuth.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(PX.Space.snug)
        .glassCard(radius: PX.Radius.control)
    }

    private var emptyState: some View {
        VStack(spacing: PX.Space.snug) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 30))
                .foregroundStyle(PX.Color.inkFaint)
            Text("Aucun lieu enregistré")
                .font(PX.Font.display(15, .semibold))
                .foregroundStyle(PX.Color.inkMuted)
            Text(currentFix == nil
                 ? "Pose d'abord un point sur la carte, puis reviens l'enregistrer."
                 : "Enregistre la position actuelle ci-dessus.")
                .font(PX.Font.body(12.5))
                .foregroundStyle(PX.Color.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PX.Space.wide)
    }
}

// MARK: - Recherche d'adresse

/// Barre de recherche de lieu. On tape une adresse ou un nom, MapKit renvoie
/// l'adresse exacte et les coordonnées, et on choisit un résultat — comme
/// arrivée d'un trajet, ou comme point de téléportation, selon le contexte.
private struct SearchSheet: View {
    let region: MKCoordinateRegion?
    /// En mode trajet, un résultat devient l'arrivée ; sinon, une téléportation.
    let routing: Bool
    let onSelect: (String, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            PX.Color.canvas
            VStack(alignment: .leading, spacing: PX.Space.snug) {
                header

                TextField("", text: $query)
                    .focused($focused)
                    .field("Adresse ou lieu")
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, new in schedule(new) }
                    .onSubmit { run(query) }

                if searching {
                    HStack(spacing: PX.Space.tight) {
                        ProgressView().tint(PX.Color.azimuth)
                        Text("Recherche…")
                            .font(PX.Font.body(12)).foregroundStyle(PX.Color.inkFaint)
                    }
                }

                ScrollView {
                    VStack(spacing: PX.Space.tight) {
                        ForEach(results, id: \.self) { row($0) }
                    }
                }
            }
            .padding(PX.Space.base)
        }
        .presentationDetents([.large])
        .presentationBackground(.clear)
        .presentationCornerRadius(PX.Radius.sheet)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(routing ? "Destination" : "Aller à")
                    .font(PX.Font.display(24, .heavy))
                    .foregroundStyle(PX.Color.ink)
                Text(routing ? "L'arrivée de ton trajet."
                             : "Cherche un lieu et téléporte-toi.")
                    .font(PX.Font.body(12.5))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PX.Color.inkMuted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ item: MKMapItem) -> some View {
        let coord = item.placemark.coordinate
        return Button {
            onSelect(item.name ?? "Lieu", coord)
        } label: {
            HStack(spacing: PX.Space.snug) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(PX.Color.azimuth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Lieu")
                        .font(PX.Font.display(14, .semibold))
                        .foregroundStyle(PX.Color.ink)
                        .lineLimit(1)
                    Text(Self.address(item))
                        .font(PX.Font.body(12))
                        .foregroundStyle(PX.Color.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PX.Color.inkFaint)
            }
            .padding(PX.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: PX.Radius.control)
        }
        .buttonStyle(.plain)
    }

    private static func address(_ item: MKMapItem) -> String {
        let p = item.placemark
        let parts = [p.thoroughfare, p.locality, p.administrativeArea, p.country]
            .compactMap { $0 }
        guard !parts.isEmpty else {
            return String(format: "%+.5f, %+.5f", p.coordinate.latitude, p.coordinate.longitude)
        }
        return parts.joined(separator: ", ")
    }

    // Débounce : on ne lance pas une requête réseau à chaque frappe.
    private func schedule(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            await perform(trimmed)
        }
    }

    private func run(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searching = true
        searchTask = Task { await perform(trimmed) }
    }

    private func perform(_ q: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region { request.region = region }
        do {
            let response = try await MKLocalSearch(request: request).start()
            if Task.isCancelled { return }
            results = response.mapItems
        } catch {
            if Task.isCancelled { return }
            results = []
        }
        searching = false
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

    var icon: String {
        switch self {
        case .standard: "map"
        case .hybrid: "map.fill"
        case .imagery: "globe.americas.fill"
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
