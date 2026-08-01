import Foundation
import AVFoundation
import Network

/// Pilote le host de jumelage RPPairing.
///
/// Trois responsabilités qui ne peuvent pas vivre en Rust :
///
/// 1. **Autorisation Réseau local.** Sans elle, la diffusion Bonjour est
///    silencieusement ignorée et rien n'apparaît sous « Jumeler avec ».
/// 2. **Diffusion Bonjour**, pour que Réglages découvre l'hôte.
/// 3. **Maintien en vie.** L'utilisateur doit quitter l'app pour aller dans
///    Réglages. Une app suspendue cesse de diffuser — c'est la cause n°1
///    d'échec. On joue un silence en boucle, technique qui fonctionne dès
///    iOS 17.4, là où StikPair utilise un `BGContinuedProcessingTask`
///    réservé à iOS 26.
@MainActor
final class PairingController: ObservableObject {

    @Published private(set) var pin: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var hasFile = PairingStore.exists

    private let connection: DeviceConnection
    private var listener: NWListener?
    private var keepAlive: AVAudioPlayer?

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        pin = nil
        defer { isRunning = false; stopKeepAlive() }

        do {
            try startKeepAlive()
            try advertise()

            LogBridge.shared.note("host de jumelage démarré — en attente de Réglages")

            // Le host bloque : il tourne hors du thread principal et rappelle
            // sur celui-ci pour publier le code.
            let path = PairingStore.fileURL.path
            let code = try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    let result = "Parallax".withCString { name in
                        path.withCString { out in
                            px_pairing_run_host(name, out) { pointer in
                                guard let pointer else { return }
                                let code = String(cString: pointer)
                                Task { @MainActor in PairingController.publish(code) }
                            }
                        }
                    }
                    if result == PX_OK {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: FFI.Failure(code: result, detail: FFI.lastError))
                    }
                }
            }
            _ = code

            hasFile = PairingStore.exists
            pin = nil
            LogBridge.shared.note("jumelage terminé")
        } catch {
            lastError = error.localizedDescription
            pin = nil
        }
        stopAdvertising()
    }

    /// Le callback C ne capture rien : il passe par ce point d'entrée statique.
    private static func publish(_ code: String) {
        NotificationCenter.default.post(name: .pairingPIN, object: code)
    }

    func observePIN() {
        NotificationCenter.default.addObserver(
            forName: .pairingPIN, object: nil, queue: .main
        ) { [weak self] note in
            guard let code = note.object as? String else { return }
            Task { @MainActor in self?.pin = code }
        }
    }

    // MARK: - Bonjour

    private func advertise() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: "Parallax", type: "_remotepairing._tcp")
        listener.newConnectionHandler = { $0.cancel() } // Le host Rust gère le vrai trafic.
        listener.start(queue: .main)
        self.listener = listener
    }

    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Maintien en vie

    private func startKeepAlive() throws {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` : ne coupe pas la musique de l'utilisateur. Une app
        // utilitaire qui interrompt la lecture pour un jumelage serait
        // insupportable, et le silence n'a besoin d'aucune priorité.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            LogBridge.shared.note("⚠️ silence.wav absent — l'app peut être suspendue pendant le jumelage")
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

extension Notification.Name {
    static let pairingPIN = Notification.Name("io.parallax.pairingPIN")
}
