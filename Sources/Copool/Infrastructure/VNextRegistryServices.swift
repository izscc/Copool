import Foundation

/// Data-driven built-in provider registry (PRD: "registry is data-driven;
/// model lists come from live discovery, not hardcoded research snapshots").
///
/// Definitions carry no user data and no secrets; model lists are deliberately
/// NOT seeded here — discovery/curation populates them at runtime.
enum BuiltInProviderRegistry {
    static let all: [ProviderDefinition] = [
        ProviderDefinition(
            id: "deepseek",
            displayName: "DeepSeek",
            ownership: "deepseek",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.deepseek.com/v1",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "qwen",
            displayName: "Qwen",
            ownership: "alibaba",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "zai",
            displayName: "Z.ai",
            ownership: "zai",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.z.ai/api/v1",
            credentialKinds: [.apiKey, .oauth],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "minimax",
            displayName: "MiniMax",
            ownership: "minimax",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.minimax.chat/v1",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "kimi",
            displayName: "Kimi",
            ownership: "moonshot",
            supportedProtocols: [.chat, .responses],
            defaultBaseURL: "https://api.moonshot.cn/v1",
            credentialKinds: [.apiKey, .oauth],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "openrouter",
            displayName: "OpenRouter",
            ownership: "openrouter",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://openrouter.ai/api/v1",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "volcengine",
            displayName: "火山方舟",
            ownership: "volcengine",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "anthropic",
            displayName: "Anthropic",
            ownership: "anthropic",
            supportedProtocols: [.anthropic],
            defaultBaseURL: "https://api.anthropic.com",
            credentialKinds: [.apiKey, .oauth, .subscriptionImport],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "google",
            displayName: "Google Gemini",
            ownership: "google",
            supportedProtocols: [.google],
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            credentialKinds: [.apiKey, .oauth, .subscriptionImport],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "antigravity",
            displayName: "Antigravity",
            ownership: "google",
            supportedProtocols: [.google],
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            credentialKinds: [.subscriptionImport, .oauth],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "grok",
            displayName: "Grok",
            ownership: "xai",
            supportedProtocols: [.chat, .responses],
            defaultBaseURL: "https://api.x.ai/v1",
            credentialKinds: [.apiKey, .oauth, .subscriptionImport],
            isBuiltIn: true
        ),
    ]

    static func definition(id: String) -> ProviderDefinition? {
        all.first { $0.id == id }
    }
}

/// Persists the v2 registry (provider-registry-v2.json) and its migration
/// journal (migration-journal.json) with atomic writes.
final class ProviderRegistryV2Repository: @unchecked Sendable {
    private let registryPath: URL
    private let journalPath: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(registryPath: URL, journalPath: URL, fileManager: FileManager = .default) {
        self.registryPath = registryPath
        self.journalPath = journalPath
        self.fileManager = fileManager
    }

    func loadRegistry() -> ProviderRegistryV2 {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: registryPath.path),
              let data = try? Data(contentsOf: registryPath),
              let registry = try? JSONDecoder().decode(ProviderRegistryV2.self, from: data) else {
            return ProviderRegistryV2()
        }
        return registry
    }

    func saveRegistry(_ registry: ProviderRegistryV2) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: registryPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try writeAtomically(data: data, to: registryPath)
    }

    func loadJournal() -> MigrationJournal {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: journalPath.path),
              let data = try? Data(contentsOf: journalPath),
              let journal = try? JSONDecoder().decode(MigrationJournal.self, from: data) else {
            return MigrationJournal()
        }
        return journal
    }

    func appendJournalEntry(_ entry: MigrationEntry) {
        lock.lock()
        defer { lock.unlock() }
        var journal = loadJournalLocked()
        journal.entries.append(entry)
        try? fileManager.createDirectory(at: journalPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(journal) {
            try? writeAtomically(data: data, to: journalPath)
        }
    }

    private func loadJournalLocked() -> MigrationJournal {
        guard fileManager.fileExists(atPath: journalPath.path),
              let data = try? Data(contentsOf: journalPath),
              let journal = try? JSONDecoder().decode(MigrationJournal.self, from: data) else {
            return MigrationJournal()
        }
        return journal
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            try data.write(to: destination, options: .atomic)
        }
        Self.setPrivatePermissions(at: destination)
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}

/// v1 ProviderStore → v2 ProviderRegistryV2 migration with shadow write,
/// verify, journal and idempotence (AC-004).
///
/// Strategy:
///   1. Compute a stable sourceHash of the v1 store.
///   2. If the journal already records a verified migration for that hash,
///      skip (idempotent — re-running after a crash is safe).
///   3. Build the v2 registry: instances keep their v1 UUID as the stable
///      route key; credentials become CredentialIdentity references (the
///      values themselves stay in the keychain under the legacy account
///      names, so nothing is moved at migration time).
///   4. Shadow-write the v2 file, read it back and verify, then journal.
final class RegistryMigrationService: Sendable {
    private let repository: ProviderRegistryV2Repository
    private let keychainService: String
    private let now: @Sendable () -> Int64

    init(
        repository: ProviderRegistryV2Repository,
        keychainService: String = "com.alick.copool.providers",
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.repository = repository
        self.keychainService = keychainService
        self.now = now
    }

    enum MigrationOutcome: Equatable, Sendable {
        case migrated
        case alreadyMigrated
        case nothingToMigrate
        case failed(String)
    }

    /// Migrates one v1 store into the v2 registry. Idempotent and safe to
    /// re-run (journal + sourceHash gate). Never throws: failures surface as
    /// `.failed` so the caller can decide.
    func migrateIfNeeded(v1 store: ProviderStore) -> MigrationOutcome {
        guard !store.providers.isEmpty else { return .nothingToMigrate }

        let sourceHash = Self.sourceHash(of: store)
        if let last = repository.loadJournal().lastEntry(sourceHash: sourceHash),
           last.verified, last.rolledBack != true {
            return .alreadyMigrated
        }

        var registry = repository.loadRegistry()

        for provider in store.providers {
            // Stable id: v1 UUID inherited as the v2 route key (AC-005).
            let instanceID = provider.id.isEmpty ? UUID().uuidString : provider.id

            // Definition: match by name/endpoint heuristics, else user overlay.
            let definition = Self.matchDefinition(for: provider)
            if !registry.definitions.contains(where: { $0.id == definition.id }) {
                registry.definitions.append(definition)
            }

            // Credential reference only — the values live in the keychain
            // under the legacy account names and are never encoded here.
            var credential = CredentialIdentity(
                id: "cred-\(instanceID)",
                kind: Self.credentialKind(of: provider),
                secureReference: SecureReference(
                    storage: .keychainAccount,
                    name: ProviderSecretAccount.apiKey(providerID: instanceID)
                ),
                source: provider.authKind == .subscriptionImport ? .importedFromApp : .userEntered,
                scopes: [],
                expiresAt: nil,
                lastVerifiedAt: nil
            )
            // v1 stores keychain accounts under the v1 provider id; keep the
            // reference pointing at the real account name when it differs.
            if provider.id != instanceID {
                credential.secureReference?.name = ProviderSecretAccount.apiKey(providerID: provider.id)
            }
            if !registry.credentials.contains(where: { $0.id == credential.id }) {
                registry.credentials.append(credential)
            }

            if !registry.instances.contains(where: { $0.id == instanceID }) {
                registry.instances.append(
                    ProviderInstance(
                        id: instanceID,
                        definitionID: definition.id,
                        displayName: provider.name,
                        endpoint: provider.baseURL,
                        credentialID: credential.id,
                        protocolBindings: Dictionary(
                            uniqueKeysWithValues: provider.modelProtocols.map { ($0.key, APIDialect($0.value)) }
                        ),
                        defaultProtocol: APIDialect(provider.defaultProtocol),
                        enabled: true,
                        addedAt: provider.addedAt
                    )
                )
            }

            // Catalog: model entries keyed by instance + backend model.
            for model in provider.models {
                let entry = ModelCatalogEntry(
                    providerInstanceID: instanceID,
                    backendModelID: model.id,
                    displayName: model.displayName,
                    capabilities: ModelCapabilitiesV2(
                        contextWindow: model.contextWindow,
                        supportedReasoningEfforts: model.supportedReasoningEfforts,
                        defaultReasoningEffort: model.defaultReasoningEffort,
                        supportsVision: nil
                    ),
                    metadataSources: Self.metadataSources(of: model),
                    visibility: .visible
                )
                if !registry.catalog.contains(where: { $0.id == entry.id }) {
                    registry.catalog.append(entry)
                }
            }
        }

        // Shadow write → read back → verify.
        do {
            try repository.saveRegistry(registry)
        } catch {
            return .failed("shadow write failed: \(error.localizedDescription)")
        }
        let written = repository.loadRegistry()
        guard written == registry else {
            return .failed("shadow write verification mismatch")
        }

        repository.appendJournalEntry(
            MigrationEntry(
                journalID: UUID().uuidString,
                migratedAt: now(),
                fromVersion: 1,
                toVersion: ProviderRegistryV2.currentVersion,
                shadowed: true,
                verified: true,
                rolledBack: nil,
                sourceHash: sourceHash
            )
        )
        return .migrated
    }

    // MARK: - Helpers

    /// Deterministic fingerprint of the v1 store (ignores secret fields so a
    /// key rotation does not invalidate the journal). FNV-1a 64-bit: stable
    /// across processes (String.hashValue is per-process randomized and would
    /// break journal idempotence after a restart).
    static func sourceHash(of store: ProviderStore) -> String {
        var digest = ""
        for provider in store.providers.sorted(by: { $0.id < $1.id }) {
            digest += "\(provider.id)|\(provider.name)|\(provider.baseURL)|\(provider.defaultProtocol.rawValue);"
        }
        guard !digest.isEmpty else { return "empty" }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in digest.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func matchDefinition(for provider: ProviderConfig) -> ProviderDefinition {
        let name = provider.name.lowercased()
        let url = provider.baseURL.lowercased()
        let candidates: [(String, String)] = [
            ("deepseek", "deepseek"), ("qwen", "qwen"), ("z.ai", "zai"), ("zai", "zai"),
            ("minimax", "minimax"), ("kimi", "kimi"), ("moonshot", "kimi"),
            ("openrouter", "openrouter"), ("volcengine", "volcengine"), ("火山", "volcengine"),
            ("anthropic", "anthropic"), ("claude", "anthropic"), ("antigravity", "antigravity"),
            ("agy", "antigravity"), ("grok", "grok"), ("x.ai", "grok"),
            ("gemini", "google"), ("generativelanguage", "google"),
        ]
        for (needle, definitionID) in candidates where name.contains(needle) || url.contains(needle) {
            if let definition = BuiltInProviderRegistry.definition(id: definitionID) {
                return definition
            }
        }
        // Unknown provider: user overlay definition.
        return ProviderDefinition(
            id: "custom-\(provider.id)",
            displayName: provider.name,
            ownership: "user",
            supportedProtocols: [APIDialect(provider.defaultProtocol)],
            defaultBaseURL: provider.baseURL,
            credentialKinds: [.apiKey],
            isBuiltIn: false
        )
    }

    static func credentialKind(of provider: ProviderConfig) -> CredentialKind {
        switch provider.authKind {
        case .subscriptionImport: return .subscriptionImport
        case .apiKey:
            return provider.refreshToken == nil ? .apiKey : .oauth
        }
    }

    static func metadataSources(of model: ProviderModel) -> [String: MetadataSource] {
        var sources: [String: MetadataSource] = [:]
        if let source = model.contextWindowSource {
            sources["contextWindow"] = MetadataSource(source)
        }
        if let source = model.reasoningSource {
            sources["reasoning"] = MetadataSource(source)
        }
        return sources
    }
}
