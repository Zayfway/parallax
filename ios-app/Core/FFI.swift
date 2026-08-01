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

// MARK: - Certificats

extension FFI {

    /// Nom de machine déclaré au moment de la connexion.
    ///
    /// Doit rester identique à `machine_name` dans `account.rs` : c'est le seul
    /// moyen de reconnaître, dans la liste rendue par Apple, l'emplacement que
    /// cette app occupe. S'ils divergent, l'écran marque « autre machine » sur
    /// notre propre certificat.
    static let machineName = "Parallax"

    /// Certificat de développement iOS tel qu'Apple le décrit.
    ///
    /// Décodé du JSON produit par `px_cert_list`. Les champs absents côté Apple
    /// arrivent en chaîne vide plutôt qu'en `null` — c'est le contrat de
    /// `CertInfo` côté Rust, et ça évite un `Optional` par champ ici.
    struct Certificate: Identifiable, Equatable {
        let name: String
        let serialNumber: String
        let machineName: String
        let certificateID: String
        let status: String
        /// `nil` quand Apple ne donne pas de date.
        let expiry: Date?
        /// Nombre d'emplacements qu'Apple déclare pour ce type de certificat.
        /// `nil` quand il ne le renseigne pas. C'est la seule source honnête :
        /// trois vaut pour un compte gratuit, pas pour un compte payant.
        let maxActiveCerts: Int?

        /// Le numéro de série est ce que `px_cert_revoke` attend ; s'il manque,
        /// on retombe sur l'identifiant pour garder la liste stable à l'écran.
        var id: String { serialNumber.isEmpty ? certificateID : serialNumber }

        /// Vrai si c'est l'emplacement occupé par cette app.
        var isOurs: Bool { machineName == FFI.machineName }

        var isExpired: Bool {
            if let expiry { return expiry < Date.now }
            return status.caseInsensitiveCompare("Expired") == .orderedSame
        }

        var isRevoked: Bool {
            status.caseInsensitiveCompare("Revoked") == .orderedSame
        }
    }

    /// Liste les certificats de développement iOS de l'équipe.
    ///
    /// **Bloquant** — aller-retour vers Apple. À n'appeler que depuis
    /// `DispatchQueue.global`, jamais depuis le pool coopératif.
    static func certificates(session: OpaquePointer) throws -> [Certificate] {
        guard let raw = px_cert_list(session) else {
            throw Failure(code: PX_ERR_INTERNAL, detail: lastError)
        }
        // Le tas appartient à Rust : Swift rend la chaîne quoi qu'il arrive,
        // y compris si le décodage lève.
        defer { px_string_free(raw) }

        let payload = Data(String(cString: raw).utf8)
        do {
            // Un formateur local plutôt qu'un `static` partagé : en mode Swift 6
            // une globale non-`Sendable` ne compile pas, et l'annoter
            // `nonisolated(unsafe)` serait affirmer une garantie qu'on n'a pas.
            // La liste tient en quelques éléments, l'allocation ne se voit pas.
            let dates = ISO8601DateFormatter()
            dates.formatOptions = [.withInternetDateTime]

            return try JSONDecoder()
                .decode([Wire].self, from: payload)
                .map { $0.certificate(parsingDatesWith: dates) }
        } catch {
            throw Failure(
                code: PX_ERR_INTERNAL,
                detail: "Réponse d'Apple illisible : \(error.localizedDescription)"
            )
        }
    }

    /// Révoque un certificat par son numéro de série.
    ///
    /// **Bloquant** — même règle que `certificates(session:)`.
    static func revokeCertificate(session: OpaquePointer, serial: String) throws {
        try check(serial.withCString { px_cert_revoke(session, $0) })
    }

    /// Récupère le certificat de cette machine, ou en demande un neuf à Apple.
    /// Rend son numéro de série.
    ///
    /// Idempotent : appeler deux fois ne crée pas deux certificats.
    ///
    /// **Bloquant** — même règle que `certificates(session:)`.
    @discardableResult
    static func createCertificate(session: OpaquePointer) throws -> String {
        guard let raw = px_cert_create(session) else {
            throw Failure(code: PX_ERR_INTERNAL, detail: lastError)
        }
        defer { px_string_free(raw) }
        return String(cString: raw)
    }

    /// Miroir exact de `CertInfo` (`account.rs`). Séparé du modèle exposé pour
    /// que la conversion de date reste au même endroit que le format qui la
    /// produit — `to_xml_format`, donc ISO 8601 en UTC.
    private struct Wire: Decodable {
        let name: String
        let serialNumber: String
        let machineName: String
        let certificateID: String
        let status: String
        let expiration: String
        let maxActiveCerts: Int?

        enum CodingKeys: String, CodingKey {
            case name, status, expiration
            case serialNumber = "serial_number"
            case machineName = "machine_name"
            case certificateID = "certificate_id"
            case maxActiveCerts = "max_active_certs"
        }

        func certificate(parsingDatesWith dates: ISO8601DateFormatter) -> Certificate {
            Certificate(
                name: name,
                serialNumber: serialNumber,
                machineName: machineName,
                certificateID: certificateID,
                status: status,
                expiry: expiration.isEmpty ? nil : dates.date(from: expiration),
                maxActiveCerts: maxActiveCerts
            )
        }
    }
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
