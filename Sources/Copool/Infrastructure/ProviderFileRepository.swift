import Foundation

/// Persists the third-party provider configuration (providers.json).
final class ProviderFileRepository: ProviderStoreRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let lock = NSLock()

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
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
            return try JSONDecoder().decode(ProviderStore.self, from: data)
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
        let data = try encoder.encode(store)
        try writeAtomically(data: data, to: paths.providerStorePath)
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
