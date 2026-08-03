import SwiftUI
import UIKit

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
    @State private var selectedApp: InstalledApp?
    @State private var busyID: String?
    @State private var shown = false
    @State private var filter: AppFilter = .all
    @State private var searchText = ""
    @State private var sortMode: SortMode = .name
    /// Icônes chargées paresseusement (bundleId → image) et ce qui a déjà été
    /// demandé, pour ne pas relancer.
    @State private var icons: [String: UIImage] = [:]
    @State private var iconRequested: Set<String> = []

    /// File **série** : une icône à la fois. L'accès au tunnel n'est pas
    /// concurrent (le cœur natif prête un `&mut` unique de l'adaptateur), donc
    /// on ne lance jamais deux requêtes en parallèle.
    private static let iconQueue = DispatchQueue(label: "io.parallax.icons")

    /// Filtre par provenance : tout, sideloadées (cert/IPA), ou App Store.
    enum AppFilter: String, CaseIterable {
        case all = "Toutes"
        case sideloaded = "Sideloadées"
        case store = "App Store"
    }

    /// Tri de la liste.
    enum SortMode: String, CaseIterable {
        case name = "Nom"
        case size = "Taille"
        var icon: String { self == .name ? "textformat" : "internaldrive" }
    }

    private var filteredApps: [InstalledApp] {
        var list: [InstalledApp]
        switch filter {
        case .all:        list = apps
        case .sideloaded: list = apps.filter { $0.isSideloaded }
        case .store:      list = apps.filter { $0.isStore }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.bundleId.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortMode {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: list.sort { $0.sizeBytes > $1.sizeBytes }
        }
        return list
    }

    /// Espace total occupé par les apps affichées.
    private var totalSize: Int { filteredApps.reduce(0) { $0 + $1.sizeBytes } }

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
            .refreshable { await load() }
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
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app, icon: icons[app.bundleId]) {
                selectedApp = nil
                pendingUninstall = app
            }
            .presentationDetents([.medium])
            .presentationBackground(PX.Color.abyss)
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
            searchBar.appear(1, shown)

            SegmentedRow(selection: $filter, options: AppFilter.allCases) { $0.rawValue }
                .appear(2, shown)

            HStack(spacing: PX.Space.tight) {
                SectionLabel("\(filteredApps.count) app\(filteredApps.count > 1 ? "s" : "")")
                if totalSize > 0 {
                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))")
                        .font(PX.Font.mono(10.5))
                        .foregroundStyle(PX.Color.inkFaint)
                }
                Spacer()
                sortMenu
            }
            .appear(3, shown)

            if filteredApps.isEmpty {
                banner(icon: "line.3.horizontal.decrease.circle", tint: PX.Color.inkFaint,
                       title: "Rien dans ce filtre",
                       detail: "Aucune app \(filter.rawValue.lowercased()) trouvée.")
                    .appear(3, shown)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                        appRow(app)
                        if index < filteredApps.count - 1 {
                            Divider().overlay(PX.Color.horizon).padding(.leading, 56)
                        }
                    }
                }
                .glassCard()
                .appear(3, shown)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: PX.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(PX.Color.inkFaint)
            TextField("Rechercher une app", text: $searchText)
                .font(PX.Font.body(14))
                .foregroundStyle(PX.Color.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(PX.Color.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                .fill(PX.Color.night.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                .strokeBorder(PX.Color.horizon, lineWidth: 1)
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker("Trier", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(sortMode.rawValue)
                    .font(PX.Font.display(11, .semibold))
            }
            .foregroundStyle(PX.Color.azimuth)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(PX.Color.azimuth.opacity(0.14)))
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: PX.Space.snug) {
            appIcon(app)

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

            VStack(alignment: .trailing, spacing: 2) {
                if !app.version.isEmpty {
                    Text("v\(app.version)")
                        .font(PX.Font.mono(10.5, .medium))
                        .foregroundStyle(PX.Color.inkMuted)
                }
                if !app.sizeText.isEmpty {
                    Text(app.sizeText)
                        .font(PX.Font.mono(10))
                        .foregroundStyle(PX.Color.inkFaint)
                }
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
        .contentShape(Rectangle())
        .onTapGesture { selectedApp = app }
    }

    /// Vraie icône de l'app si chargée, tuile générique en attendant.
    private func appIcon(_ app: InstalledApp) -> some View {
        RoundedRectangle(cornerRadius: 40 * 0.28, style: .continuous)
            .fill(PX.Color.azimuth.opacity(icons[app.bundleId] == nil ? 0.16 : 0))
            .frame(width: 40, height: 40)
            .overlay {
                if let img = icons[app.bundleId] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PX.Color.azimuth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 40 * 0.28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 40 * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .onAppear { loadIcon(app) }
    }

    private func loadIcon(_ app: InstalledApp) {
        guard icons[app.bundleId] == nil,
              !iconRequested.contains(app.bundleId),
              let tunnel = connection.tunnelPointer else { return }
        iconRequested.insert(app.bundleId)
        let bundleId = app.bundleId
        Self.iconQueue.async {
            let image = FFI.appIcon(tunnel: tunnel, bundleID: bundleId).flatMap(UIImage.init)
            guard let image else { return }
            DispatchQueue.main.async {
                withAnimation(PX.Motion.settle) { icons[bundleId] = image }
            }
        }
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

/// Fiche détaillée d'une app installée.
private struct AppDetailSheet: View {
    let app: InstalledApp
    let icon: UIImage?
    let onUninstall: () -> Void

    var body: some View {
        VStack(spacing: PX.Space.base) {
            Capsule().fill(PX.Color.horizon).frame(width: 38, height: 5).padding(.top, PX.Space.snug)

            HStack(spacing: PX.Space.base) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        Image(systemName: "app.fill").font(.system(size: 26)).foregroundStyle(PX.Color.azimuth)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 60 * 0.28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 60 * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(PX.Font.display(19, .semibold)).foregroundStyle(PX.Color.ink).lineLimit(1)
                    Tag(app.isStore ? "App Store" : (app.isSideloaded ? "Sideloadée" : "Système"),
                        color: app.isStore ? PX.Color.azimuth : PX.Color.verdant,
                        icon: app.isStore ? "bag.fill" : "square.and.arrow.down.fill")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                detailRow("Identifiant", app.bundleId, mono: true)
                Divider().overlay(PX.Color.horizon)
                detailRow("Version", app.version.isEmpty ? "—" : "\(app.version) (\(app.build))", mono: false)
                Divider().overlay(PX.Color.horizon)
                detailRow("Stockage", app.sizeText.isEmpty ? "—" : app.sizeText, mono: false)
            }
            .padding(PX.Space.base)
            .glassCard()

            Button(role: .destructive) { onUninstall() } label: {
                Label("Désinstaller", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle(tint: PX.Color.alert))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PX.Space.loose)
        .padding(.bottom, PX.Space.loose)
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .top) {
            Text(label).font(PX.Font.body(12.5)).foregroundStyle(PX.Color.inkMuted)
            Spacer(minLength: PX.Space.base)
            Text(value)
                .font(mono ? PX.Font.mono(11.5) : PX.Font.body(12.5))
                .foregroundStyle(PX.Color.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
    }
}
