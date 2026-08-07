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
///
/// Every call is also time-boxed: `SecItemCopyMatching` can block
/// indefinitely on an authorization prompt (macOS asks before letting a new
/// build read an item another build created). Calls run on a background queue
/// and give up after `timeout`, returning the failable result, so no caller —
/// including the main-thread provider list — can ever stall on the keychain.
struct KeychainSecretStore: Sendable, SecureStore {
    let service: String

    init(service: String = "com.alick.copool.providers") {
        self.service = service
    }

    func read(account: String, timeout: TimeInterval = 3) -> String? {
        runOnBackground(timeout: timeout) {
            Self.readSynchronously(service: self.service, account: account)
        } ?? nil
    }

    /// Returns false when the secret could not be stored, so the caller can
    /// fall back rather than dropping it.
    @discardableResult
    func write(account: String, value: String, timeout: TimeInterval = 3) -> Bool {
        guard !value.isEmpty else { return delete(account: account, timeout: timeout) }
        let data = Data(value.utf8)
        return runOnBackground(timeout: timeout) {
            Self.writeSynchronously(service: self.service, account: account, data: data)
        } ?? false
    }

    @discardableResult
    func delete(account: String, timeout: TimeInterval = 3) -> Bool {
        runOnBackground(timeout: timeout) {
            Self.deleteSynchronously(service: self.service, account: account)
        } ?? false
    }

    // MARK: - Synchronous core (runs on a background queue)

    #if canImport(Security)
    private static func readSynchronously(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
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
    }

    private static func writeSynchronously(service: String, account: String, data: Data) -> Bool {
        let query = baseQuery(service: service, account: account)
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
    }

    private static func deleteSynchronously(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

    // MARK: - Time boxing

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Any?

        func set(_ value: Any?) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        func get() -> Any? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func runOnBackground<T>(timeout: TimeInterval, _ body: @escaping @Sendable () -> T) -> T? {
        #if canImport(Security)
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(body())
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.get() as? T
        #else
        return nil
        #endif
    }
}

/// Keychain account names for one provider's secrets.
enum ProviderSecretAccount {
    static func apiKey(providerID: String) -> String { "\(providerID)|apiKey" }
    static func refreshToken(providerID: String) -> String { "\(providerID)|refreshToken" }
}
