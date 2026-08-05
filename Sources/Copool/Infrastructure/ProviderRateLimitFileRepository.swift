import Foundation

/// Persists passively harvested rate-limit snapshots (provider-rate-limits.json).
final class ProviderRateLimitFileRepository: @unchecked Sendable {
    private let path: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func loadSnapshots() -> [String: ProviderRateLimitSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let store = try? JSONDecoder().decode([String: ProviderRateLimitSnapshot].self, from: data) else {
            return [:]
        }
        return store
    }

    func record(_ snapshot: ProviderRateLimitSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadSnapshotsLocked()
        entries[snapshot.providerID] = snapshot
        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try writeAtomically(data: data)
        } catch {
            // Rate-limit telemetry must never break a request.
        }
    }

    private func loadSnapshotsLocked() -> [String: ProviderRateLimitSnapshot] {
        guard fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let store = try? JSONDecoder().decode([String: ProviderRateLimitSnapshot].self, from: data) else {
            return [:]
        }
        return store
    }

    private func writeAtomically(data: Data) throws {
        let tempURL = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(path, withItemAt: tempURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            try data.write(to: path, options: .atomic)
        }
        Self.setPrivatePermissions(at: path)
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
