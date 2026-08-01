import Foundation
import Security

/// Stockage du fichier de jumelage.
///
/// Deux emplacements, volontairement :
///
/// - **Le fichier sur disque**, protégé par `.completeUntilFirstUserAuthentication`.
///   Le cœur Rust lit un chemin, pas un blob mémoire ; l'exposer autrement
///   demanderait de réécrire l'API d'idevice.
/// - **Une copie en Trousseau**, qui sert de sauvegarde. Le conteneur de
///   l'app est effacé à chaque réinstallation, or SideStore doit être
///   rafraîchi tous les sept jours en signature gratuite. Sans cette copie,
///   l'utilisateur refait tout le jumelage à chaque cycle.
///
/// La protection retenue est `AfterFirstUnlock` et non `WhenUnlocked` : le
/// superviseur GPS doit pouvoir relire le fichier pour reconnecter alors que
/// l'écran est verrouillé.
enum PairingStore {

    static let fileURL = URL.documentsDirectory
        .appending(path: "rp_pairing_file.plist")

    private static let service = "io.parallax.pairing"
    private static let account = "rp_pairing_file"

    static var exists: Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int else { return false }
        return size > 0
    }

    static func save(_ data: Data) throws {
        guard !data.isEmpty else { throw StoreError.empty }

        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? saveToKeychain(data)
    }

    static func load() throws -> Data {
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty { return data }

        // Le conteneur a été effacé : on restaure depuis le Trousseau.
        let backup = try loadFromKeychain()
        try? backup.write(to: fileURL, options: .atomic)
        return backup
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }

    // MARK: - Trousseau

    private static func saveToKeychain(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private static func loadFromKeychain() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            throw StoreError.notFound
        }
        return data
    }

    enum StoreError: LocalizedError {
        case empty, notFound
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .empty:    "Fichier de jumelage vide — le jumelage n'a pas abouti."
            case .notFound: "Aucun fichier de jumelage enregistré."
            case .keychain(let s): "Trousseau inaccessible (\(s))."
            }
        }
    }
}
