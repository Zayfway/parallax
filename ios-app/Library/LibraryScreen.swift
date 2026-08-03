import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET BIBLIOTHÈQUE
//
// Le pendant de « Installer » : ce qui est **déjà** sur l'appareil. On interroge
// `installation_proxy` par le tunnel (le même lien que pour installer), on liste
// les apps utilisateur, et on peut en **désinstaller** d'un geste.
//
// Même grammaire que les autres écrans : grand titre, un seul élément coloré qui
// porte l'état (ici le manque de lien), cartes en verre, cascade.
// ═══════════════════════════════════════════════════════════════════════════

struct LibraryScreen: View {

    @EnvironmentObject private var connection: DeviceConnection

    @State private var apps: [InstalledApp] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var pendingUninstall: InstalledApp?
    @State private var busyID: String?
    @State private var shown = false

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    ScreenHeader("Bibliothèque", "Les apps installées sur ton appareil.") {
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(PX.Color.azimuth)
                                .padding(PX.Space.tight)
                                .background(Circle().fill(PX.Color.azimuth.opacity(0.14)))
                        }
                        .disabled(loading || connection.tunnelPointer == nil)
                        .opacity(loading ? 0.4 : 1)
                    }
                    .appear(0, shown)

                    content
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear {
            shown = true
            if apps.isEmpty { Task { await load() } }
        }
        .animation(PX.Motion.settle, value: apps)
        .animation(PX.Motion.settle, value: loading)
        .confirmationDialog(
            "Désinstaller cette app ?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUninstall
        ) { app in
            Button("Désinstaller \(app.name)", role: .destructive) {
                let target = app
                pendingUninstall = nil
                Task { await uninstall(target) }
            }
            Button("Annuler", role: .cancel) { pendingUninstall = nil }
        } message: { app in
            Text("\(app.name) et toutes ses données seront supprimées de l'appareil.")
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if connection.tunnelPointer == nil {
            banner(icon: "link.badge.plus", tint: PX.Color.inkFaint,
                   title: "Lien requis",
                   detail: "Établis le lien dans l'onglet Jumelage pour lister les apps.")
                .appear(1, shown)
        } else if let failure {
            banner(icon: "exclamationmark.triangle.fill", tint: PX.Color.alert,
                   title: "Échec", detail: failure)
                .appear(1, shown)
        } else if loading && apps.isEmpty {
            loadingCard.appear(1, shown)
        } else if apps.isEmpty {
            banner(icon: "app.dashed", tint: PX.Color.inkFaint,
                   title: "Aucune app listée",
                   detail: "Installe une app depuis l'onglet Installer.")
                .appear(1, shown)
        } else {
            HStack {
                SectionLabel("\(apps.count) app\(apps.count > 1 ? "s" : "")")
                Spacer()
            }
            .appear(1, shown)

            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    appRow(app)
                    if index < apps.count - 1 {
                        Divider().overlay(PX.Color.horizon).padding(.leading, 56)
                    }
                }
            }
            .glassCard()
            .appear(2, shown)
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: "app.fill", size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(PX.Font.mono(10.5))
                    .foregroundStyle(PX.Color.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PX.Space.tight)

            if !app.version.isEmpty {
                Text("v\(app.version)")
                    .font(PX.Font.mono(10.5, .medium))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Button {
                pendingUninstall = app
            } label: {
                if busyID == app.bundleId {
                    ProgressView().tint(PX.Color.inkMuted)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(PX.Color.alert)
                }
            }
            .buttonStyle(.plain)
            .disabled(busyID != nil)
            .padding(.leading, PX.Space.hair)
        }
        .padding(PX.Space.base)
    }

    private func banner(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text(detail)
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.34), lineWidth: 1)
        )
    }

    private var loadingCard: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Lecture des apps installées…")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    // MARK: - Actions

    private func load() async {
        guard !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            try await connection.connect()
            guard let tunnel = connection.tunnelPointer else {
                failure = "Lien indisponible. Passe par l'onglet Jumelage."
                return
            }
            let list = try await onBackground { try FFI.listApps(tunnel: tunnel) }
            withAnimation(PX.Motion.settle) { apps = list }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func uninstall(_ app: InstalledApp) async {
        guard let tunnel = connection.tunnelPointer, busyID == nil else { return }
        busyID = app.bundleId
        defer { busyID = nil }
        do {
            try await onBackground { try FFI.uninstallApp(tunnel: tunnel, bundleID: app.bundleId) }
            withAnimation(PX.Motion.settle) { apps.removeAll { $0.id == app.id } }
            LogBridge.shared.note("app désinstallée : \(app.bundleId)")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Sort l'appel FFI bloquant du pool coopératif.
    private func onBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
