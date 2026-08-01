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

    /// Handle RSD opaque, propriété du cœur Rust.
    /// `nil` tant que `connect()` n'a pas réussi.
    private(set) var rsdHandle: UnsafeMutableRawPointer?

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
        case handshakeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTunnel:  "Ouvre LocalDevVPN et touche Connect."
            case .noPairing: "Aucun fichier de jumelage. Passe par l'onglet Jumelage."
            case .handshakeFailed(let why): why
            }
        }
    }

    @discardableResult
    func connect() async throws -> DeviceInfo {
        guard tunnelState.isConnected else { throw ConnectionError.noTunnel }

        // Refuse d'appeler idevice sans fichier valide. Sans ce garde-fou, un
        // fichier absent remonte en `Socket(ENOENT)` — qui ressemble à un échec
        // de socket usbmuxd et envoie le débogage dans une fausse direction.
        let path = PairingStore.fileURL.path
        try FFI.check(px_pairing_validate(path))

        // TODO — brancher tunnel_create_rppairing + lockdownd_get_value une fois
        // les signatures d'idevice confirmées. Voir README, étapes 3 et 4.
        throw ConnectionError.handshakeFailed(
            "Connexion native non compilée. Active --features device-pairing."
        )
    }

    /// Reconnecte si le handle est tombé. Appelé par le superviseur GPS.
    func reconnectIfNeeded() async throws {
        guard rsdHandle == nil else { return }
        try await connect()
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
