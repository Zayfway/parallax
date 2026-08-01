import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

struct MapScreen: View {

    @EnvironmentObject private var engine: LocationEngine

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var pendingDrop: CLLocationCoordinate2D?
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $camera) {
                    if let fix = engine.currentFix {
                        Annotation("Position simulée", coordinate: fix) {
                            SimulatedPin(active: engine.state == .simulating)
                        }
                    }
                    if let pending = pendingDrop {
                        Annotation("Nouveau point", coordinate: pending) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .mapStyle(style.mapStyle)
                .onTapGesture { screenPoint in
                    if let coord = proxy.convert(screenPoint, from: .local) {
                        pendingDrop = coord
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 12) {
                if let pending = pendingDrop {
                    DropConfirmation(coordinate: pending) {
                        Task { await activate(at: pending) }
                        pendingDrop = nil
                    } cancel: {
                        pendingDrop = nil
                    }
                }

                if engine.state == .simulating || isDegraded {
                    Joystick { bearing, speed in
                        engine.joystick(bearingDegrees: bearing, metersPerSecond: speed)
                    }
                }

                StatusBar(state: engine.state)
            }
            .padding()
        }
        .safeAreaInset(edge: .top) { toolbar }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]
        ) { result in
            handleImport(result)
        }
        .alert("Import GPX", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var isDegraded: Bool {
        if case .degraded = engine.state { return true }
        return false
    }

    private var toolbar: some View {
        HStack {
            Picker("Style", selection: $style) {
                ForEach(MapStyleChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            Button {
                showingImporter = true
            } label: {
                Label("Importer un GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)

            if engine.state != .idle {
                Button("Arrêter", role: .destructive) {
                    Task { await engine.stop() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Joystick

/// Palet analogique. Le cap vient de l'angle, la vitesse de l'amplitude.
///
/// Trois vitesses discrètes plutôt qu'un continu : à 1 fix/s, un continu produit
/// des écarts de vitesse que le système lisse de toute façon, et le retour
/// discret est bien plus contrôlable au pouce.
private struct Joystick: View {

    let onMove: (_ bearing: Double, _ metersPerSecond: Double) -> Void

    @State private var offset: CGSize = .zero
    @State private var ticker: Timer?

    private let radius: CGFloat = 52
    private let deadzone: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))

            Circle()
                .fill(.tint)
                .frame(width: 44, height: 44)
                .offset(offset)
                .shadow(radius: 4, y: 2)
        }
        .frame(width: radius * 2, height: radius * 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let raw = value.translation
                    let magnitude = min(hypot(raw.width, raw.height), radius)
                    let angle = atan2(raw.width, -raw.height)
                    offset = CGSize(
                        width: sin(angle) * magnitude,
                        height: -cos(angle) * magnitude
                    )
                    startTicking()
                }
                .onEnded { _ in
                    offset = .zero
                    ticker?.invalidate()
                    ticker = nil
                }
        )
        .accessibilityLabel("Joystick de déplacement")
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let magnitude = hypot(offset.width, offset.height)
            guard magnitude > deadzone else { return }

            var bearing = atan2(offset.width, -offset.height) * 180 / .pi
            if bearing < 0 { bearing += 360 }

            // Marche · course · véhicule
            let speed: Double = switch magnitude / radius {
            case ..<0.4: 1.4
            case ..<0.75: 4.5
            default: 13.0
            }
            onMove(bearing, speed)
        }
    }
}

// MARK: - Éléments d'état

private struct SimulatedPin: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? .blue : .gray)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 3)
    }
}

private struct DropConfirmation: View {
    let coordinate: CLLocationCoordinate2D
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Se téléporter ici")
                    .font(.subheadline.weight(.medium))
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Annuler", action: cancel).buttonStyle(.bordered)
            Button("Y aller", action: confirm).buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Barre d'état. Un état dégradé se dit franchement : pendant la reprise, la
/// vraie position est visible des autres apps, et masquer ce fait derrière un
/// spinner neutre ferait prendre à l'utilisateur des décisions qu'il regretterait.
private struct StatusBar: View {
    let state: LocationEngine.State

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(message).font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var color: Color {
        switch state {
        case .simulating: .green
        case .degraded, .waitingForWiFi: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var message: String {
        switch state {
        case .idle: "Touche la carte pour choisir un point."
        case .mountingDDI: "Montage de l'image développeur…"
        case .connecting: "Ouverture du canal…"
        case .simulating: "Position simulée active."
        case .degraded(let n): "Canal perdu — position réelle visible. Reprise (essai \(n))…"
        case .waitingForWiFi: "Position réelle visible. Repasse en Wi-Fi pour reprendre."
        case .failed(let why): why
        }
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
