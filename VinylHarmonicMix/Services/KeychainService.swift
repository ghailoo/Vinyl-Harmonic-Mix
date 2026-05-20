import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = Bundle.main.bundleIdentifier ?? "com.vinylharmonicmix"

    private init() {}

    func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let base = baseQuery(for: key)
        SecItemDelete(base as CFDictionary)
        var addQuery = base
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    enum Key: String {
        case token = "discogs_token"
        case username = "discogs_username"
        case musicbrainzContactEmail = "mb_contact_email"
        case acoustIDKey = "acoustid_api_key"
    }

    enum KeychainError: LocalizedError {
        case encodingFailed
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode value for Keychain storage."
            case .saveFailed(let status):
                return "Keychain save failed (OSStatus \(status))."
            }
        }
    }
}
