import XCTest
@testable import Copool

/// Phase 7 acceptance: session index sync + dedupe (AC-105), generic target
/// adapter isolation and rollback for Beta bindings.
final class SessionAndTargetTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Session sync & dedupe (AC-105)

    func testSessionSyncImportsNamesAndDedupes() {
        // Codex index with two sessions.
        let indexPath = tempDir.appendingPathComponent("session_index.jsonl")
        let index = """
        {"id":"thread-aaa","thread_name":"Refactor phase","updated_at":"1786000000"}
        {"id":"thread-bbb","thread_name":"Debug proxy","updated_at":"1786000100"}
        """
        try! index.write(to: indexPath, atomically: true, encoding: .utf8)

        let storePath = tempDir.appendingPathComponent("sessions.json")
        // Pre-existing store has thread-aaa under a different name.
        let store = SessionStore(sessions: [
            SessionRecord(targetSessionID: "thread-aaa", targetID: "codex", displayName: "Old name", turnCount: 3)
        ])
        let encoder = JSONEncoder()
        try! encoder.encode(store).write(to: storePath)

        let repo = SessionIndexRepository(indexPath: indexPath, storePath: storePath)
        let sessions = repo.sync()

        XCTAssertEqual(sessions.count, 2)
        let aaa = sessions.first { $0.targetSessionID == "thread-aaa" }
        XCTAssertEqual(aaa?.displayName, "Refactor phase", "index name should win")
        XCTAssertEqual(aaa?.turnCount, 3, "existing record fields preserved")
        XCTAssertTrue(sessions.contains { $0.targetSessionID == "thread-bbb" })

        // Dedupe: syncing again must not duplicate.
        let again = repo.sync()
        XCTAssertEqual(again.count, 2)
    }

    func testSessionDedupeKeyedByTargetAndSession() {
        let storePath = tempDir.appendingPathComponent("sessions.json")
        let repo = SessionIndexRepository(indexPath: tempDir.appendingPathComponent("missing-index.jsonl"), storePath: storePath)
        // Two targets may share the same session id — keys must not collide.
        let store = SessionStore(sessions: [
            SessionRecord(targetSessionID: "s-1", targetID: "codex", displayName: "A"),
            SessionRecord(targetSessionID: "s-1", targetID: "cursor", displayName: "B"),
        ])
        let encoder = JSONEncoder()
        try! encoder.encode(store).write(to: storePath)

        let sessions = repo.sync()
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Generic target adapter (Beta bindings)

    private func makeAdapter(targetID: String = "cursor") -> TargetConfigFileAdapter {
        TargetConfigFileAdapter(
            targetID: targetID,
            configPath: tempDir.appendingPathComponent("\(targetID).json"),
            stateRoot: tempDir.appendingPathComponent("targets", isDirectory: true),
            managedProviderID: "copool",
            providerBlockName: "Copool"
        )
    }

    func testGenericAdapterCycleAndIsolation() throws {
        let adapter = makeAdapter(targetID: "cursor")
        // User config before any managed write.
        let userConfig = """
        {
          "models": { "default": "claude" },
          "userSetting": true
        }
        """
        try! userConfig.write(to: tempDir.appendingPathComponent("cursor.json"), atomically: true, encoding: .utf8)

        let desired = adapter.desiredConfig(port: 19787, baseURLTemplate: "http://127.0.0.1:%d/v1")
        let diff = adapter.plan(to: desired)
        try adapter.apply(diff)
        XCTAssertTrue(adapter.verify(diff))

        let applied = try String(contentsOf: tempDir.appendingPathComponent("cursor.json"), encoding: .utf8)
        XCTAssertTrue(applied.contains("copool-managed"))
        XCTAssertTrue(applied.contains("\"userSetting\": true"), "user content preserved")

        // Isolation: the codex adapter state is separate — rolling back this
        // adapter only restores cursor.json.
        try adapter.rollback(diff)
        let restored = try String(contentsOf: tempDir.appendingPathComponent("cursor.json"), encoding: .utf8)
        XCTAssertEqual(restored, userConfig)
        XCTAssertFalse(restored.contains("copool-managed"))
    }

    func testGenericAdapterUninstallStripsBlocks() throws {
        let adapter = makeAdapter(targetID: "opencode")
        try! "user line".write(to: tempDir.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        let desired = adapter.desiredConfig(port: 20787, baseURLTemplate: "http://127.0.0.1:%d/v1")
        try adapter.apply(adapter.plan(to: desired))
        try adapter.uninstall()
        let stripped = try String(contentsOf: tempDir.appendingPathComponent("opencode.json"), encoding: .utf8)
        XCTAssertTrue(stripped.contains("user line"))
        XCTAssertFalse(stripped.contains("copool-managed"))
    }

    func testTargetConfigFileAdapterNeverCarriesSecrets() {
        let adapter = makeAdapter()
        let desired = adapter.desiredConfig(port: 19787, baseURLTemplate: "http://127.0.0.1:%d/v1")
        XCTAssertFalse(desired.lowercased().contains("authorization"))
        XCTAssertFalse(desired.contains("sk-"))
        XCTAssertFalse(desired.contains("Bearer"))
    }
}
