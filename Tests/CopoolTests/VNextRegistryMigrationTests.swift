import XCTest
@testable import Copool

/// Phase 2 acceptance: AC-003 (no persistent secret), AC-004 (migration
/// journal, shadow verify, idempotence), AC-005 (stable route keys).
final class VNextRegistryMigrationTests: XCTestCase {
    private var tempDir: URL!
    private var registryPath: URL!
    private var journalPath: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registryPath = tempDir.appendingPathComponent("provider-registry-v2.json")
        journalPath = tempDir.appendingPathComponent("migration-journal.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeRepository() -> ProviderRegistryV2Repository {
        ProviderRegistryV2Repository(registryPath: registryPath, journalPath: journalPath)
    }

    private func makeV1Store(providerName: String = "antigravity", providerID: String = "fixed-uuid-0001") -> ProviderStore {
        ProviderStore(providers: [
            ProviderConfig(
                id: providerID,
                name: providerName,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKey: "sk-should-never-persist-12345",
                refreshToken: "rt-should-never-persist-67890",
                authKind: .subscriptionImport,
                models: [
                    ProviderModel(
                        id: "gemini-3.6-flash-high",
                        displayName: nil,
                        contextWindow: 1_048_576,
                        contextWindowSource: .provider,
                        supportedReasoningEfforts: ["low", "medium", "high"],
                        defaultReasoningEffort: "medium",
                        reasoningSource: .provider
                    )
                ],
                modelProtocols: ["gemini-3.6-flash-high": .google],
                defaultProtocol: .google
            )
        ])
    }

    // MARK: - AC-003: no secret value in persisted encoding

    func testProviderConfigEncodingContainsNoSecretValues() throws {
        let provider = makeV1Store().providers[0]
        let data = try JSONEncoder().encode(provider)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-should-never-persist-12345"))
        XCTAssertFalse(text.contains("rt-should-never-persist-67890"))
        XCTAssertFalse(text.contains("apiKey"))
        XCTAssertFalse(text.contains("refreshToken"))
    }

    func testV2RegistryEncodingContainsNoSecretValues() throws {
        let service = RegistryMigrationService(repository: makeRepository())
        let outcome = service.migrateIfNeeded(v1: makeV1Store())
        guard case .migrated = outcome else {
            return XCTFail("expected migrated, got \(outcome)")
        }

        let data = try Data(contentsOf: registryPath)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-should-never-persist-12345"), "apiKey leaked into v2")
        XCTAssertFalse(text.contains("rt-should-never-persist-67890"), "refreshToken leaked into v2")
        XCTAssertTrue(text.contains("keychainAccount"), "credential should be a keychain reference")
    }

    func testCredentialIdentityHasNoValueField() {
        let identity = CredentialIdentity(
            id: "cred-1",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "some-account"),
            source: .userEntered,
            scopes: [],
            expiresAt: nil,
            lastVerifiedAt: nil
        )
        // Type-level guarantee: no `value`/`secret` property exists.
        // Encoding must only carry the reference name.
        let data = try! JSONEncoder().encode(identity)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("some-account"))
        XCTAssertFalse(text.contains("\"value\""))
        XCTAssertFalse(text.contains("\"secret\""))
    }

    // MARK: - AC-004: migration journal, verify, idempotence

    func testMigrationJournalRecordsVerifiedEntry() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)
        let outcome = service.migrateIfNeeded(v1: makeV1Store())
        guard case .migrated = outcome else { return XCTFail("expected migrated") }

        let journal = repository.loadJournal()
        XCTAssertEqual(journal.entries.count, 1)
        XCTAssertTrue(journal.entries[0].verified)
        XCTAssertTrue(journal.entries[0].shadowed)
        XCTAssertEqual(journal.entries[0].fromVersion, 1)
        XCTAssertEqual(journal.entries[0].toVersion, ProviderRegistryV2.currentVersion)
    }

    func testMigrationIsIdempotent() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)

        XCTAssertEqual(service.migrateIfNeeded(v1: makeV1Store()), .migrated)
        // Second run with the same v1 store: journal gate.
        XCTAssertEqual(service.migrateIfNeeded(v1: makeV1Store()), .alreadyMigrated)
        // Journal still has exactly one entry.
        XCTAssertEqual(repository.loadJournal().entries.count, 1)
    }

    func testRollbackRemovesRegistryAndIsReversible() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)
        let store = makeV1Store()
        _ = service.migrateIfNeeded(v1: store)
        XCTAssertFalse(repository.loadRegistry().instances.isEmpty)

        let sourceHash = RegistryMigrationService.sourceHash(of: store)
        // Unknown hash → nothing to roll back.
        XCTAssertFalse(service.rollbackMigration(sourceHash: "no-such-hash"))
        // Real rollback: v2 file gone, journal entry flipped.
        XCTAssertTrue(service.rollbackMigration(sourceHash: sourceHash))
        XCTAssertTrue(repository.loadRegistry().instances.isEmpty)
        XCTAssertEqual(repository.loadJournal().entries.last?.rolledBack, true)
        // Idempotent: second rollback is a no-op success.
        XCTAssertTrue(service.rollbackMigration(sourceHash: sourceHash))
        // Migration re-runs after rollback and recreates the registry.
        XCTAssertEqual(service.migrateIfNeeded(v1: store), .migrated)
        XCTAssertFalse(repository.loadRegistry().instances.isEmpty)
    }

    func testMigrationPreservesInstancesAndCatalog() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)
        _ = service.migrateIfNeeded(v1: makeV1Store())

        let registry = repository.loadRegistry()
        XCTAssertEqual(registry.instances.count, 1)
        XCTAssertEqual(registry.instances[0].id, "fixed-uuid-0001")
        XCTAssertEqual(registry.instances[0].definitionID, "antigravity")
        XCTAssertEqual(registry.catalog.count, 1)
        XCTAssertEqual(registry.catalog[0].id, "fixed-uuid-0001/gemini-3.6-flash-high")
        XCTAssertEqual(registry.catalog[0].capabilities.contextWindow, 1_048_576)
        XCTAssertEqual(registry.catalog[0].metadataSources["contextWindow"], .provider)
    }

    // MARK: - AC-005: route keys independent of displayName

    func testRenamingProviderDoesNotChangeStableKeys() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)
        _ = service.migrateIfNeeded(v1: makeV1Store(providerName: "antigravity"))

        // Rename the provider in v1 and migrate a second store (different
        // source hash → separate journal entry). The same stable id must be
        // updated in place, never duplicated.
        let renamed = makeV1Store(providerName: "AGY Beta")
        _ = service.migrateIfNeeded(v1: renamed)

        let registry = repository.loadRegistry()
        let instanceIDs = Set(registry.instances.map(\.id))
        XCTAssertEqual(instanceIDs, ["fixed-uuid-0001"])
        XCTAssertEqual(registry.instances.first?.displayName, "AGY Beta")
        let catalogIDs = Set(registry.catalog.map(\.id))
        XCTAssertTrue(catalogIDs.contains("fixed-uuid-0001/gemini-3.6-flash-high"))
        XCTAssertEqual(registry.instances.count, 1)
    }

    func testLegacyNameMatchesButStableRouteUsesID() {
        let provider = makeV1Store(providerName: "Friendly Name").providers[0]
        let model = provider.models[0].id
        XCTAssertEqual(provider.clientModelID(for: model), "fixed-uuid-0001/\(model)")
        XCTAssertNotEqual(provider.clientModelID(for: model), provider.legacyClientModelID(for: model))
        XCTAssertTrue(provider.matchesClientModel("friendly name/\(model)", backendModel: model))
        XCTAssertTrue(provider.matchesClientModel("fixed-uuid-0001/\(model)", backendModel: model))
    }

    func testDefinitionMatchingFallsBackToUserOverlay() {
        let repository = makeRepository()
        let service = RegistryMigrationService(repository: repository)
        let store = ProviderStore(providers: [
            ProviderConfig(id: "custom-1", name: "My Custom LLM", baseURL: "https://llm.example.com/v1", apiKey: "k", authKind: .apiKey)
        ])
        _ = service.migrateIfNeeded(v1: store)

        let registry = repository.loadRegistry()
        let definition = registry.definition(id: "custom-custom-1")
        XCTAssertNotNil(definition)
        XCTAssertEqual(definition?.isBuiltIn, false)
        XCTAssertEqual(definition?.ownership, "user")
    }
}
