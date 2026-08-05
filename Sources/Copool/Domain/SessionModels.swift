import Foundation

// MARK: - Session domain (Phase 7)

/// One recorded session across targets (PRD: Session 1---* TargetBinding;
/// *---1 ModelCatalogEntry; *---0..1 Credential).
struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// Thread/session id as the target app knows it.
    var targetSessionID: String
    var targetID: String
    var displayName: String?
    var modelEntryID: String?
    var startedAt: Int64
    var updatedAt: Int64
    var lastTaskSummary: String?
    var turnCount: Int
    var status: Status

    enum Status: String, Codable, Equatable, Sendable {
        case active
        case paused
        case archived
    }

    init(
        id: String = UUID().uuidString,
        targetSessionID: String,
        targetID: String,
        displayName: String? = nil,
        modelEntryID: String? = nil,
        startedAt: Int64 = Int64(Date().timeIntervalSince1970),
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970),
        lastTaskSummary: String? = nil,
        turnCount: Int = 0,
        status: Status = .active
    ) {
        self.id = id
        self.targetSessionID = targetSessionID
        self.targetID = targetID
        self.displayName = displayName
        self.modelEntryID = modelEntryID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastTaskSummary = lastTaskSummary
        self.turnCount = turnCount
        self.status = status
    }
}

struct SessionStore: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var sessions: [SessionRecord]

    init(version: Int = SessionStore.currentVersion, sessions: [SessionRecord] = []) {
        self.version = version
        self.sessions = sessions
    }
}

/// Indexes sessions from Codex's `session_index.jsonl` (display names) and
/// merges them with our own session ledger, deduping by
/// (targetID, targetSessionID).
struct SessionIndexRepository: Sendable {
    var indexPath: URL
    var storePath: URL

    init(
        indexPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl"),
        storePath: URL
    ) {
        self.indexPath = indexPath
        self.storePath = storePath
    }

    /// Reads the store, merges names from the Codex index (newest first),
    /// dedupes and persists. Returns the merged sessions.
    func sync() -> [SessionRecord] {
        var sessions = loadStore()

        // Import names from the Codex index.
        let indexed = codexIndexEntries()
        var byKey: [String: (name: String, updatedAt: Int64)] = [:]
        for entry in indexed {
            byKey[entry.key] = (entry.name, entry.updatedAt)
        }

        var merged: [SessionRecord] = []
        var seen: Set<String> = []
        for var session in sessions {
            let key = "\(session.targetID)|\(session.targetSessionID)"
            if let index = byKey[key] {
                session.displayName = index.name
                session.updatedAt = max(session.updatedAt, index.updatedAt)
                seen.insert(key)
            }
            merged.append(session)
        }
        // New sessions from the index (not yet in our store).
        for entry in indexed where !seen.contains(entry.key) {
            let parts = entry.key.split(separator: "|")
            guard parts.count == 2 else { continue }
            merged.append(
                SessionRecord(
                    targetSessionID: String(parts[1]),
                    targetID: String(parts[0]),
                    displayName: entry.name,
                    updatedAt: entry.updatedAt
                )
            )
        }

        merged.sort { $0.updatedAt > $1.updatedAt }
        try? persist(merged)
        return merged
    }

    /// Codex index entries: thread id → display name + updated_at.
    func codexIndexEntries() -> [(key: String, name: String, updatedAt: Int64)] {
        guard let data = try? Data(contentsOf: indexPath) else { return [] }
        var entries: [(key: String, name: String, updatedAt: Int64)] = []
        for line in String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? [] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String else {
                continue
            }
            let updated = (object["updated_at"] as? String)
                .flatMap { Double($0) }
                .map { Int64($0) } ?? 0
            entries.append((key: "codex|\(id)", name: name, updatedAt: updated))
        }
        return entries
    }

    func loadStore() -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: storePath.path),
              let data = try? Data(contentsOf: storePath),
              let store = try? JSONDecoder().decode(SessionStore.self, from: data) else {
            return []
        }
        return store.sessions
    }

    private func persist(_ sessions: [SessionRecord]) throws {
        try FileManager.default.createDirectory(at: storePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SessionStore(sessions: sessions))
        try data.write(to: storePath, options: .atomic)
    }
}
