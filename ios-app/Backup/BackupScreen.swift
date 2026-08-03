import SwiftUI
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET SAUVEGARDES
//
// Une signature gratuite expire en 7 jours ; à la réinstallation, iOS efface le
// conteneur de l'app — progression, réglages, fichiers, tout part. Ici on
// archive le conteneur d'une app sideloadée dans un `.zip` (à garder ou à
// partager), et on le réinjecte après coup.
//
// Le natif passe par `house_arrest` (`px_backup_create` / `px_backup_restore`),
// qui donne accès au conteneur via le **même** AFC que l'explorateur Fichiers.
// Ne marche que pour les apps qui l'autorisent (dev / get-task-allow) — donc
// les sideloadées, précisément celles qu'on réinstalle sans cesse.
// ═══════════════════════════════════════════════════════════════════════════

struct BackupScreen: View {

    @EnvironmentObject private var connection: DeviceConnection

    @State private var apps: [InstalledApp] = []
    @State private var loading = false
    @State private var busyID: String?
    @State private var failure: String?
    @State private var status: String?
    @State private var shown = false
    @State private var share: ShareItem?
    @State private var restoreTarget: InstalledApp?
    @State private var showingRestore = false

    private var sideloaded: [InstalledApp] { apps.filter { $0.isSideloaded } }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    ScreenHeader("Sauvegardes", "Protège les données de tes apps.") {
                        if connection.tunnelPointer != nil {
                            Button { Task { await load() } } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(PX.Color.azimuth)
                            }
                            .disabled(busyID != nil || loading)
                        }
                    }
                    .appear(0, shown)

                    content
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
            .refreshable { await load() }
        }
        .onAppear {
            shown = true
            if apps.isEmpty { Task { await load() } }
        }
        .animation(PX.Motion.settle, value: apps)
        .animation(PX.Motion.settle, value: busyID)
        .animation(PX.Motion.settle, value: status)
        .sheet(item: $share) { item in ActivityView(items: [item.url]) }
        .sheet(isPresented: $showingRestore) {
            DocumentPicker(contentTypes: [UTType.zip, .data], allowsMultiple: false, asCopy: true) { urls in
                showingRestore = false
                if let src = urls.first, let app = restoreTarget {
                    Task { await restore(app, from: src) }
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        if connection.tunnelPointer == nil {
            banner("link.badge.plus", PX.Color.inkFaint, "Lien requis",
                   "Établis le lien dans l'onglet Jumelage pour sauvegarder une app.")
                .appear(1, shown)
        } else {
            introCard.appear(1, shown)

            if let status {
                banner("checkmark.circle.fill", PX.Color.verdant, "Terminé", status)
                    .appear(2, shown)
            }
            if let failure {
                banner("exclamationmark.triangle.fill", PX.Color.alert, "Échec", failure)
                    .appear(2, shown)
            }

            if loading && apps.isEmpty {
                loadingCard.appear(3, shown)
            } else if sideloaded.isEmpty {
                banner("app.badge", PX.Color.inkFaint, "Aucune app sideloadée",
                       "Les sauvegardes visent les apps installées hors App Store. Aucune détectée.")
                    .appear(3, shown)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sideloaded.enumerated()), id: \.element.id) { index, app in
                        appRow(app)
                        if index < sideloaded.count - 1 {
                            Divider().overlay(PX.Color.horizon).padding(.leading, 60)
                        }
                    }
                }
                .glassCard()
                .appear(3, shown)
            }
        }
    }

    private var introCard: some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: "externaldrive.badge.timemachine", tint: PX.Color.azimuth)
            VStack(alignment: .leading, spacing: 2) {
                Text("Avant que le certificat n'expire")
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text("Archive le conteneur d'une app dans un .zip, puis restaure-le après réinstallation.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: "app.fill", tint: PX.Color.azimuth, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                Text(app.bundleId)
                    .font(PX.Font.mono(10.5))
                    .foregroundStyle(PX.Color.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: PX.Space.tight)

            if busyID == app.bundleId {
                ProgressView().tint(PX.Color.azimuth)
            } else {
                Menu {
                    Button { Task { await backup(app) } } label: {
                        Label("Sauvegarder", systemImage: "arrow.down.doc")
                    }
                    Button { restoreTarget = app; showingRestore = true } label: {
                        Label("Restaurer depuis un .zip", systemImage: "arrow.up.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PX.Color.azimuth)
                }
                .disabled(busyID != nil)
            }
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
    }

    private var loadingCard: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Lecture des apps…").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func banner(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PX.Font.display(15, .semibold)).foregroundStyle(PX.Color.ink)
                Text(detail).font(PX.Font.body(12)).foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
            .strokeBorder(tint.opacity(0.34), lineWidth: 1))
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

    private func backup(_ app: InstalledApp) async {
        guard let tunnel = connection.tunnelPointer, busyID == nil else { return }
        busyID = app.bundleId
        failure = nil; status = nil
        defer { busyID = nil }
        let safe = app.name.replacingOccurrences(of: "/", with: "-")
        let dest = URL.temporaryDirectory.appending(path: "\(safe)-sauvegarde.zip")
        try? FileManager.default.removeItem(at: dest)
        let bundleID = app.bundleId
        do {
            let result = try await onBackground {
                try FFI.backupCreate(tunnel: tunnel, bundleID: bundleID, dest: dest.path)
            }
            status = "\(app.name) — \(result.summary)"
            LogBridge.shared.note("sauvegarde \(bundleID) : \(result.summary)")
            share = ShareItem(url: dest)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func restore(_ app: InstalledApp, from src: URL) async {
        guard let tunnel = connection.tunnelPointer, busyID == nil else { return }
        busyID = app.bundleId
        failure = nil; status = nil
        defer { busyID = nil; restoreTarget = nil }
        let local = URL.temporaryDirectory.appending(path: "restore-\(src.lastPathComponent)")
        try? FileManager.default.removeItem(at: local)
        let bundleID = app.bundleId
        do {
            try FileManager.default.copyItem(at: src, to: local)
            let files = try await onBackground {
                try FFI.backupRestore(tunnel: tunnel, bundleID: bundleID, src: local.path)
            }
            status = "\(app.name) — \(files == 1 ? "1 fichier restauré" : "\(files) fichiers restaurés")"
            LogBridge.shared.note("restauration \(bundleID) : \(files) fichiers")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func onBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { c.resume(returning: try work()) } catch { c.resume(throwing: error) }
            }
        }
    }
}
