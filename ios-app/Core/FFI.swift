import Foundation

/// Enrobage Swift du cœur Rust.
///
/// Une seule règle : rien d'autre dans l'app n'appelle `px_*` directement.
/// Toute la conversion de codes d'erreur, de chaînes C et de handles opaques
/// est concentrée ici, ce qui laisse un unique endroit à corriger quand
/// l'API d'idevice bouge — et elle bougera.
enum FFI {

    /// Erreur remontée par le cœur natif.
    struct Failure: LocalizedError {
        let code: Int32
        let detail: String?

        var errorDescription: String? {
            if let detail, !detail.isEmpty { return detail }
            return Self.message(for: code)
        }

        /// Message pour l'utilisateur, pas pour le journal. Chacun dit quoi
        /// faire, parce qu'un code d'erreur seul n'aide personne.
        static func message(for code: Int32) -> String {
            switch code {
            case PX_ERR_ARG:              "Paramètre invalide."
            case PX_ERR_NOT_BUILT:        "Module natif non compilé dans cette version."
            case PX_ERR_NO_TUNNEL:        "Tunnel absent. Ouvre LocalDevVPN et touche Connect."
            case PX_ERR_NO_PAIRING:       "Aucun jumelage. Passe par l'onglet Jumelage."
            case PX_ERR_DDI_NOT_MOUNTED:  "Image développeur non montée."
            case PX_ERR_DDI_MOUNT_FAILED: "Le montage de l'image développeur a échoué."
            case PX_ERR_DVT_OPEN_FAILED:  "Canal développeur inaccessible."
            case PX_ERR_SESSION_DEAD:     "Session perdue. Reconnexion en cours."
            case PX_ERR_AUTH_FAILED:      "Identifiants Apple refusés."
            case PX_ERR_2FA_REQUIRED:     "Code de validation requis."
            case PX_ERR_SIGN_FAILED:      "La signature a échoué."
            default:                      "Erreur interne (\(code))."
            }
        }
    }

    /// Dernier message d'erreur du cœur natif.
    static var lastError: String? {
        guard let ptr = px_last_error() else { return nil }
        let text = String(cString: ptr)
        return text.isEmpty ? nil : text
    }

    /// Convertit un code de retour en `throws`.
    static func check(_ code: Int32) throws {
        guard code != PX_OK else { return }
        throw Failure(code: code, detail: lastError)
    }

    /// Ce qui a réellement été compilé. Affiché dans les réglages : c'est la
    /// première chose à vérifier quand une fonctionnalité ne répond pas.
    static var buildProfile: String {
        guard let ptr = px_build_profile() else { return "inconnu" }
        return String(cString: ptr)
    }

    static func ping() -> Bool { px_ping() == PX_OK }
}

/// Pont de journalisation Rust → Swift.
///
/// Le callback C ne peut pas capturer de contexte, d'où le singleton. Les
/// lignes sont publiées sur le thread principal parce que l'UI les observe.
@MainActor
final class LogBridge: ObservableObject {
    static let shared = LogBridge()

    /// Borné : sur un échec en boucle, un journal non borné finit par
    /// consommer toute la mémoire de l'app.
    private let limit = 2_000

    @Published private(set) var lines: [String] = []

    nonisolated static func install() {
        _ = px_log_init { pointer in
            guard let pointer else { return }
            let line = String(cString: pointer)
            Task { @MainActor in LogBridge.shared.append(line) }
        }
    }

    func append(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(line)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func note(_ message: String) { append(message) }
    func clear() { lines.removeAll() }

    var joined: String { lines.joined(separator: "\n") }
}
