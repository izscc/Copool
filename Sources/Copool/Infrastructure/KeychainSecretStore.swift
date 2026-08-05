import Foundation
#if canImport(Security)
import Security
#endif

/// Stores provider secrets in the login keychain instead of on disk.
///
/// Every call is failable on purpose. This app ships ad-hoc signed, and an
/// ad-hoc signature changes on every rebuild, which can make macOS treat a
/// new build as a different application and refuse access to items the
/// previous build created. Callers must therefore keep working when the
/// keychain says no — losing a user's imported OAuth token would be far worse
/// than leaving it in a 0600 file.
struct KeychainSecretStore: Sendable {
    let service: String

    init(service: String = "com.alick.copool.providers") {
        self.service = service
    }

    func read(account: String) -> String? {
        #if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
        #else
        return nil
        #endif
    }

    /// Returns false when the secret could not be stored, so the caller can
    /// fall back rather than dropping it.
    @discardableResult
    func write(account: String, value: String) -> Bool {
        #if canImport(Security)
        guard !value.isEmpty else { return delete(account: account) }
        let data = Data(value.utf8)

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        // Secrets are only needed while the user is at this Mac, and must not
        // travel to other devices via iCloud keychain.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    @discardableResult
    func delete(account: String) -> Bool {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        return false
        #endif
    }

    #if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}

/// Keychain account names for one provider's secrets.
enum ProviderSecretAccount {
    static func apiKey(providerID: String) -> String { "\(providerID)|apiKey" }
    static func refreshToken(providerID: String) -> String { "\(providerID)|refreshToken" }
}
