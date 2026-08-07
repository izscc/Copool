import XCTest
@testable import Copool

final class ProviderFileRepositoryTests: XCTestCase {
    private var tempDir: URL!
    private var paths: FileSystemPaths!
    /// Isolated keychain service so tests never touch real provider secrets.
    private let testService = "com.alick.copool.tests.providers"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )
    }

    override func tearDown() {
        let secrets = KeychainSecretStore(service: testService)
        for provider in providerIDs {
            secrets.delete(account: ProviderSecretAccount.apiKey(providerID: provider))
            secrets.delete(account: ProviderSecretAccount.refreshToken(providerID: provider))
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var providerIDs: [String] { ["provider-a", "provider-b"] }

    private func makeRepository() -> ProviderFileRepository {
        ProviderFileRepository(paths: paths, secrets: KeychainSecretStore(service: testService))
    }

    private func makeStore(providerID: String = "provider-a", apiKey: String = "sk-test", refreshToken: String? = "rt-test") -> ProviderStore {
        let provider = ProviderConfig(
            id: providerID,
            name: providerID,
            baseURL: "https://example.com/v1",
            apiKey: apiKey,
            refreshToken: refreshToken,
            authKind: .apiKey,
            models: [],
            modelProtocols: [:],
            defaultProtocol: .chat
        )
        return ProviderStore(providers: [provider])
    }

    func testSaveMovesSecretsToKeychainAndBlanksFile() throws {
        let repository = makeRepository()
        let store = makeStore()

        try repository.saveProviders(store)

        // The file on disk must not carry plaintext secrets.
        let diskData = try Data(contentsOf: paths.providerStorePath)
        let diskStore = try JSONDecoder().decode(ProviderStore.self, from: diskData)
        XCTAssertTrue(diskStore.providers[0].apiKey.isEmpty)
        XCTAssertTrue((diskStore.providers[0].refreshToken ?? "").isEmpty)

        // The keychain holds them.
        let secrets = KeychainSecretStore(service: testService)
        XCTAssertEqual(secrets.read(account: ProviderSecretAccount.apiKey(providerID: "provider-a")), "sk-test")
        XCTAssertEqual(secrets.read(account: ProviderSecretAccount.refreshToken(providerID: "provider-a")), "rt-test")
    }

    func testLoadRehydratesSecretsFromKeychain() throws {
        let repository = makeRepository()
        try repository.saveProviders(makeStore())

        let loaded = try repository.loadProviders()

        XCTAssertEqual(loaded.providers[0].apiKey, "sk-test")
        XCTAssertEqual(loaded.providers[0].refreshToken, "rt-test")
    }

    func testMigrateLegacySecretsIfNeededMovesPlaintextFile() throws {
        // Simulate a store written before the keychain migration: plaintext on
        // disk, nothing in the keychain.
        let legacy = """
        {
          "version": 1,
          "providers": [{
            "id": "provider-b",
            "name": "provider-b",
            "baseURL": "https://example.com/v1",
            "apiKey": "sk-legacy",
            "authKind": "apiKey",
            "models": [],
            "modelProtocols": {},
            "defaultProtocol": "chat",
            "addedAt": 0
          }]
        }
        """
        try legacy.write(to: paths.providerStorePath, atomically: true, encoding: .utf8)

        let repository = makeRepository()
        repository.migrateLegacySecretsIfNeeded()

        // After migration the keychain holds the secret…
        let secrets = KeychainSecretStore(service: testService)
        XCTAssertEqual(secrets.read(account: ProviderSecretAccount.apiKey(providerID: "provider-b")), "sk-legacy")

        // …and the file no longer does.
        let diskData = try Data(contentsOf: paths.providerStorePath)
        let diskStore = try JSONDecoder().decode(ProviderStore.self, from: diskData)
        XCTAssertTrue(diskStore.providers[0].apiKey.isEmpty)

        // Loading still yields the secret (rehydrated).
        XCTAssertEqual(try repository.loadProviders().providers[0].apiKey, "sk-legacy")
    }

    func testMigrateLegacySecretsIfNeededIsNoOpOnCleanStore() throws {
        // A store whose secrets are already in the keychain: file blanked.
        let repository = makeRepository()
        try repository.saveProviders(makeStore())
        // Wipe the keychain side to make the next load fall back to nothing.
        let secrets = KeychainSecretStore(service: testService)
        secrets.delete(account: ProviderSecretAccount.apiKey(providerID: "provider-a"))
        secrets.delete(account: ProviderSecretAccount.refreshToken(providerID: "provider-a"))

        // Second run must not resurrect plaintext into the file.
        repository.migrateLegacySecretsIfNeeded()
        let diskData = try Data(contentsOf: paths.providerStorePath)
        let diskStore = try JSONDecoder().decode(ProviderStore.self, from: diskData)
        XCTAssertTrue(diskStore.providers[0].apiKey.isEmpty)
    }

    func testSaveRemovedProviderCleansKeychain() throws {
        let repository = makeRepository()
        try repository.saveProviders(makeStore(providerID: "provider-a"))
        try repository.saveProviders(makeStore(providerID: "provider-b"))

        let secrets = KeychainSecretStore(service: testService)
        XCTAssertNil(secrets.read(account: ProviderSecretAccount.apiKey(providerID: "provider-a")))
        XCTAssertEqual(secrets.read(account: ProviderSecretAccount.apiKey(providerID: "provider-b")), "sk-test")
    }
}
