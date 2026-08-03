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

// MARK: - Tunnel

extension FFI {

    /// Services annoncés par RSD, `nom → port`. Vide si le tunnel est mort.
    ///
    /// Utile en soi : la présence de `com.apple.instruments.dtservicehub`
    /// signifie que l'image développeur est montée.
    static func tunnelServices(tunnel: OpaquePointer) -> [String: Int] {
        guard let raw = px_tunnel_services(tunnel) else { return [:] }
        defer { px_string_free(raw) }
        let payload = Data(String(cString: raw).utf8)
        return (try? JSONDecoder().decode([String: Int].self, from: payload)) ?? [:]
    }
}

// MARK: - Installation

extension FFI {

    /// Identité de l'appareil, écrite par Rust au moment du jumelage.
    ///
    /// L'UDID ne vient de nulle part ailleurs : le `RpPairingFile` ne le
    /// contient pas, et le lire ensuite demanderait lockdown par-dessus le
    /// tunnel. `PairableHost::accept` le rend gratuitement, une seule fois.
    struct PairedDevice: Decodable, Equatable {
        let udid: String
        let name: String
        let model: String
    }

    static func pairedDevice(besidePairingFile url: URL) -> PairedDevice? {
        let peer = URL(fileURLWithPath: url.path + ".peer.json")
        guard let data = try? Data(contentsOf: peer) else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    /// Installe un `.ipa` : enregistrement de l'appareil, signature, transfert,
    /// installation. Rend le nom de l'app spéciale détectée, ou une chaîne vide.
    ///
    /// **Bloquant, et longuement** — plusieurs allers-retours chez Apple puis un
    /// transfert de fichier. `DispatchQueue.global` obligatoire.
    @discardableResult
    static func installIPA(
        session: OpaquePointer,
        tunnel: OpaquePointer,
        ipaPath: String,
        device: PairedDevice,
        dylibs: [String] = [],
        injectionPath: String = "@executable_path",
        injectionFolder: String = "Frameworks",
        injectIntoExtensions: Bool = false,
        customName: String = "",
        customBundleID: String = ""
    ) throws -> String {
        // Tableau de C-strings pour les tweaks à injecter. strdup + free : plus
        // simple qu'un withCString imbriqué de longueur variable. Vide = aucune
        // injection, chemin d'install normal.
        let owned = dylibs.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }

        let raw = ipaPath.withCString { ipa in
            device.udid.withCString { udid in
                device.name.withCString { name in
                    withCStrings(injectionPath, injectionFolder, customName, customBundleID) {
                        ipath, ifolder, cname, cbundle in
                        ptrs.withUnsafeBufferPointer { buf in
                            px_install_ipa(
                                session, tunnel, ipa, udid, name,
                                buf.baseAddress, UInt(dylibs.count),
                                ipath, ifolder, injectIntoExtensions,
                                cname, cbundle,
                                pxInstallProgress
                            )
                        }
                    }
                }
            }
        }
        guard let raw else { throw Failure(code: PX_ERR_INTERNAL, detail: lastError) }
        defer { px_string_free(raw) }
        return String(cString: raw)
    }

    /// Installe un `.ipa` signé **hors-ligne** avec un certificat importé
    /// (`.p12` + `.mobileprovision`) — sans compte Apple. Ne demande que le
    /// tunnel. Même options d'injection que le chemin en ligne.
    ///
    /// **Bloquant** — signature locale puis transfert. `DispatchQueue.global`.
    @discardableResult
    static func installIPAWithCertificate(
        tunnel: OpaquePointer,
        ipaPath: String,
        p12Path: String,
        p12Password: String,
        profilePath: String,
        dylibs: [String] = [],
        injectionPath: String = "@executable_path",
        injectionFolder: String = "Frameworks",
        injectIntoExtensions: Bool = false,
        customName: String = "",
        customBundleID: String = ""
    ) throws -> String {
        let owned = dylibs.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }

        let raw = ipaPath.withCString { ipa in
            p12Path.withCString { p12 in
                p12Password.withCString { pass in
                    profilePath.withCString { prof in
                        withCStrings(injectionPath, injectionFolder, customName, customBundleID) {
                            ipath, ifolder, cname, cbundle in
                            ptrs.withUnsafeBufferPointer { buf in
                                px_install_ipa_p12(
                                    tunnel, ipa, p12, pass, prof,
                                    buf.baseAddress, UInt(dylibs.count),
                                    ipath, ifolder, injectIntoExtensions,
                                    cname, cbundle,
                                    pxInstallProgress
                                )
                            }
                        }
                    }
                }
            }
        }
        guard let raw else { throw Failure(code: PX_ERR_INTERNAL, detail: lastError) }
        defer { px_string_free(raw) }
        return String(cString: raw)
    }

    // MARK: - Bibliothèque (apps installées)

    /// Liste les apps utilisateur installées sur l'appareil (via le tunnel).
    static func listApps(tunnel: OpaquePointer) throws -> [InstalledApp] {
        guard let raw = px_apps_list(tunnel) else {
            throw Failure(code: PX_ERR_INTERNAL, detail: lastError)
        }
        defer { px_string_free(raw) }
        let json = Data(String(cString: raw).utf8)
        return (try? JSONDecoder().decode([InstalledApp].self, from: json)) ?? []
    }

    /// Désinstalle l'app d'identifiant `bundleID`.
    static func uninstallApp(tunnel: OpaquePointer, bundleID: String) throws {
        let rc = bundleID.withCString { px_app_uninstall(tunnel, $0) }
        if rc != PX_OK { throw Failure(code: rc, detail: lastError) }
    }

    /// Icône PNG d'une app (via springboardservices). `nil` si indisponible —
    /// c'est un ornement, jamais une erreur bloquante. **Bloquant** : à appeler
    /// hors du thread principal, un appel à la fois (accès tunnel non concurrent).
    static func appIcon(tunnel: OpaquePointer, bundleID: String) -> Data? {
        guard let raw = bundleID.withCString({ px_app_icon(tunnel, $0) }) else { return nil }
        defer { px_string_free(raw) }
        return Data(base64Encoded: String(cString: raw))
    }

    // MARK: - Fichiers (espace Média, AFC)

    static func listFiles(tunnel: OpaquePointer, path: String) throws -> [DeviceFile] {
        guard let raw = path.withCString({ px_fs_list(tunnel, $0) }) else {
            throw Failure(code: PX_ERR_INTERNAL, detail: lastError)
        }
        defer { px_string_free(raw) }
        let json = Data(String(cString: raw).utf8)
        return (try? JSONDecoder().decode([DeviceFile].self, from: json)) ?? []
    }

    static func downloadFile(tunnel: OpaquePointer, remote: String, dest: String) throws {
        let rc = remote.withCString { r in dest.withCString { d in px_fs_download(tunnel, r, d) } }
        if rc != PX_OK { throw Failure(code: rc, detail: lastError) }
    }

    static func uploadFile(tunnel: OpaquePointer, local: String, remote: String) throws {
        let rc = local.withCString { l in remote.withCString { r in px_fs_upload(tunnel, l, r) } }
        if rc != PX_OK { throw Failure(code: rc, detail: lastError) }
    }

    static func deleteFile(tunnel: OpaquePointer, path: String) throws {
        let rc = path.withCString { px_fs_delete(tunnel, $0) }
        if rc != PX_OK { throw Failure(code: rc, detail: lastError) }
    }

    static func makeDir(tunnel: OpaquePointer, path: String) throws {
        let rc = path.withCString { px_fs_mkdir(tunnel, $0) }
        if rc != PX_OK { throw Failure(code: rc, detail: lastError) }
    }

    static func storageInfo(tunnel: OpaquePointer) -> DeviceStorage? {
        guard let raw = px_fs_storage(tunnel) else { return nil }
        defer { px_string_free(raw) }
        return try? JSONDecoder().decode(DeviceStorage.self, from: Data(String(cString: raw).utf8))
    }
}

/// Une entrée du système de fichiers de l'appareil (espace Média).
struct DeviceFile: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int
    let kind: String
    var id: String { path }
    var sizeText: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// Infos de stockage de l'espace Média.
struct DeviceStorage: Codable {
    let model: String
    let totalBytes: Int
    let freeBytes: Int
    var usedBytes: Int { max(0, totalBytes - freeBytes) }
}

/// Une app installée, telle que rendue par `px_apps_list`.
struct InstalledApp: Codable, Identifiable, Equatable {
    let bundleId: String
    let name: String
    let version: String
    let build: String
    /// « sideloaded » (dev/entreprise/IPA), « store » (App Store) ou « system ».
    let source: String
    /// Espace occupé (statique + dynamique), en octets.
    let sizeBytes: Int
    var id: String { bundleId }

    var isSideloaded: Bool { source == "sideloaded" }
    var isStore: Bool { source == "store" }

    /// Taille lisible (« 128 Mo »), vide si inconnue.
    var sizeText: String {
        guard sizeBytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Emprunte quatre chaînes en C-strings à la fois, pour éviter une pyramide de
/// `withCString` imbriqués. Les pointeurs ne sont valides que dans `body`.
func withCStrings<R>(
    _ a: String, _ b: String, _ c: String, _ d: String,
    _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>,
             UnsafePointer<CChar>, UnsafePointer<CChar>) -> R
) -> R {
    a.withCString { pa in
        b.withCString { pb in
            c.withCString { pc in
                d.withCString { pd in body(pa, pb, pc, pd) }
            }
        }
    }
}

/// Pont de progression Rust → Swift.
///
/// **Portée fichier, donc non isolée.** Une closure définie dans un contexte
/// `@MainActor` en hériterait l'isolation, et le runtime trappe dès que Rust
/// l'appelle depuis un de ses threads. C'est le même piège que `pxPinSink`.
func pxInstallProgress(_ percent: UInt32, _ label: UnsafePointer<CChar>?) {
    let text = label.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .installProgress,
            object: InstallProgress(percent: Int(percent), label: text)
        )
    }
}

struct InstallProgress: Equatable {
    let percent: Int
    let label: String
}

extension Notification.Name {
    static let installProgress = Notification.Name("io.parallax.installProgress")
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

    /// Journalise depuis un fil de fond — découverte Bonjour, appels FFI
    /// bloquants. `shared` est isolé au `MainActor`, donc on ne le touche que
    /// depuis une tâche qui y est déjà ; le `Task` ne contient aucun appel
    /// bloquant, seulement l'ajout d'une ligne.
    nonisolated static func noteFromBackground(_ message: String) {
        Task { @MainActor in LogBridge.shared.append(message) }
    }
    func clear() { lines.removeAll() }

    var joined: String { lines.joined(separator: "\n") }
}
