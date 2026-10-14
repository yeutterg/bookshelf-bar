import Foundation
import Security

/// The speaker's web-page password (only needed if one was set), stored in the login Keychain.
enum SpeakerPassword {
    static let service = "BookshelfBar speaker password"
    /// Name used before the app was renamed from KEF Bar; read as a fallback.
    static let legacyService = "KEFBar speaker password"

    static func load(for kefId: String?) -> String? {
        load(for: kefId, service: service) ?? load(for: kefId, service: legacyService)
    }

    private static func load(for kefId: String?, service: String) -> String? {
        guard let kefId else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: kefId, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for kefId: String?) {
        guard let kefId else { return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: kefId]
        SecItemDelete(match as CFDictionary)
        guard !password.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
