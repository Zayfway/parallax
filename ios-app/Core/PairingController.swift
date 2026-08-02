import AVFoundation
import Foundation
import Network

// ═══════════════════════════════════════════════════════════════════════════
// CONTRÔLEUR DE JUMELAGE
//
// Répartition des rôles, apprise à la dure :
//
//   Rust  · lie le socket TCP, mène le protocole RPPairing, écrit le fichier
//   Swift · demande l'autorisation réseau local, **annonce le service en
//           Bonjour**, garde l'app vivante
//
// L'annonce ne peut pas être faite depuis Rust. Une bibliothèque mDNS pure
// publie les adresses de toutes les interfaces — sur un iPhone il y en a cinq,
// dont le tunnel VPN et le cellulaire — et iOS finit par tenter une adresse
// injoignable. `NetService` passe par le démon système, qui sait laquelle
// annoncer. Le symptôme d'une annonce faite en Rust : l'entrée apparaît bien
// dans Réglages, mais reste grise avec un rouet, et `accept()` n'est jamais
// atteint.
//
// Rust rend donc le port et les enregistrements TXT dès qu'il écoute, et
// Swift publie.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class PairingController: NSObject, ObservableObject {

    @Published private(set) var pin: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var hasFile = PairingStore.exists

    private let connection: DeviceConnection
    private var netService: NetService?
    private var keepAlive: AVAudioPlayer?

    init(connection: DeviceConnection) {
        self.connection = connection
        super.init()
    }

    // MARK: - Cycle de vie

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        pin = nil
        defer { isRunning = false; stopKeepAlive(); stopAdvertising() }

        do {
            try startKeepAlive()
            LogBridge.shared.note("host de jumelage démarré — en attente de Réglages")

            let path = PairingStore.fileURL.path

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Appel C bloquant : jamais dans une Task, le pool coopératif
                // n'a qu'un thread par cœur et les geler fait dérailler le reste.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = "Parallax".withCString { name in
                        path.withCString { out in
                            px_pairing_run_host(name, out, pxPinSink, pxReadySink)
                        }
                    }
                    if result == PX_OK {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: FFI.Failure(code: result, detail: FFI.lastError)
                        )
                    }
                }
            }

            hasFile = PairingStore.exists
            pin = nil
            LogBridge.shared.note("jumelage terminé")
        } catch {
            lastError = error.localizedDescription
            pin = nil
        }
    }

    /// Relit la présence du fichier. Appelé après un import : le jumelage
    /// n'est pas passé par nous, donc rien n'aurait mis `hasFile` à jour.
    func refreshFileState() {
        hasFile = PairingStore.exists
        lastError = nil
    }

    // MARK: - Observation des callbacks natifs

    func observePIN() {
        NotificationCenter.default.addObserver(
            forName: .pairingPIN, object: nil, queue: .main
        ) { [weak self] note in
            guard let code = note.object as? String else { return }
            Task { @MainActor in self?.pin = code }
        }

        NotificationCenter.default.addObserver(
            forName: .pairingReady, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.object as? PairingReadyPayload else { return }
            Task { @MainActor in self?.advertise(payload) }
        }
    }

    // MARK: - Bonjour

    /// Publie le service que Réglages va chercher. Le type porte un point
    /// final : `NetService` attend un nom pleinement qualifié, et sans lui
    /// l'enregistrement est silencieusement ignoré.
    private func advertise(_ payload: PairingReadyPayload) {
        stopAdvertising()

        let service = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: payload.serviceID,
            port: Int32(payload.port)
        )

        var txt: [String: Data] = [:]
        for (key, value) in payload.records {
            txt[key] = Data(value.utf8)
        }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        netService = service

        LogBridge.shared.note(
            "annonce _remotepairing-pairable-host._tcp \(payload.serviceID) sur le port \(payload.port)"
        )
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    // MARK: - Maintien en vie

    /// L'utilisateur part dans Réglages au milieu de l'opération. Une app
    /// suspendue cesse de répondre à Bonjour et l'entrée disparaît — c'est la
    /// première cause d'échec. De l'audio silencieux suffit à rester éveillé,
    /// et fonctionne dès iOS 17.4.
    private func startKeepAlive() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            LogBridge.shared.note("⚠️ silence.wav absent — l'app peut être suspendue")
            return
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        keepAlive = player
    }

    private func stopKeepAlive() {
        keepAlive?.stop()
        keepAlive = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Retour de publication

extension PairingController: NetServiceDelegate {

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in
            LogBridge.shared.note("service publié — visible dans Réglages")
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        Task { @MainActor in
            self.lastError = "Publication Bonjour refusée (code \(code)). Vérifie l'autorisation réseau local dans Réglages › Parallax."
            LogBridge.shared.note("échec de publication Bonjour : \(code)")
        }
    }
}

// MARK: - Ponts C

/// Ces deux fonctions sont de **portée fichier**, donc non isolées. Une
/// closure définie dans un contexte `@MainActor` hérite de son isolation, et
/// le runtime Swift 6 trappe dès que Rust l'appelle depuis un de ses threads.

struct PairingReadyPayload {
    let serviceID: String
    let port: UInt16
    let records: [(String, String)]
}

func pxPinSink(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let code = String(cString: pointer)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pairingPIN, object: code)
    }
}

func pxReadySink(
    _ serviceID: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ keys: UnsafePointer<UnsafePointer<CChar>?>?,
    _ values: UnsafePointer<UnsafePointer<CChar>?>?,
    _ count: UInt
) {
    guard let serviceID else { return }
    let identifier = String(cString: serviceID)

    var records: [(String, String)] = []
    if let keys, let values {
        for index in 0..<Int(count) {
            guard let key = keys[index], let value = values[index] else { continue }
            records.append((String(cString: key), String(cString: value)))
        }
    }

    let payload = PairingReadyPayload(serviceID: identifier, port: port, records: records)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pairingReady, object: payload)
    }
}

extension Notification.Name {
    static let pairingPIN = Notification.Name("io.parallax.pairingPIN")
    static let pairingReady = Notification.Name("io.parallax.pairingReady")
}
