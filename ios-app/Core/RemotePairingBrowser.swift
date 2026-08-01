import Foundation

/// Découverte du service de jumelage annoncé par l'appareil.
///
/// C'est le pendant de l'annonce faite dans `PairingController` : là on publie,
/// ici on cherche. Les deux passent par `NetService` / `NetServiceBrowser`, et
/// pour la même raison — le démon système sait quelle interface interroger,
/// alors qu'une pile mDNS pure en essaie cinq sur un iPhone, dont le tunnel
/// VPN, et se bloque sur une adresse injoignable.
///
/// Rust ne fait donc que recevoir une adresse et un port déjà résolus.
///
/// ⚠️ `_remotepairing._tcp` doit figurer dans `NSBonjourServices` du
/// `project.yml`. Un type non déclaré ne fait pas échouer l'appel : il fait
/// **tuer le processus**.
@MainActor
final class RemotePairingBrowser: NSObject, ObservableObject {

    struct Endpoint: Equatable {
        let host: String
        let port: UInt16
        let name: String
    }

    enum BrowseError: LocalizedError {
        case timedOut
        case notFound

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "Aucun service de jumelage trouvé sur le réseau local. Vérifie que l'autorisation Réseau local est accordée dans Réglages › Parallax."
            case .notFound:
                "Le service a été vu mais son adresse n'a pas pu être résolue."
            }
        }
    }

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var continuation: CheckedContinuation<Endpoint, Error>?

    /// Cherche le premier `_remotepairing._tcp` résolvable, ou échoue.
    ///
    /// `timeout` généreux : l'appareil n'annonce le service qu'une fois le mode
    /// développeur actif, et l'annonce peut mettre quelques secondes à se
    /// propager après un redémarrage.
    func discover(timeout: TimeInterval = 12) async throws -> Endpoint {
        cancel()

        return try await withThrowingTaskGroup(of: Endpoint.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let browser = NetServiceBrowser()
                    browser.delegate = self
                    browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
                    self.browser = browser
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw BrowseError.timedOut
            }

            guard let first = try await group.next() else { throw BrowseError.timedOut }
            group.cancelAll()
            return first
        }
    }

    func cancel() {
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        // Une continuation jamais reprise fige la tâche pour toujours.
        continuation?.resume(throwing: BrowseError.notFound)
        continuation = nil
    }

    private func deliver(_ endpoint: Endpoint) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.stop()
        browser = nil
        LogBridge.shared.note("service de jumelage résolu : \(endpoint.host):\(endpoint.port)")
        continuation.resume(returning: endpoint)
    }
}

extension RemotePairingBrowser: NetServiceBrowserDelegate, NetServiceDelegate {

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
    ) {
        Task { @MainActor in
            service.delegate = self
            self.resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        // On veut une adresse littérale, pas le nom d'hôte `.local` : Rust
        // ouvre un socket TCP brut et ne fait pas de résolution mDNS.
        let address = sender.addresses?.compactMap(Self.literalAddress).first
        Task { @MainActor in
            guard let address, sender.port > 0 else { return }
            self.deliver(Endpoint(host: address, port: UInt16(sender.port), name: sender.name))
        }
    }

    /// Rend l'adresse sous forme littérale. IPv6 lien-local exclue : elle exige
    /// un identifiant de portée que le `SocketAddr` de Rust ne transporte pas.
    nonisolated static func literalAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { return nil }

            let text = String(cString: host)
            if family == UInt8(AF_INET6) {
                if text.hasPrefix("fe80") || text.contains("%") { return nil }
                // Rust parse `[adresse]:port` pour l'IPv6.
                return "[\(text)]"
            }
            return text
        }
    }
}
