import Foundation

/// Découverte du service de jumelage annoncé par l'appareil.
///
/// C'est le pendant de l'annonce faite dans `PairingController` : là on publie,
/// ici on cherche. Les deux passent par `NetService`, et pour la même raison —
/// le démon système sait quelle interface interroger, alors qu'une pile mDNS
/// pure en essaie cinq sur un iPhone, dont le tunnel VPN, et se bloque sur une
/// adresse injoignable. Rust ne reçoit qu'une adresse et un port déjà résolus.
///
/// ── POURQUOI CETTE CLASSE N'EST PAS UN ACTEUR ─────────────────────────────
///
/// `NetService` n'est pas `Sendable`. Le faire traverser la moindre frontière
/// d'isolation — y compris un `Task { @MainActor in }` — est refusé en mode
/// Swift 6, et `MainActor.assumeIsolated` n'y change rien : c'est la capture
/// elle-même qui compte comme un envoi.
///
/// Alors on ne franchit aucune frontière. Le navigateur tourne sur son propre
/// run loop, ses rappels s'exécutent sur ce fil, et seul le résultat — deux
/// valeurs immuables — en ressort, protégé par un verrou. `@unchecked Sendable`
/// est assumé et payé par ce verrou, pas par un vœu pieux.
///
/// ⚠️ `_remotepairing._tcp` doit figurer dans `NSBonjourServices` du
/// `project.yml`. Un type non déclaré ne fait pas échouer l'appel : il fait
/// **tuer le processus**.
final class RemotePairingBrowser: NSObject, @unchecked Sendable {

    struct Endpoint: Sendable, Equatable {
        let host: String
        let port: UInt16
        let name: String
    }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)

    private var found: [Endpoint] = []
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []

    /// Rend **tous** les `_remotepairing._tcp` résolus, pas seulement le
    /// premier.
    ///
    /// Prendre le premier venu était un piège : n'importe quel autre appareil
    /// Apple du réseau annonce le même type de service, on lui ouvre un socket,
    /// et pair-verify échoue parce que notre enregistrement ne le concerne pas.
    /// Le symptôme est indiscernable d'un jumelage périmé. L'appelant essaie
    /// donc les candidats l'un après l'autre.
    ///
    /// **Bloquant** — à appeler depuis `DispatchQueue.global`, jamais depuis le
    /// pool coopératif. Liste vide si rien n'a répondu dans le délai.
    ///
    /// Délai généreux : l'appareil n'annonce le service qu'une fois le mode
    /// développeur actif, et l'annonce met quelques secondes à se propager
    /// après un redémarrage.
    func discover(timeout: TimeInterval = 12) -> [Endpoint] {
        lock.lock(); found = []; lock.unlock()

        let worker = Thread { [self] in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .current, forMode: .default)
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

            lock.lock(); self.browser = browser; lock.unlock()

            // On laisse tourner un court instant après la première résolution
            // pour ramasser les autres annonceurs : c'est précisément quand il
            // y en a plusieurs que l'ordre compte.
            let deadline = Date().addingTimeInterval(timeout)
            var settleUntil: Date?
            while Date() < deadline {
                lock.lock(); let count = found.count; lock.unlock()
                if count > 0 {
                    let until = settleUntil ?? Date().addingTimeInterval(1.5)
                    settleUntil = until
                    if Date() >= until { break }
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }

            browser.stop()
            lock.lock()
            self.browser = nil
            resolving.forEach { $0.stop() }
            resolving.removeAll()
            lock.unlock()

            gate.signal()
        }
        worker.name = "io.parallax.bonjour"
        worker.start()

        // Marge d'une seconde : le fil signale toujours, la marge n'existe que
        // pour ne jamais rester bloqué si le run loop est empêché de tourner.
        _ = gate.wait(timeout: .now() + timeout + 1)

        lock.lock(); let candidates = found; lock.unlock()
        return candidates
    }
}

// MARK: - Rappels

/// Ces méthodes s'exécutent sur le fil du navigateur, pas sur le principal.
/// Elles ne touchent que de l'état protégé par le verrou.
extension RemotePairingBrowser: NetServiceBrowserDelegate, NetServiceDelegate {

    func netServiceBrowser(
        _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
    ) {
        service.delegate = self
        lock.lock(); resolving.append(service); lock.unlock()
        service.schedule(in: .current, forMode: .default)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // On veut une adresse littérale, pas le nom d'hôte `.local` : Rust
        // ouvre un socket TCP brut et ne fait aucune résolution mDNS.
        guard let host = sender.addresses?.compactMap(Self.literalAddress).first,
              sender.port > 0 else { return }

        let endpoint = Endpoint(host: host, port: UInt16(sender.port), name: sender.name)
        lock.lock()
        if !found.contains(endpoint) { found.append(endpoint) }
        lock.unlock()
    }

    /// Rend l'adresse sous forme littérale. IPv6 lien-local exclue : elle exige
    /// un identifiant de portée que le `SocketAddr` de Rust ne transporte pas.
    static func literalAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let socket = base.assumingMemoryBound(to: sockaddr.self)
            let family = socket.pointee.sa_family

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socket, socklen_t(data.count),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { return nil }

            let text = String(cString: host)
            if family == UInt8(AF_INET6) {
                if text.hasPrefix("fe80") || text.contains("%") { return nil }
                // Rust attend `[adresse]:port` pour l'IPv6.
                return "[\(text)]"
            }
            return text
        }
    }
}
