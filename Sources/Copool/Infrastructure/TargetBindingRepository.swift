import Foundation

final class TargetBindingRepository: TargetBindingRepositoryProtocol, @unchecked Sendable {
    private let path: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func load() throws -> TargetBindingStore {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: path.path) else {
            return TargetBindingStore.defaults
        }
        let data = try Data(contentsOf: path)
        return (try? JSONDecoder().decode(TargetBindingStore.self, from: data)) ?? TargetBindingStore.defaults
    }

    func save(_ store: TargetBindingStore) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        let temporary = path.deletingLastPathComponent()
            .appendingPathComponent(".target-bindings.tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .withoutOverwriting)
        #if canImport(Darwin)
        _ = chmod(temporary.path, S_IRUSR | S_IWUSR)
        #endif
        do {
            if fileManager.fileExists(atPath: path.path) {
                _ = try fileManager.replaceItemAt(path, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: path)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw AppError.io("Target binding store atomic write failed: \(error.localizedDescription)")
        }
    }
}
