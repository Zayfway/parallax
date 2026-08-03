import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// SOURCES — modèle & chargement
//
// Le format lu est celui d'AltStore / SideStore. On reste tolérant : les
// sources réelles ont des champs en trop, parfois une entrée d'app malformée —
// une seule ne doit pas faire tomber tout le catalogue. D'où le décodage
// « lossy » de `apps[]`, qui saute l'élément fautif au lieu de tout rejeter.
// ═══════════════════════════════════════════════════════════════════════════

/// Une source = un JSON qui liste des apps.
struct AppSource: Decodable, Equatable {
    var name: String?
    var identifier: String?
    var subtitle: String?
    var apps: [SourceApp]

    private enum CodingKeys: String, CodingKey { case name, identifier, subtitle, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)

        var collected: [SourceApp] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .apps) {
            while !array.isAtEnd {
                if let app = try? array.decode(SourceApp.self) {
                    collected.append(app)
                } else {
                    // L'élément a échoué : on le consomme quand même pour avancer
                    // le curseur, sinon boucle infinie.
                    _ = try? array.decode(Discard.self)
                }
            }
        }
        apps = collected
    }
}

/// Décodable qui absorbe n'importe quelle valeur sans rien lire — sert à sauter
/// un élément fautif dans un conteneur non-clé.
private struct Discard: Decodable { init(from decoder: Decoder) throws {} }

/// Une app dans une source. Beaucoup de champs sont optionnels : les sources
/// varient, et l'app hérité (`downloadURL` à plat) coexiste avec le récent
/// (`versions[]`).
struct SourceApp: Decodable, Equatable, Identifiable {
    var name: String
    var bundleIdentifier: String
    var developerName: String?
    var subtitle: String?
    var localizedDescription: String?
    var iconURL: String?
    var tintColor: String?
    var category: String?
    var size: Int?
    var version: String?
    var versionDate: String?
    var downloadURL: String?
    var versions: [SourceVersion]?

    var id: String { bundleIdentifier.isEmpty ? name : bundleIdentifier }

    // La forme récente met tout dans `versions[0]` ; l'ancienne à plat. On
    // résout vers l'une puis l'autre, dans cet ordre.
    var resolvedVersion: String? { versions?.first?.version ?? version }
    var resolvedDownloadURL: String? { versions?.first?.downloadURL ?? downloadURL }
    var resolvedSize: Int? { versions?.first?.size ?? size }
    var resolvedDescription: String? { versions?.first?.localizedDescription ?? localizedDescription }
    var resolvedDate: String? {
        let raw = versions?.first?.date ?? versionDate
        return raw.map { String($0.prefix(10)) }   // yyyy-MM-dd, sans l'heure
    }
    var resolvedSizeText: String? {
        guard let s = resolvedSize, s > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
    }

    /// Teinte d'accent de l'app (`tintColor` hex), repli pervenche.
    var accent: Color {
        guard let hex = tintColor, let value = SourceApp.parseHex(hex) else { return PX.Color.azimuth }
        return Color(hex: value)
    }

    static func parseHex(_ string: String) -> UInt32? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }
}

struct SourceVersion: Decodable, Equatable {
    var version: String?
    var date: String?
    var downloadURL: String?
    var size: Int?
    var localizedDescription: String?
}

// MARK: - Store

/// Gère la liste des sources (persistée) et leur chargement réseau.
@MainActor
final class SourceStore: ObservableObject {

    struct Feed: Identifiable, Equatable {
        let url: String
        var source: AppSource?
        var error: String?
        var id: String { url }
    }

    /// URLs des sources ajoutées, persistées entre les lancements.
    @Published private(set) var urls: [String]
    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var loading = false

    private let key = "px.sources.urls"

    /// Sources suggérées dans l'état vide — connues, légitimes, open-source.
    static let suggestions: [(name: String, url: String)] = [
        ("AltStore — officiel", "https://apps.altstore.io"),
        ("SideStore", "https://apps.sidestore.io"),
    ]

    init() {
        urls = UserDefaults.standard.stringArray(forKey: "px.sources.urls") ?? []
        feeds = urls.map { Feed(url: $0) }
    }

    func add(_ url: String) {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.lowercased().hasPrefix("http") { u = "https://" + u }
        guard !urls.contains(u) else { return }
        urls.append(u)
        feeds.append(Feed(url: u))
        persist()
        Task { await fetch(u) }
    }

    func remove(_ url: String) {
        urls.removeAll { $0 == url }
        feeds.removeAll { $0.url == url }
        persist()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        // Séquentiel : quelques sources tout au plus, et chaque `fetch` écrit
        // dans `feeds` sur le MainActor — pas de course à gérer.
        for u in urls { await fetch(u) }
    }

    private func fetch(_ url: String) async {
        guard let u = URL(string: url) else {
            update(url) { $0.error = "URL invalide" }
            return
        }
        do {
            var request = URLRequest(url: u)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                update(url) { $0.error = "HTTP \(http.statusCode)"; $0.source = nil }
                return
            }
            let source = try JSONDecoder().decode(AppSource.self, from: data)
            update(url) { $0.source = source; $0.error = nil }
        } catch {
            update(url) { $0.error = error.localizedDescription; $0.source = nil }
        }
    }

    private func update(_ url: String, _ mutate: (inout Feed) -> Void) {
        guard let i = feeds.firstIndex(where: { $0.url == url }) else { return }
        var feed = feeds[i]
        mutate(&feed)
        feeds[i] = feed
    }

    private func persist() {
        UserDefaults.standard.set(urls, forKey: key)
    }
}
