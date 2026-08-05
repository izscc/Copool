import Foundation

/// Persists the third-party provider configuration (providers.json).
///
/// Secrets are held in the keychain and blanked in the file; the store
/// rehydrates them on load so everything downstream — the proxy, capability
/// discovery, the token refresher — keeps seeing a plain `apiKey`.
///
/// Migration is lazy rather than eager. Existing secrets move across the
/// first time anything saves the store, which token refresh and capability
/// discovery both do on their own. Rewriting every provider at launch would
/// throw a keychain prompt at the user before they had asked for anything,
/// and would move all their credentials in one step on a build whose ad-hoc
/// signature changes each time it is rebuilt.
final class ProviderFileRepository: ProviderStoreRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let secrets: KeychainSecretStore
    private let lock = NSLock()

    init(
        paths: FileSystemPaths,
        fileManager: FileManager = .default,
        secrets: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.secrets = secrets
    }

    func loadProviders() throws -> ProviderStore {
        lock.lock()
        defer { lock.unlock() }
        let path = paths.providerStorePath
        guard fileManager.fileExists(atPath: path.path) else {
            return ProviderStore()
        }

        let data = try Data(contentsOf: path)
        do {
            var store = try JSONDecoder().decode(ProviderStore.self, from: data)
            hydrateSecrets(into: &store)
            return store
        } catch {
            // Corrupt provider store should not block the app; reset to empty.
            try? fileManager.removeItem(at: path)
            return ProviderStore()
        }
    }

    func saveProviders(_ store: ProviderStore) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(strippingSecrets(from: store))
        try writeAtomically(data: data, to: paths.providerStorePath)
    }

    // MARK: - Secrets

    /// Puts each secret back on the in-memory config.
    ///
    /// A file written before this migration still carries its secrets, and a
    /// keychain that refuses to answer leaves them there too, so the stored
    /// value wins whenever the keychain has nothing.
    private func hydrateSecrets(into store: inout ProviderStore) {
        for index in store.providers.indices {
            let id = store.providers[index].id
            if store.providers[index].apiKey.isEmpty,
               let key = secrets.read(account: ProviderSecretAccount.apiKey(providerID: id)) {
                store.providers[index].apiKey = key
            }
            if (store.providers[index].refreshToken ?? "").isEmpty,
               let token = secrets.read(account: ProviderSecretAccount.refreshToken(providerID: id)) {
                store.providers[index].refreshToken = token
            }
        }
    }

    /// Moves secrets into the keychain and blanks them for disk.
    ///
    /// A secret is only removed from the file once the keychain has confirmed
    /// it stored it. If the keychain is unavailable the value stays in the
    /// file exactly as before — degraded, but never lost.
    private func strippingSecrets(from store: ProviderStore) -> ProviderStore {
        var result = store
        for index in result.providers.indices {
            let provider = result.providers[index]
            if !provider.apiKey.isEmpty,
               secrets.write(account: ProviderSecretAccount.apiKey(providerID: provider.id), value: provider.apiKey) {
                result.providers[index].apiKey = ""
            }
            if let token = provider.refreshToken, !token.isEmpty,
               secrets.write(account: ProviderSecretAccount.refreshToken(providerID: provider.id), value: token) {
                result.providers[index].refreshToken = ""
            }
        }
        // Drop keychain entries for providers the user removed.
        let liveIDs = Set(result.providers.map(\.id))
        for id in removedProviderIDs(keeping: liveIDs) {
            secrets.delete(account: ProviderSecretAccount.apiKey(providerID: id))
            secrets.delete(account: ProviderSecretAccount.refreshToken(providerID: id))
        }
        return result
    }

    /// Ids present in the file on disk but absent from the store being saved.
    private func removedProviderIDs(keeping liveIDs: Set<String>) -> [String] {
        guard let data = try? Data(contentsOf: paths.providerStorePath),
              let previous = try? JSONDecoder().decode(ProviderStore.self, from: data) else {
            return []
        }
        return previous.providers.map(\.id).filter { !liveIDs.contains($0) }
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            Self.setPrivatePermissions(at: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
                Self.setPrivatePermissions(at: destination)
                return
            }
            throw AppError.io(L10n.tr("error.store.atomic_write_failed_format", error.localizedDescription))
        }
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}

/// Persists the third-party usage ledger (third-party-usage.json).
final class ThirdPartyUsageFileRepository: ThirdPartyUsageRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let lock = NSLock()

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadUsage() throws -> ThirdPartyUsageStore {
        lock.lock()
        defer { lock.unlock() }
        let path = paths.thirdPartyUsagePath
        guard fileManager.fileExists(atPath: path.path) else {
            return ThirdPartyUsageStore()
        }

        let data = try Data(contentsOf: path)
        do {
            return try JSONDecoder().decode(ThirdPartyUsageStore.self, from: data)
        } catch {
            try? fileManager.removeItem(at: path)
            return ThirdPartyUsageStore()
        }
    }

    func saveUsage(_ store: ThirdPartyUsageStore) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try writeAtomically(data: data, to: paths.thirdPartyUsagePath)
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            Self.setPrivatePermissions(at: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
                Self.setPrivatePermissions(at: destination)
                return
            }
            throw AppError.io(L10n.tr("error.store.atomic_write_failed_format", error.localizedDescription))
        }
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
