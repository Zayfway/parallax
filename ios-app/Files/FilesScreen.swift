import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET FICHIERS
//
// L'espace **Média** de l'appareil (photos DCIM, téléchargements, fichiers…),
// par AFC, sur le tunnel qu'on a déjà. On navigue, on télécharge/partage, on
// importe, on supprime, on crée des dossiers. Pas le système complet ni les
// conteneurs d'apps (ça, ce serait house_arrest) — l'espace Média, qui est déjà
// là où vivent tes vrais fichiers.
// ═══════════════════════════════════════════════════════════════════════════

struct FilesScreen: View {

    @EnvironmentObject private var connection: DeviceConnection

    /// Composants de chemin sous la racine. Chemin courant = "/" + joint.
    @State private var path: [String] = []
    @State private var entries: [DeviceFile] = []
    @State private var storage: DeviceStorage?
    @State private var loading = false
    @State private var busy = false
    @State private var failure: String?
    @State private var shown = false

    @State private var pendingDelete: DeviceFile?
    @State private var fileMenu: DeviceFile?
    @State private var share: ShareItem?
    @State private var preview: ShareItem?
    @State private var query = ""
    @State private var sort: FileSort = .name
    @State private var renaming: DeviceFile?
    @State private var renameText = ""

    /// Tri de la liste. Les dossiers restent toujours groupés en tête.
    private enum FileSort: String, CaseIterable {
        case name = "Nom"
        case size = "Taille"
        case kind = "Type"
    }
    @State private var showingUpload = false
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    private var currentPath: String {
        path.isEmpty ? "/" : "/" + path.joined(separator: "/")
    }

    /// Entrées après recherche et tri — dossiers toujours en tête.
    private var displayed: [DeviceFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? entries : entries.filter { $0.name.lowercased().contains(q) }
        return base.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }   // dossiers d'abord
            switch sort {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: return a.size > b.size
            case .kind:
                let ea = (a.name as NSString).pathExtension.lowercased()
                let eb = (b.name as NSString).pathExtension.lowercased()
                return ea == eb
                    ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    : ea < eb
            }
        }
    }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    ScreenHeader("Fichiers", "L'espace Média de ton appareil.") {
                        headerMenu
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
            if entries.isEmpty { Task { await load() } }
        }
        .animation(PX.Motion.settle, value: entries)
        .animation(PX.Motion.settle, value: loading)
        .animation(PX.Motion.settle, value: query)
        .animation(PX.Motion.settle, value: sort)
        .sheet(isPresented: $showingUpload) {
            DocumentPicker(contentTypes: [.item, .data], allowsMultiple: false, asCopy: true) { urls in
                showingUpload = false
                if let src = urls.first { Task { await upload(src) } }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
        .sheet(item: $preview) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .alert("Nouveau dossier", isPresented: $showingNewFolder) {
            TextField("Nom", text: $newFolderName)
            Button("Créer") { Task { await createFolder() } }
            Button("Annuler", role: .cancel) { newFolderName = "" }
        }
        .confirmationDialog(
            fileMenu?.name ?? "",
            isPresented: Binding(get: { fileMenu != nil }, set: { if !$0 { fileMenu = nil } }),
            titleVisibility: .visible,
            presenting: fileMenu
        ) { file in
            Button("Aperçu") {
                let f = file; fileMenu = nil; Task { await previewFile(f) }
            }
            Button("Télécharger et partager") {
                let f = file; fileMenu = nil; Task { await shareFile(f) }
            }
            Button("Renommer") {
                renameText = file.name; renaming = file; fileMenu = nil
            }
            Button("Supprimer", role: .destructive) {
                pendingDelete = file; fileMenu = nil
            }
            Button("Annuler", role: .cancel) { fileMenu = nil }
        }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { if let f = renaming { renaming = nil; Task { await rename(f, to: renameText) } } }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Supprimer ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { file in
            Button("Supprimer \(file.name)", role: .destructive) {
                let f = file; pendingDelete = nil; Task { await delete(f) }
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        }
    }

    private var headerMenu: some View {
        Menu {
            Button { showingUpload = true } label: { Label("Importer un fichier", systemImage: "square.and.arrow.up") }
            Button { newFolderName = ""; showingNewFolder = true } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }
            Picker("Trier par", selection: $sort) {
                ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Button { Task { await load() } } label: { Label("Rafraîchir", systemImage: "arrow.clockwise") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PX.Color.azimuth)
        }
        .disabled(connection.tunnelPointer == nil || busy)
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if connection.tunnelPointer == nil {
            banner("link.badge.plus", PX.Color.inkFaint, "Lien requis",
                   "Établis le lien dans l'onglet Jumelage pour parcourir les fichiers.")
                .appear(1, shown)
        } else {
            breadcrumb.appear(1, shown)

            if let storage {
                storageBar(storage).appear(2, shown)
            }

            if let failure {
                banner("exclamationmark.triangle.fill", PX.Color.alert, "Échec", failure)
                    .appear(3, shown)
            } else if loading && entries.isEmpty {
                loadingCard.appear(3, shown)
            } else if entries.isEmpty {
                banner("folder", PX.Color.inkFaint, "Dossier vide", "Rien ici.")
                    .appear(3, shown)
            } else {
                if entries.count > 6 { searchField.appear(3, shown) }
                let items = displayed
                if items.isEmpty {
                    banner("magnifyingglass", PX.Color.inkFaint, "Aucun résultat",
                           "Rien ne correspond à « \(query) ».").appear(4, shown)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, file in
                            row(file)
                            if index < items.count - 1 {
                                Divider().overlay(PX.Color.horizon).padding(.leading, 52)
                            }
                        }
                    }
                    .glassCard()
                    .appear(4, shown)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: PX.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PX.Color.inkFaint)
            TextField("Filtrer ce dossier", text: $query)
                .font(PX.Font.body(15))
                .foregroundStyle(PX.Color.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(PX.Color.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .glassCard()
    }

    private var breadcrumb: some View {
        HStack(spacing: PX.Space.tight) {
            Button {
                if !path.isEmpty { path.removeLast(); Task { await load() } }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(path.isEmpty ? PX.Color.inkFaint : PX.Color.azimuth)
            }
            .buttonStyle(.plain)
            .disabled(path.isEmpty)

            Text(currentPath)
                .font(PX.Font.mono(11.5))
                .foregroundStyle(PX.Color.inkMuted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if busy { ProgressView().tint(PX.Color.azimuth).scaleEffect(0.8) }
        }
        .padding(.horizontal, PX.Space.snug)
    }

    private func storageBar(_ s: DeviceStorage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(s.model.isEmpty ? "Stockage" : s.model)
                Spacer()
                Text("\(sizeText(s.freeBytes)) libres · \(sizeText(s.totalBytes))")
                    .font(PX.Font.mono(10.5))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PX.Color.night.opacity(0.55))
                    Capsule().fill(PX.Color.azimuth)
                        .frame(width: geo.size.width * usedFraction(s))
                }
            }
            .frame(height: 4)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func row(_ file: DeviceFile) -> some View {
        Button {
            if file.isDir {
                path.append(file.name)
                Task { await load() }
            } else {
                fileMenu = file
            }
        } label: {
            HStack(spacing: PX.Space.snug) {
                IconTile(system: icon(for: file), tint: file.isDir ? PX.Color.azimuth : PX.Color.inkMuted, size: 34)
                Text(file.name)
                    .font(PX.Font.display(14, .medium))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PX.Space.tight)
                if file.isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PX.Color.inkFaint)
                } else if !file.sizeText.isEmpty {
                    Text(file.sizeText)
                        .font(PX.Font.mono(10.5))
                        .foregroundStyle(PX.Color.inkFaint)
                }
            }
            .padding(.horizontal, PX.Space.base)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var loadingCard: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Lecture du dossier…").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    // MARK: - Helpers

    private func icon(for file: DeviceFile) -> String {
        if file.isDir { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mov", "mp4", "m4v", "avi": return "film"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "zip", "gz", "tar", "7z", "rar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "txt", "log", "json", "xml", "plist": return "doc.text"
        default: return "doc"
        }
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func usedFraction(_ s: DeviceStorage) -> CGFloat {
        guard s.totalBytes > 0 else { return 0 }
        return CGFloat(s.usedBytes) / CGFloat(s.totalBytes)
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
            let dir = currentPath
            let list = try await onBackground { try FFI.listFiles(tunnel: tunnel, path: dir) }
            withAnimation(PX.Motion.settle) { entries = list }
            if storage == nil {
                storage = await onBackgroundOptional { FFI.storageInfo(tunnel: tunnel) }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func shareFile(_ file: DeviceFile) async {
        guard let tunnel = connection.tunnelPointer, !busy else { return }
        busy = true
        defer { busy = false }
        let dest = URL.temporaryDirectory.appending(path: file.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try await onBackground { try FFI.downloadFile(tunnel: tunnel, remote: file.path, dest: dest.path) }
            share = ShareItem(url: dest)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func previewFile(_ file: DeviceFile) async {
        guard let tunnel = connection.tunnelPointer, !busy else { return }
        busy = true
        defer { busy = false }
        let dest = URL.temporaryDirectory.appending(path: file.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try await onBackground { try FFI.downloadFile(tunnel: tunnel, remote: file.path, dest: dest.path) }
            preview = ShareItem(url: dest)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete(_ file: DeviceFile) async {
        guard let tunnel = connection.tunnelPointer, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await onBackground { try FFI.deleteFile(tunnel: tunnel, path: file.path) }
            withAnimation(PX.Motion.settle) { entries.removeAll { $0.id == file.id } }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func rename(_ file: DeviceFile, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard let tunnel = connection.tunnelPointer, !busy,
              !clean.isEmpty, clean != file.name, !clean.contains("/") else { return }
        busy = true
        defer { busy = false }
        let target = currentPath == "/" ? "/\(clean)" : "\(currentPath)/\(clean)"
        do {
            try await onBackground { try FFI.renameFile(tunnel: tunnel, from: file.path, to: target) }
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard let tunnel = connection.tunnelPointer, !name.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let target = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
        do {
            try await onBackground { try FFI.makeDir(tunnel: tunnel, path: target) }
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func upload(_ src: URL) async {
        guard let tunnel = connection.tunnelPointer, !busy else { return }
        busy = true
        defer { busy = false }
        // Copie locale d'abord (le fichier du picker est déjà dans le bac à sable
        // grâce à asCopy, mais on fige un chemin propre).
        let local = URL.temporaryDirectory.appending(path: src.lastPathComponent)
        try? FileManager.default.removeItem(at: local)
        do {
            try FileManager.default.copyItem(at: src, to: local)
            let name = src.lastPathComponent
            let target = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
            try await onBackground { try FFI.uploadFile(tunnel: tunnel, local: local.path, remote: target) }
            await load()
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

    private func onBackgroundOptional<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
        }
    }
}

/// Élément à partager (fichier téléchargé).
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Feuille de partage système (UIActivityViewController).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Aperçu natif d'un fichier (QuickLook) — photos, PDF, texte, vidéos…
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
