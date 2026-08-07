import Foundation

struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var targetSessionID: String
    var targetID: String
    var source: Source
    var displayName: String?
    var modelEntryID: String?
    var startedAt: Int64
    var updatedAt: Int64
    var lastTaskSummary: String?
    var turnCount: Int
    var status: Status

    enum Source: String, Codable, Equatable, Sendable {
        case codex
        case copool
        case externalAgent
    }

    enum Status: String, Codable, Equatable, Sendable {
        case active
        case paused
        case archived
    }

    init(
        id: String = UUID().uuidString,
        targetSessionID: String,
        targetID: String,
        source: Source = .codex,
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
        self.source = source
        self.displayName = displayName
        self.modelEntryID = modelEntryID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastTaskSummary = lastTaskSummary
        self.turnCount = turnCount
        self.status = status
    }
}

struct SessionImportPreview: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sourcePath: String
    var source: SessionRecord.Source
    var recordCount: Int
    var mappedFields: [String]
    var droppedFields: [String]
}

protocol SessionImportAdapter: Sendable {
    var source: SessionRecord.Source { get }
    func preview() -> SessionImportPreview
    func importRecords() -> [SessionRecord]
}

struct JSONLSessionImportAdapter: SessionImportAdapter {
    let source: SessionRecord.Source
    let path: URL
    let targetID: String

    func preview() -> SessionImportPreview {
        let records = importRecords()
        return SessionImportPreview(
            id: "\(source.rawValue):\(path.path)",
            sourcePath: path.path,
            source: source,
            recordCount: records.count,
            mappedFields: ["id", "displayName", "updatedAt"],
            droppedFields: ["raw transcript", "attachments", "tool arguments"]
        )
    }

    func importRecords() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: path) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                let name = object["thread_name"] as? String ?? object["name"] as? String
                let updated = (object["updated_at"] as? String).flatMap(Double.init).map(Int64.init)
                    ?? (object["updatedAt"] as? NSNumber)?.int64Value
                    ?? 0
                return SessionRecord(
                    targetSessionID: id,
                    targetID: targetID,
                    source: source,
                    displayName: name,
                    updatedAt: updated
                )
            }
    }
}

struct SessionStore: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version: Int
    var sessions: [SessionRecord]

    init(version: Int = SessionStore.currentVersion, sessions: [SessionRecord] = []) {
        self.version = version
        self.sessions = sessions
    }
}

struct SessionIndexRepository: Sendable {
    var indexPath: URL
    var storePath: URL
    var adapters: [any SessionImportAdapter]

    init(
        indexPath: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl"),
        storePath: URL,
        adapters: [any SessionImportAdapter] = []
    ) {
        self.indexPath = indexPath
        self.storePath = storePath
        self.adapters = adapters
    }

    func sync() -> [SessionRecord] {
        let stored = loadStore()
        let codex = JSONLSessionImportAdapter(source: .codex, path: indexPath, targetID: "codex").importRecords()
        let imported = adapters.flatMap { $0.importRecords() }
        var byKey: [String: SessionRecord] = [:]
        for session in stored + codex + imported {
            let key = "\(session.targetID)|\(session.targetSessionID)"
            if let current = byKey[key], current.updatedAt >= session.updatedAt { continue }
            byKey[key] = session
        }
        let merged = byKey.values.sorted { $0.updatedAt > $1.updatedAt }
        try? persist(merged)
        return merged
    }

    func importPreviews() -> [SessionImportPreview] {
        [JSONLSessionImportAdapter(source: .codex, path: indexPath, targetID: "codex").preview()]
            + adapters.map { $0.preview() }
    }

    func loadStore() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: storePath),
              let store = try? JSONDecoder().decode(SessionStore.self, from: data) else { return [] }
        return store.sessions
    }

    private func persist(_ sessions: [SessionRecord]) throws {
        try FileManager.default.createDirectory(at: storePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SessionStore(sessions: sessions)).write(to: storePath, options: .atomic)
    }
}
