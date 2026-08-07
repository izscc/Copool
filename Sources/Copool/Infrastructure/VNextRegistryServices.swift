import Foundation

/// 内置 provider 定义的查询入口。
///
/// **唯一真源是 `provider-registry-seed.json`**，不是本文件里的数组。曾经这里
/// 硬编码了一份 11 家的清单，与种子的 23 家各自演进，id 还对不上
/// （`kimi` vs `kimi-api`、`google` vs `gemini-api`）。结果是 v1 迁移出来的实例
/// 挂在种子里不存在的 definition 上，供应商页按种子分组，那些实例一条都不显示。
///
/// 定义不含用户数据也不含密钥；模型清单有意不放在这里——实时发现与策展在
/// 运行时填充。
enum BuiltInProviderRegistry {

    /// 种子里的定义。解码失败时为空，由 `all` 兜底。
    static let seeded: [ProviderDefinition] = (try? ProviderRegistrySeedLoader.load())?.definitions ?? []

    /// 只在 v1 迁移里出现、种子里有意没有的 provider。
    ///
    /// 这两家不是"漏了"：Antigravity 走的是导入本机订阅登录态，火山方舟需要用户
    /// 自带 endpoint id，都不适合作为开箱可用的内置条目。但老用户的 v1 配置里
    /// 有它们，迁移时必须落到一条**有品牌名的**定义上——否则会退化成
    /// `custom-<uuid>` 覆盖层，显示名变成一串 id。
    static let legacySupplement: [ProviderDefinition] = [
        ProviderDefinition(
            id: "antigravity",
            displayName: "Antigravity",
            ownership: "google",
            supportedProtocols: [.google],
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            credentialKinds: [.subscriptionImport, .oauthDeviceFlow],
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
    ]

    /// 种子 + 迁移补充。种子解码失败时退到 `fallback`，让迁移仍能匹配到品牌名。
    static var all: [ProviderDefinition] {
        (seeded.isEmpty ? fallback : seeded) + legacySupplement
    }

    /// **仅在种子解码失败时使用**的应急清单。
    ///
    /// 保留它是为了让 v1 迁移在种子坏掉时不至于把所有 provider 都变成
    /// `custom-` 覆盖层。id 与种子保持一致，这样种子修好后不会产生第二套身份。
    static let fallback: [ProviderDefinition] = [
        ProviderDefinition(
            id: "deepseek",
            displayName: "DeepSeek API",
            ownership: "deepseek",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.deepseek.com",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "qwen-plan",
            displayName: "Qwen（阿里云 Model Studio 套餐）",
            ownership: "alibaba",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "zai-coding",
            displayName: "Z.ai GLM Coding Plan",
            ownership: "zhipu",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.z.ai/api/coding/paas/v4",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "minimax-token-plan",
            displayName: "MiniMax Token Plan",
            ownership: "minimax",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.minimax.io/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "kimi-api",
            displayName: "Kimi Platform API",
            ownership: "moonshot",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.moonshot.cn/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "openrouter",
            displayName: "OpenRouter",
            ownership: "openrouter",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://openrouter.ai/api/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true,
            catalogOnly: true
        ),
        ProviderDefinition(
            id: "anthropic-api",
            displayName: "Anthropic API",
            ownership: "anthropic",
            supportedProtocols: [.anthropic],
            defaultBaseURL: "https://api.anthropic.com/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
        ProviderDefinition(
            id: "gemini-api",
            displayName: "Google Gemini API",
            ownership: "google",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true,
            catalogOnly: true
        ),
        ProviderDefinition(
            id: "grok-api",
            displayName: "xAI Grok API",
            ownership: "xai",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.x.ai/v1",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true
        ),
    ]

    static func definition(id: String) -> ProviderDefinition? {
        all.first { $0.id == id }
    }
}

/// Persists the v2 registry (provider-registry-v2.json) and its migration
/// journal (migration-journal.json) with atomic writes.
final class ProviderRegistryV2Repository: ProviderRegistryRepository, @unchecked Sendable {
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

    /// Removes the v2 registry entirely (AC-004 rollback): the v1 store stays
    /// the source of truth and the next migration recreates the registry.
    func deleteRegistry() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: registryPath.path) {
            try fileManager.removeItem(at: registryPath)
        }
    }

    /// Persists the whole journal (rollback needs to flip `rolledBack` on an
    /// existing entry; append-only is insufficient for that).
    func saveJournal(_ journal: MigrationJournal) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: journalPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        try writeAtomically(data: data, to: journalPath)
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

    // MARK: - Rollback (AC-004)

    /// Rolls a verified migration back: removes the v2 registry and marks the
    /// journal entry `rolledBack`, so the next `migrateIfNeeded` recreates the
    /// registry from the v1 store. The v1 store is never touched — it remains
    /// the source of truth, which is what makes the rollback safe and
    /// repeatable. Idempotent: rolling back twice is a no-op.
    ///
    /// Returns false when the source hash is unknown (nothing to roll back)
    /// or the journal/registry could not be updated.
    @discardableResult
    func rollbackMigration(sourceHash: String) -> Bool {
        var journal = repository.loadJournal()
        guard let index = journal.entries.lastIndex(where: { $0.sourceHash == sourceHash }) else {
            return false
        }
        guard journal.entries[index].rolledBack != true else { return true }
        do {
            try repository.deleteRegistry()
            journal.entries[index].rolledBack = true
            try repository.saveJournal(journal)
            return true
        } catch {
            return false
        }
    }

    /// Migrates one v1 store into the v2 registry. Idempotent and safe to
    /// re-run (journal + sourceHash gate). Never throws: failures surface as
    /// `.failed` so the caller can decide.
    func migrateIfNeeded(v1 store: ProviderStore) -> MigrationOutcome {
        guard !store.providers.isEmpty else { return .nothingToMigrate }

        let sourceHash = Self.sourceHash(of: store)
        if let last = repository.loadJournal().lastEntry(sourceHash: sourceHash),
           last.verified, last.rolledBack != true {
            // 已经迁移过，但注册表可能停在旧的 schema 版本上——sourceHash 只
            // 反映 v1 存储有没有变，管不到"我们把 currentVersion 提上去了"。
            //
            // 不补这一步的后果是静默的：`V2RouteResolver` 要求版本严格等于
            // currentVersion，否则返回 `registryUnavailable` 回落 v1。于是老用户
            // 升级 App 之后 v2 路由（打分、转移、trace）全部停摆，界面上却什么
            // 都不报——他们只会觉得"最近选模型好像不太准"。
            return upgradeVersionIfNeeded(sourceHash: sourceHash)
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
            // 种子里没有的定义（迁移补充、用户自定义）还要进覆盖层：供应商页
            // 是"种子 + userDefinitions"渲染的，只写 definitions 的话，迁移过来的
            // 火山方舟 / Antigravity / 自定义端点在新页面上一条都看不见。
            if !Self.isSeeded(definition.id),
               !registry.userDefinitions.contains(where: { $0.id == definition.id }) {
                registry.userDefinitions.append(definition)
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

            let instance = ProviderInstance(
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
            if let index = registry.instances.firstIndex(where: { $0.id == instanceID }) {
                registry.instances[index] = instance
            } else {
                registry.instances.append(instance)
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

    /// 把一次失败的迁移记进账本（`verified: false`）。
    ///
    /// 迁移整个跑在后台、没有任何 UI，不留痕的话失败与成功在外部看起来完全
    /// 一样——用户只会发现"模型页是空的"，而没有任何地方说得清为什么。
    ///
    /// 复用同一份账本而不是另开日志：支持包与设置页都已经在读它，多一条通道
    /// 就多一处会漏读的地方。原因必须脱敏（INV-1），失败信息里可能带着上游
    /// 错误体或路径。
    func journalFailure(reason: String, v1 store: ProviderStore) {
        repository.appendJournalEntry(
            MigrationEntry(
                journalID: UUID().uuidString,
                migratedAt: now(),
                fromVersion: repository.loadRegistry().version,
                toVersion: ProviderRegistryV2.currentVersion,
                shadowed: false,
                verified: false,
                rolledBack: nil,
                sourceHash: Self.sourceHash(of: store),
                failureReason: SecretRedactor.redactText(reason)
            )
        )
    }

    /// 把已存在的注册表提到当前 schema 版本（MIG-02）。
    ///
    /// 只改 `version` 字段，不重建内容：v2→v3 这类升级新增的都是可选字段，
    /// 解码时已经落到各自的默认值了（`fallbackPolicy`、`requestProfiles`…）。
    /// 重新跑一遍完整迁移反而有害——那会用 v1 存储覆盖用户在 v2 里做过的
    /// 编辑（改过的展示名、手动禁用的模型、策展过的目录）。
    ///
    /// 版本比 currentVersion 还新时不动它：那是用户降级了 App，把版本号往回
    /// 写只会让新版本再打开时以为这是一份旧数据，触发一次没必要的重建。
    private func upgradeVersionIfNeeded(sourceHash: String) -> MigrationOutcome {
        var registry = repository.loadRegistry()
        guard registry.version < ProviderRegistryV2.currentVersion else {
            return .alreadyMigrated
        }
        let fromVersion = registry.version
        registry.version = ProviderRegistryV2.currentVersion
        do {
            try repository.saveRegistry(registry)
        } catch {
            return .failed("version upgrade failed: \(error.localizedDescription)")
        }
        repository.appendJournalEntry(
            MigrationEntry(
                journalID: UUID().uuidString,
                migratedAt: now(),
                fromVersion: fromVersion,
                toVersion: ProviderRegistryV2.currentVersion,
                shadowed: false,
                verified: repository.loadRegistry().version == ProviderRegistryV2.currentVersion,
                rolledBack: nil,
                // 沿用触发这次升级的那个 sourceHash，让升级记录和它所升级的
                // 那次迁移在账本里串得起来；也让下次 `lastEntry(sourceHash:)`
                // 查到的是这条最新的。
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
            let models = provider.models
                .sorted { $0.id < $1.id }
                .map { model in
                    let protocolName = provider.modelProtocols[model.id]?.rawValue ?? provider.defaultProtocol.rawValue
                    return "\(model.id):\(protocolName)"
                }
                .joined(separator: ",")
            digest += "\(provider.id)|\(provider.name)|\(provider.baseURL)|\(provider.defaultProtocol.rawValue)|\(models);"
        }
        guard !digest.isEmpty else { return "empty" }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in digest.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// 把一条 v1 provider 匹配到内置定义上。
    ///
    /// 右列必须是**种子里真实存在的 id**。匹配到一个种子里没有的 id，实例就会
    /// 挂在不存在的 definition 上——供应商页按种子分组，那条实例一辈子都不显示，
    /// 而用户只看到"我的配置没了"。
    ///
    /// 顺序敏感：先长后短、先专后泛。`z.ai` 要排在 `zai` 前面（域名里带点），
    /// `moonshot` 与 `kimi` 指向同一家。
    static func matchDefinition(for provider: ProviderConfig) -> ProviderDefinition {
        let name = provider.name.lowercased()
        let url = provider.baseURL.lowercased()
        let candidates: [(String, String)] = [
            ("deepseek", "deepseek"), ("qwen", "qwen-plan"), ("dashscope", "qwen-plan"),
            ("aliyuncs", "qwen-plan"),
            ("z.ai", "zai-coding"), ("zai", "zai-coding"), ("glm", "zai-coding"),
            ("minimax", "minimax-token-plan"),
            ("kimi", "kimi-api"), ("moonshot", "kimi-api"),
            ("openrouter", "openrouter"),
            ("volcengine", "volcengine"), ("volces", "volcengine"), ("火山", "volcengine"),
            ("antigravity", "antigravity"), ("agy", "antigravity"),
            ("anthropic", "anthropic-api"), ("claude", "anthropic-api"),
            ("grok", "grok-api"), ("x.ai", "grok-api"),
            ("gemini", "gemini-api"), ("generativelanguage", "gemini-api"),
            ("opencode", "opencode-go"), ("groq", "groq"), ("together", "together"),
            ("fireworks", "fireworks"), ("cerebras", "cerebras"), ("mistral", "mistral"),
            ("nvidia", "nvidia-nim"), ("siliconflow", "siliconflow"), ("硅基流动", "siliconflow"),
            ("huggingface", "huggingface"), ("ollama", "ollama-cloud"),
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

    /// 该 definition id 是否来自种子。种子里已有的不必再写覆盖层——
    /// 写了反而会把一份当时的快照钉死，日后种子改了域名也拿不到新值。
    static func isSeeded(_ definitionID: String) -> Bool {
        BuiltInProviderRegistry.seeded.contains { $0.id == definitionID }
    }

    static func credentialKind(of provider: ProviderConfig) -> CredentialKind {        switch provider.authKind {
        case .subscriptionImport: return .subscriptionImport
        case .apiKey:
            return provider.refreshToken == nil ? .apiKey : .oauthDeviceFlow
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
