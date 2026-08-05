import XCTest
@testable import Copool

/// Phase 4 acceptance: AC-007 (target detect/plan/apply/verify/rollback),
/// user config preservation, failure recovery, AC-009 (browser origin
/// rejection), support bundle redaction.
final class TargetConfigContractTests: XCTestCase {
    private var tempDir: URL!
    private var paths: FileSystemPaths!
    private var adapter: CodexTargetAdapter!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            providerStorePath: tempDir.appendingPathComponent("providers.json"),
            registryV2Path: tempDir.appendingPathComponent("provider-registry-v2.json"),
            migrationJournalPath: tempDir.appendingPathComponent("migration-journal.json"),
            thirdPartyUsagePath: tempDir.appendingPathComponent("usage.json"),
            providerRateLimitsPath: tempDir.appendingPathComponent("rate-limits.json"),
            usageEventsPath: tempDir.appendingPathComponent("usage-events.jsonl"),
            agentStorePath: tempDir.appendingPathComponent("agents.json"),
            agentRouteEventsPath: tempDir.appendingPathComponent("agent-routes.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            codexModelsCachePath: tempDir.appendingPathComponent("models_cache.json"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )
        adapter = CodexTargetAdapter(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeConfig(_ text: String) {
        try! text.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)
    }

    // MARK: - AC-007: full cycle

    func testDetectPlanApplyVerifyRollbackCycle() throws {
        writeConfig("""
        model = "gpt-5.4"
        # user's own comment
        [hooks]
        enabled = true
        """)

        // detect
        let detected = adapter.detect()
        XCTAssertNotNil(detected)
        XCTAssertTrue(detected!.content.contains("user's own comment"))

        // plan
        let desired = adapter.desiredConfig(port: 8787)
        XCTAssertTrue(desired.contains("model_provider = \"opencodex\""))
        XCTAssertTrue(desired.contains("[model_providers.opencodex]"))
        XCTAssertTrue(desired.contains("base_url = \"http://127.0.0.1:8787/v1\""))
        let diff = adapter.plan(to: desired)
        XCTAssertEqual(diff.preservedUserLines.count >= 3, true)

        // apply
        try adapter.apply(diff)
        let applied = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertEqual(applied, desired)

        // user lines survived
        XCTAssertTrue(applied.contains("model = \"gpt-5.4\""))
        XCTAssertTrue(applied.contains("user's own comment"))
        XCTAssertTrue(applied.contains("[hooks]"))

        // verify
        XCTAssertTrue(adapter.verify(diff))

        // rollback
        try adapter.rollback(diff)
        let restored = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertTrue(restored.contains("user's own comment"))
        XCTAssertFalse(restored.contains("opencodex"))
    }

    func testApplyFailureKeepsOriginalFile() throws {
        // Simulate an unwritable config path: apply must not corrupt the file.
        writeConfig("original content")
        let original = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)

        // Make the parent read-only so the temp write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.codexConfigPath.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.codexConfigPath.deletingLastPathComponent().path) }

        let diff = adapter.plan(to: "should not land")
        XCTAssertThrowsError(try adapter.apply(diff))
        let after = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertEqual(after, original, "apply failure must leave the original file intact")
    }

    func testRollbackRestoresManagedConfig() throws {
        writeConfig("user line")
        let desired = adapter.desiredConfig(port: 8787)
        let diff = adapter.plan(to: desired)
        try adapter.apply(diff)
        // Corrupt the config.
        writeConfig("corrupted")
        try adapter.rollback(diff)
        let restored = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertEqual(restored, desired)
    }

    func testUninstallStripsManagedBlocks() throws {
        writeConfig("user line")
        let desired = adapter.desiredConfig(port: 8787)
        try adapter.apply(adapter.plan(to: desired))
        try adapter.uninstall()
        let stripped = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertTrue(stripped.contains("user line"))
        XCTAssertFalse(stripped.contains("opencodex"))
        XCTAssertFalse(stripped.contains("copool managed"))
    }

    // MARK: - AC-009 helpers (proxy-level origin check is integration)

    func testDesiredConfigNeverCarriesSecrets() {
        let desired = adapter.desiredConfig(port: 8787)
        XCTAssertFalse(desired.lowercased().contains("authorization"))
        XCTAssertFalse(desired.contains("Bearer"))
        XCTAssertFalse(desired.contains("sk-"))
    }

    // MARK: - Redaction

    func testSecretRedactorScrubsCredentials() {
        let text = """
        Authorization: Bearer abc123def456ghi789jkl012mno345
        api_key: "sk-proj-abcdefghijklmnopqrstuvwx"
        "refresh_token": "rt-verysecretvalue123456"
        """
        let redacted = SecretRedactor.redactText(text)
        XCTAssertFalse(redacted.contains("abc123def456ghi789jkl012mno345"))
        XCTAssertFalse(redacted.contains("sk-proj-abcdefghijklmnopqrstuvwx"))
        XCTAssertFalse(redacted.contains("rt-verysecretvalue123456"))
        XCTAssertTrue(redacted.contains("REDACTED"))
    }

    func testSecretRedactorHeaderNames() {
        XCTAssertEqual(SecretRedactor.redactHeader("Authorization", value: "Bearer secret123"), "REDACTED")
        XCTAssertEqual(SecretRedactor.redactHeader("X-Custom", value: "ok"), "ok")
    }

    func testSupportBundleCarriesReferencesNotValues() async {
        let bundleText = await SupportBundleBuilder(paths: paths).build(
            providers: [
                ProviderConfig(id: "p-1", name: "grok", baseURL: "https://api.x.ai/v1", apiKey: "sk-super-secret", authKind: .apiKey)
            ],
            engineStatus: RouterEngineStatus(running: true, port: 8787, apiKey: "proxy-key-123", baseURL: "http://127.0.0.1:8787/v1", availableAccounts: 2, activeAccountID: "acc-1", activeAccountLabel: "A", lastError: "Bearer tok1234567890")
        )
        XCTAssertFalse(bundleText.contains("sk-super-secret"))
        XCTAssertFalse(bundleText.contains("proxy-key-123"))
        XCTAssertFalse(bundleText.contains("tok1234567890"))
        XCTAssertTrue(bundleText.contains("keychain:"))
        XCTAssertTrue(bundleText.contains("REDACTED"))
    }
}
