import SwiftUI
import Foundation
import Network
import Combine

/// Connexion à l'appareil par le tunnel loopback de LocalDevVPN.
///
/// Transport : RPPairing pair-verify sur le loopback Wi-Fi → tunnel TLS-PSK →
/// pile TCP logicielle in-process → handshake RSD → services par-dessus RSD.
/// **La lockdown classique n'est jamais utilisée.**
///
/// La détection du tunnel est faite par inspection des interfaces plutôt que
/// par une simple tentative de connexion : ça permet de distinguer « VPN
/// absent » de « VPN actif mais sur le mauvais sous-réseau », deux pannes qui
/// se soignent différemment et que l'utilisateur ne peut pas distinguer seul.
@MainActor
final class DeviceConnection: ObservableObject {

    enum TunnelState: Equatable {
        case down
        case wrongSubnet(String)
        case connecting
        case connected

        var isConnected: Bool { self == .connected }

        var shortLabel: String {
            switch self {
            case .down:        "TUNNEL · OFF"
            case .wrongSubnet: "TUNNEL · SUBNET"
            case .connecting:  "TUNNEL · …"
            case .connected:   "TUNNEL · OK"
            }
        }
    }

    @Published private(set) var tunnelState: TunnelState = .down
    @Published private(set) var deviceInfo: DeviceInfo?

    /// IP cible. 10.7.0.1 est le défaut de LocalDevVPN ; modifiable dans les
    /// réglages, car certaines configurations réseau l'attribuent autrement.
    @AppStorage("deviceIP") var deviceIP: String = "10.7.0.1"

    /// Port RSD atteint par le VPN loopback. Fixe : ce n'est pas une valeur
    /// annoncée, c'est celle sur laquelle `remoted` écoute côté tunnel.
    static let rsdPort: UInt16 = 49152

    /// Tunnel détenu par Rust. Propriétaire de l'adaptateur, de la poignée RSD
    /// et du runtime qui les pilote — d'où un seul pointeur à libérer.
    private var tunnelHandle: OpaquePointer?

    /// Poignée du tunnel, **empruntée**. Valide tant que `releaseTunnel` n'a
    /// pas été appelé ; ne jamais la libérer depuis l'appelant.
    var tunnelPointer: OpaquePointer? { tunnelHandle }

    /// Adaptateur et poignée RSD, **empruntés** au tunnel. Ils cessent d'être
    /// valides dès que `tunnelHandle` est libéré : jamais de `free` dessus.
    private(set) var adapterHandle: UnsafeMutableRawPointer?
    private(set) var rsdHandle: UnsafeMutableRawPointer?

    /// Services annoncés par RSD. C'est la preuve que le lien est vivant, et
    /// la réponse à « la DDI est-elle montée ? » sans aucun appel réseau.
    @Published private(set) var services: [String: Int] = [:]

    /// Non isolé : voir l'en-tête de `RemotePairingBrowser`.
    private let browser = RemotePairingBrowser()
    private var ddiVerified = false

    struct DeviceInfo: Equatable {
        let productVersion: String
        let productType: String
        let udid: String
    }

    // MARK: - Surveillance du tunnel

    /// Boucle de surveillance. Vérifie l'état toutes les deux secondes plutôt
    /// que de s'abonner à `NWPathMonitor` seul : une interface `ipsec` peut
    /// exister sans que le tunnel soit routable vers l'IP cible.
    func observeTunnel() async {
        while !Task.isCancelled {
            refreshTunnelState()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshTunnelState() {
        let interfaces = Self.activeInterfaces()

        // LocalDevVPN se présente comme utun/ipsec. Sa présence ne suffit
        // pas : il faut une adresse sur le sous-réseau de la cible.
        let tunnelAddresses = interfaces
            .filter { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") }
            .map(\.address)

        guard !tunnelAddresses.isEmpty else {
            if tunnelState != .down { tunnelState = .down }
            return
        }

        let prefix = deviceIP.split(separator: ".").prefix(2).joined(separator: ".")
        if tunnelAddresses.contains(where: { $0.hasPrefix(prefix) }) {
            if tunnelState != .connected { tunnelState = .connected }
        } else {
            let found = tunnelAddresses.joined(separator: ", ")
            if tunnelState != .wrongSubnet(found) { tunnelState = .wrongSubnet(found) }
        }
    }

    /// Interfaces IPv4 actives. Utilisé aussi par l'écran de diagnostic —
    /// afficher `lo0`, `en0` et `ipsec0` d'un coup est ce qui permet à un
    /// utilisateur de comprendre pourquoi son tunnel ne prend pas.
    static func activeInterfaces() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            result.append((String(cString: ptr.pointee.ifa_name), String(cString: host)))
        }
        return result
    }

    // MARK: - Connexion

    enum ConnectionError: LocalizedError {
        case noTunnel
        case noPairing
        case noService
        case handshakeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTunnel:
                "Ouvre LocalDevVPN (ou StosVPN) et touche Connect. Le lien passe par son tunnel loopback, pas par le Wi-Fi."
            case .noPairing: "Aucun fichier de jumelage. Passe par l'onglet Jumelage."
            case .noService:
                "Service de jumelage introuvable sur le réseau local. Vérifie que le mode développeur est actif et que l'autorisation Réseau local est accordée dans Réglages › Parallax."
            case .handshakeFailed(let why): why
            }
        }
    }

    /// Monte le tunnel : découverte Bonjour, pair-verify, TLS-PSK, poignée RSD.
    ///
    /// Découpage volontaire — Swift résout l'adresse, Rust parle le protocole.
    /// Voir l'en-tête de `RemotePairingBrowser` pour pourquoi la découverte ne
    /// peut pas descendre dans Rust.
    @discardableResult
    func connect() async throws -> [String: Int] {
        if let existing = tunnelHandle, !services.isEmpty {
            _ = existing
            return services
        }

        // Refuse d'appeler idevice sans fichier valide. Sans ce garde-fou, un
        // fichier absent remonte en `Socket(ENOENT)` — qui ressemble à un échec
        // de socket usbmuxd et envoie le débogage dans une fausse direction.
        let path = PairingStore.fileURL.path
        try FFI.check(px_pairing_validate(path))

        // Le VPN loopback est le chemin nominal, et il doit être debout.
        guard tunnelState.isConnected else { throw ConnectionError.noTunnel }

        // Montage du tunnel, bloquant, hors du pool coopératif.
        let browser = self.browser
        let loopback = deviceIP
        let handle: OpaquePointer = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // ── LE CHEMIN NOMINAL : le VPN loopback, port RSD fixe ──────
                //
                // Pas de Bonjour ici, et c'est le point qui m'a coûté le plus
                // cher. L'annonce `_remotepairing._tcp` résout vers l'adresse
                // Wi-Fi de l'appareil, où `remoted` refuse le pair-verify —
                // symptôme : `device socket io failed` dès la première trame.
                //
                // Le tunnel se monte vers l'adresse du VPN loopback, sur le
                // port RSD fixe. C'est ce que fait SideInstaller, et c'est ce
                // pour quoi `deviceIP` et la surveillance d'interface
                // existaient déjà dans cette classe.
                LogBridge.noteFromBackground("montage du tunnel vers \(loopback):\(Self.rsdPort) (VPN loopback)…")
                let viaLoopback = path.withCString { p in
                    loopback.withCString { h in
                        px_tunnel_connect(p, h, Self.rsdPort)
                    }
                }
                if let viaLoopback {
                    LogBridge.noteFromBackground("lien établi par le VPN loopback")
                    continuation.resume(returning: viaLoopback)
                    return
                }
                let loopbackError = FFI.lastError
                LogBridge.noteFromBackground(
                    "VPN loopback refusé : \(loopbackError ?? "raison inconnue") — repli sur Bonjour"
                )

                // ── REPLI ───────────────────────────────────────────────────
                // Conservé parce qu'il ne coûte rien et qu'une configuration
                // réseau exotique peut exposer le service autrement. Mais ce
                // n'est pas le chemin attendu.
                let candidates = browser.discover()
                guard !candidates.isEmpty else {
                    continuation.resume(throwing: ConnectionError.handshakeFailed(
                        loopbackError ?? "Le tunnel n'a pas pu être établi."
                    ))
                    return
                }

                // Journaliser TOUS les candidats : quand pair-verify échoue, la
                // première question est « à quoi s'est-on connecté ? », et sans
                // cette ligne il n'y a aucun moyen de répondre.
                for candidate in candidates {
                    LogBridge.noteFromBackground(
                        "candidat : \(candidate.name) → \(candidate.host):\(candidate.port)"
                    )
                    // Les TXT disent quelle version du protocole l'appareil
                    // attend, et sous quelle identité il nous connaît. Quand
                    // pair-verify échoue sans autre indice, c'est là qu'est la
                    // réponse.
                    if !candidate.txt.isEmpty {
                        LogBridge.noteFromBackground("    txt : \(candidate.txtSummary)")
                    } else {
                        LogBridge.noteFromBackground("    txt : (aucun)")
                    }
                }

                // Essai en série. Un autre appareil Apple du réseau annonce le
                // même service et accepte le socket ; seul le nôtre passera
                // pair-verify avec notre enregistrement.
                var lastError: String?
                for candidate in candidates {
                    LogBridge.noteFromBackground(
                        "montage du tunnel vers \(candidate.host):\(candidate.port)…"
                    )
                    let result = path.withCString { p in
                        candidate.host.withCString { h in
                            px_tunnel_connect(p, h, candidate.port)
                        }
                    }
                    if let result {
                        LogBridge.noteFromBackground("lien accepté par \(candidate.name)")
                        continuation.resume(returning: result)
                        return
                    }
                    lastError = FFI.lastError
                    LogBridge.noteFromBackground(
                        "refusé par \(candidate.name) : \(lastError ?? "raison inconnue")"
                    )
                }

                continuation.resume(throwing: ConnectionError.handshakeFailed(
                    candidates.count == 1
                        ? (lastError ?? "Le tunnel n'a pas pu être établi.")
                        : "Aucun des \(candidates.count) services trouvés n'a accepté le lien. Dernier refus : \(lastError ?? "raison inconnue")"
                ))
            }
        }

        releaseTunnel()
        tunnelHandle = handle
        adapterHandle = UnsafeMutableRawPointer(px_tunnel_adapter(handle))
        rsdHandle = UnsafeMutableRawPointer(px_tunnel_rsd(handle))

        let discovered = FFI.tunnelServices(tunnel: handle)
        services = discovered
        ddiVerified = false
        LogBridge.shared.note("tunnel établi — \(discovered.count) service(s) RSD")
        return discovered
    }

    /// Reconnecte si le tunnel est tombé. Appelé par le superviseur GPS.
    func reconnectIfNeeded() async throws {
        guard tunnelHandle == nil else { return }
        try await connect()
    }

    /// Libère le tunnel. Toute session GPS doit avoir été fermée avant : elle
    /// emprunte l'adaptateur et la poignée RSD que ceci détruit.
    func releaseTunnel() {
        guard let handle = tunnelHandle else { return }
        tunnelHandle = nil
        adapterHandle = nil
        rsdHandle = nil
        services = [:]
        ddiVerified = false
        px_tunnel_free(handle)
    }

    // MARK: - DDI

    /// Garantit que l'image développeur est montée.
    ///
    /// Teste avant d'agir : la documentation de Mirage ne mentionne aucune
    /// étape DDI côté utilisateur, donc l'image est peut-être déjà là. Monter
    /// inutilement coûterait un aller-retour TSS de plusieurs secondes.
    func ensureDDIMounted(progress: @escaping (String) -> Void) async throws {
        guard !ddiVerified else { return }
        guard let rsd = rsdHandle else { throw ConnectionError.noTunnel }

        let status = px_ddi_is_mounted(rsd)
        if status == PX_OK {
            progress("Image développeur déjà montée.")
            ddiVerified = true
            return
        }
        guard status == PX_ERR_DDI_NOT_MOUNTED else { try FFI.check(status); return }

        progress("Montage de l'image développeur — requête Apple en cours…")

        let cache = DDICache()
        let (image, manifest) = try await cache.materialize()
        try FFI.check(px_ddi_mount(rsd, image.path, manifest.path))

        progress("Image développeur montée.")
        ddiVerified = true
    }
}

/// Cache local de la DDI.
///
/// L'image est volumineuse et son ticket TSS est lié à l'appareil : le refaire
/// à chaque lancement serait lent et inutile. Le montage lui-même reste valide
/// jusqu'au redémarrage.
struct DDICache {
    enum CacheError: LocalizedError {
        case missing
        var errorDescription: String? {
            "Image développeur absente. Voir README, section DDI."
        }
    }

    static var directory: URL {
        URL.documentsDirectory.appending(path: "ddi", directoryHint: .isDirectory)
    }

    func materialize() async throws -> (image: URL, manifest: URL) {
        let image = Self.directory.appending(path: "Image.dmg")
        let manifest = Self.directory.appending(path: "BuildManifest.plist")

        guard FileManager.default.fileExists(atPath: image.path),
              FileManager.default.fileExists(atPath: manifest.path) else {
            throw CacheError.missing
        }
        return (image, manifest)
    }
}
