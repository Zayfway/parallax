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
struct MapScreen: View {

    @EnvironmentObject private var engine: LocationEngine

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var pendingDrop: CLLocationCoordinate2D?
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var fixCount = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            overlays
        }
        .safeAreaInset(edge: .top) { toolbar }
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
                if let coordinate = proxy.convert(point, from: .local) {
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
brid: .hybrid(elevation: .realistic)
        case .imagery: .imagery(elevation: .realistic)
        }
    }
}
