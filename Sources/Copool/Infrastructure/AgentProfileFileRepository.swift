import Foundation

/// Persists Agent Profiles, routing settings (agents.json) and the routing
/// activity log (agent-routes.json).
final class AgentProfileFileRepository: AgentProfileRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let lock = NSLock()

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadAgents() throws -> AgentProfileStore {
        lock.lock()
        defer { lock.unlock() }
        return load(AgentProfileStore.self, from: paths.agentStorePath) ?? AgentProfileStore()
    }

    func saveAgents(_ store: AgentProfileStore) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(store, to: paths.agentStorePath)
    }

    func loadRouteEvents() throws -> AgentRouteEventStore {
        lock.lock()
        defer { lock.unlock() }
        return load(AgentRouteEventStore.self, from: paths.agentRouteEventsPath) ?? AgentRouteEventStore()
    }

    func appendRouteEvent(_ event: AgentRouteEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = load(AgentRouteEventStore.self, from: paths.agentRouteEventsPath) ?? AgentRouteEventStore()
        store.append(event)
        try write(store, to: paths.agentRouteEventsPath)
    }

    // MARK: - Storage

    /// A corrupt store must not brick the app, but it also must not be
    /// silently destroyed: keep the bad file aside so it can be inspected.
    private func load<T: Decodable>(_ type: T.Type, from path: URL) -> T? {
        guard fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else {
            return nil
        }
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        let quarantine = path.appendingPathExtension("corrupt")
        try? fileManager.removeItem(at: quarantine)
        try? fileManager.moveItem(at: path, to: quarantine)
        return nil
    }

    private func write<T: Encodable>(_ value: T, to destination: URL) throws {
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

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
