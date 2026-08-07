import Foundation

/// 凭据的读写与健康维护（FR-IDT-01…FR-IDT-07）。
///
/// 五种 `CredentialKind` 的落盘方式完全不同，这里是唯一知道差异的地方：
///   - `apiKey` / `oauthDeviceFlow` / `subscriptionImport`：值进 Keychain，
///     注册表只留 `SecureReference` 指针。
///   - `environmentReference`：**什么都不存**，只记环境变量名，运行时按名读。
///   - `externalCLISession`：只记会话文件路径，不复制内容，且读取前要过同意。
///
/// SEC-01：Keychain 写失败必须抛错并中止，**禁止降级为明文落盘**。这条比
/// "让用户少看一个报错"重要——一旦降级，秘密就永久留在了明文文件里。
@MainActor
final class CredentialCoordinator {
    private let repository: ProviderRegistryRepository
    private let secrets: SecureStore
    private let consentLog: ConsentAuditLog
    private let environment: [String: String]
    private let now: () -> Int64
    private let fileManager: FileManager

    init(
        repository: ProviderRegistryRepository,
        secrets: SecureStore,
        consentLog: ConsentAuditLog,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.repository = repository
        self.secrets = secrets
        self.consentLog = consentLog
        self.environment = environment
        self.fileManager = fileManager
        self.now = now
    }

    enum CredentialError: LocalizedError, Equatable {
        case keychainWriteFailed(account: String)
        case keychainDeleteFailed(account: String)
        case credentialNotFound(String)
        case instanceNotFound(String)
        case emptySecret
        case environmentVariableNotSet(String)
        case externalSessionMissing(path: String)
        case consentRequired(subject: String)

        var errorDescription: String? {
            switch self {
            case .keychainWriteFailed:
                return L10n.tr("credentials.error.keychain_write_failed")
            case .keychainDeleteFailed:
                return L10n.tr("credentials.error.keychain_delete_failed")
            case .credentialNotFound:
                return L10n.tr("credentials.error.not_found")
            case .instanceNotFound:
                return L10n.tr("credentials.error.instance_not_found")
            case .emptySecret:
                return L10n.tr("credentials.error.empty_secret")
            case .environmentVariableNotSet(let name):
                return L10n.tr("credentials.error.env_not_set", name)
            case .externalSessionMissing:
                return L10n.tr("credentials.error.external_session_missing")
            case .consentRequired:
                return L10n.tr("credentials.error.consent_required")
            }
        }
    }

    // MARK: - 读取

    func registry() -> ProviderRegistryV2 {
        repository.loadRegistry()
    }

    /// 共用凭据组：同组的多个 provider 共享同一个 `CredentialIdentity`
    /// （opencode-go 三通道，FR-PRV-02）。填一次即三条通道同时就绪。
    ///
    /// 组 id 前缀 `shared-` 与实例 id（UUID）不可能撞车。
    func credentialIdentityID(forInstance instance: ProviderInstance, in registry: ProviderRegistryV2) -> String {
        if let group = registry.definition(id: instance.definitionID)?.sharedCredentialGroup, !group.isEmpty {
            return "shared-\(group)"
        }
        return instance.credentialID.isEmpty ? "cred-\(instance.id)" : instance.credentialID
    }

    /// 该凭据所服务的全部实例。共用组下改一把凭据会影响多条通道，UI 必须
    /// 在确认前把它们列出来——用户以为只改了一个，实际改了三个。
    func affectedInstances(credentialID: String, in registry: ProviderRegistryV2) -> [ProviderInstance] {
        registry.instances.filter {
            credentialIdentityID(forInstance: $0, in: registry) == credentialID
        }
    }

    /// 秘密在本机是否确实存在。三种存储形态的探测方式不同，健康判定要靠它。
    func secretPresent(_ credential: CredentialIdentity) -> Bool {
        guard let reference = credential.secureReference else { return false }
        switch reference.storage {
        case .keychainAccount:
            return secrets.read(account: reference.name, timeout: 3) != nil
        case .environmentVariable:
            return !(environment[reference.name] ?? "").isEmpty
        case .externalSessionFile:
            return fileManager.fileExists(atPath: reference.name)
        }
    }

    /// 按 FR-IDT-07 重算一条凭据的健康状态并落盘。
    ///
    /// `probe` 传 nil 表示"没有新的真实请求结果"，此时只重算本地信号
    /// （存在性 + 过期时间），不会把一条曾经 401 的凭据擦成就绪。
    @discardableResult
    func refreshHealth(
        credentialID: String,
        probe: CredentialHealthEvaluator.ProbeOutcome? = nil,
        verifying: Bool = false
    ) throws -> CredentialIdentity {
        try mutate { registry in
            guard let index = registry.credentials.firstIndex(where: { $0.id == credentialID }) else {
                throw CredentialError.credentialNotFound(credentialID)
            }
            let credential = registry.credentials[index]
            let signals = CredentialHealthEvaluator.Signals(
                kind: credential.kind,
                secretPresent: self.secretPresent(credential),
                expiresAt: credential.expiresAt,
                now: self.now(),
                lastProbe: probe,
                verificationInFlight: verifying
            )
            let verdict = CredentialHealthEvaluator.evaluate(signals)
            registry.credentials[index] = CredentialHealthEvaluator.apply(
                verdict,
                to: credential,
                at: self.now()
            )
            return registry.credentials[index]
        }
    }

    /// 全量重算。启动时跑一次，让 UI 一进来就显示真实状态而不是上次的缓存。
    func refreshAllHealth() throws {
        try mutateVoid { registry in
            let timestamp = self.now()
            for index in registry.credentials.indices {
                let credential = registry.credentials[index]
                let signals = CredentialHealthEvaluator.Signals(
                    kind: credential.kind,
                    secretPresent: self.secretPresent(credential),
                    expiresAt: credential.expiresAt,
                    now: timestamp,
                    lastProbe: nil,
                    verificationInFlight: false
                )
                registry.credentials[index] = CredentialHealthEvaluator.apply(
                    CredentialHealthEvaluator.evaluate(signals),
                    to: credential,
                    at: timestamp
                )
            }
        }
    }

    // MARK: - 写入

    /// 保存一把 API Key（FR-IDT-01）。
    ///
    /// 顺序是**先写 Keychain 再改注册表**：反过来的话，Keychain 写失败时
    /// 注册表里已经躺着一个指向空账户的指针，UI 会显示"已配置"而实际用不了。
    @discardableResult
    func saveAPIKey(instanceID: String, key: String) throws -> CredentialIdentity {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.emptySecret }

        var registry = repository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else {
            throw CredentialError.instanceNotFound(instanceID)
        }
        let credentialID = credentialIdentityID(forInstance: instance, in: registry)
        let account = ProviderSecretAccount.apiKey(providerID: credentialID)

        // SEC-01：写不进 Keychain 就抛错中止，绝不降级为明文落盘。
        guard secrets.write(account: account, value: trimmed, timeout: 3) else {
            throw CredentialError.keychainWriteFailed(account: account)
        }

        let credential = CredentialIdentity(
            id: credentialID,
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: account),
            source: .userEntered,
            scopes: [],
            expiresAt: nil,
            lastVerifiedAt: nil,
            healthState: .ready,
            lastFailureReason: nil
        )
        upsert(credential: credential, into: &registry)
        bindCredential(id: credentialID, in: &registry)
        try repository.saveRegistry(registry)
        return credential
    }

    /// 绑定一个环境变量（FR-IDT-03）。**只记名字，不读值也不落值**——
    /// 值留在环境里，进程每次按名读取，用户换值不需要回来改配置。
    @discardableResult
    func bindEnvironmentVariable(instanceID: String, variableName: String) throws -> CredentialIdentity {
        let name = variableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CredentialError.emptySecret }

        var registry = repository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else {
            throw CredentialError.instanceNotFound(instanceID)
        }
        let credentialID = credentialIdentityID(forInstance: instance, in: registry)
        let reference = SecureReference(storage: .environmentVariable, name: name)

        // 变量当下没设置也允许绑定：用户可能打算稍后 export。状态如实显示为
        // 未配置，而不是拒绝保存——拒绝会逼用户先去改 shell 再回来。
        let credential = CredentialIdentity(
            id: credentialID,
            kind: .environmentReference,
            secureReference: reference,
            source: .environment,
            healthState: (environment[name] ?? "").isEmpty ? .unconfigured : .ready
        )
        upsert(credential: credential, into: &registry)
        bindCredential(id: credentialID, in: &registry)
        try repository.saveRegistry(registry)
        return credential
    }

    /// 落地一次 OAuth 设备码流的结果（FR-IDT-02）。
    /// access token 与 refresh token 分账号存放，过期时间入注册表供健康判定。
    @discardableResult
    func saveOAuthTokens(
        instanceID: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Int64?,
        scopes: [String] = []
    ) throws -> CredentialIdentity {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.emptySecret }

        var registry = repository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else {
            throw CredentialError.instanceNotFound(instanceID)
        }
        let credentialID = credentialIdentityID(forInstance: instance, in: registry)
        let account = ProviderSecretAccount.apiKey(providerID: credentialID)

        guard secrets.write(account: account, value: trimmed, timeout: 3) else {
            throw CredentialError.keychainWriteFailed(account: account)
        }
        if let refreshToken, !refreshToken.isEmpty {
            let refreshAccount = ProviderSecretAccount.refreshToken(providerID: credentialID)
            guard secrets.write(account: refreshAccount, value: refreshToken, timeout: 3) else {
                // access token 已经写进去了，但缺了 refresh token 这把凭据
                // 迟早会过期且续不回来。抛错让用户重走一次，比留一个
                // 半配置状态更容易排查。
                throw CredentialError.keychainWriteFailed(account: refreshAccount)
            }
        }

        let credential = CredentialIdentity(
            id: credentialID,
            kind: .oauthDeviceFlow,
            secureReference: SecureReference(storage: .keychainAccount, name: account),
            source: .userEntered,
            scopes: scopes,
            expiresAt: expiresAt,
            lastVerifiedAt: now(),
            healthState: .ready
        )
        upsert(credential: credential, into: &registry)
        bindCredential(id: credentialID, in: &registry)
        try repository.saveRegistry(registry)
        return credential
    }

    // MARK: - 需要显式同意的两类（SEC-08）

    /// 复用第三方 CLI 的本机登录态（FR-IDT-04）。
    ///
    /// **不复制内容**：只记路径，每次请求按需读。源文件变更立刻生效，
    /// 用户在那个 CLI 里重新登录后不需要回 Copool 做任何操作。
    /// 也因此，Copool 永远不写、不删源文件。
    @discardableResult
    func bindExternalSession(
        instanceID: String,
        sessionPath: String,
        disclosure: String,
        userConsented: Bool
    ) throws -> CredentialIdentity {
        var registry = repository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else {
            throw CredentialError.instanceNotFound(instanceID)
        }
        let definitionID = instance.definitionID
        guard userConsented else {
            throw CredentialError.consentRequired(subject: definitionID)
        }
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw CredentialError.externalSessionMissing(path: sessionPath)
        }

        // 先落审计再读取。记不下同意就不该继续——顺序反了的话，崩溃窗口里
        // 会出现"已经读过但没有授权凭证"的状态。
        try consentLog.append(
            ConsentRecord(
                id: UUID().uuidString,
                action: .reuseExternalSession,
                subject: definitionID,
                disclosure: disclosure,
                grantedAt: now()
            )
        )

        let credentialID = credentialIdentityID(forInstance: instance, in: registry)
        let credential = CredentialIdentity(
            id: credentialID,
            kind: .externalCLISession,
            secureReference: SecureReference(storage: .externalSessionFile, name: sessionPath),
            source: .importedFromApp,
            healthState: .ready
        )
        upsert(credential: credential, into: &registry)
        bindCredential(id: credentialID, in: &registry)
        try repository.saveRegistry(registry)
        return credential
    }

    /// 导入订阅客户端的登录态（FR-IDT-05）。与 CLI 复用的关键差别：
    /// 这一类**会复制**一份进 Keychain，所以披露文案必须说清这一点。
    @discardableResult
    func importSubscription(
        instanceID: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Int64?,
        sourceApp: String,
        disclosure: String,
        userConsented: Bool
    ) throws -> CredentialIdentity {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.emptySecret }

        var registry = repository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else {
            throw CredentialError.instanceNotFound(instanceID)
        }
        guard userConsented else {
            throw CredentialError.consentRequired(subject: sourceApp)
        }

        try consentLog.append(
            ConsentRecord(
                id: UUID().uuidString,
                action: .importSubscription,
                subject: sourceApp,
                disclosure: disclosure,
                grantedAt: now()
            )
        )

        let credentialID = credentialIdentityID(forInstance: instance, in: registry)
        let account = ProviderSecretAccount.apiKey(providerID: credentialID)
        guard secrets.write(account: account, value: trimmed, timeout: 3) else {
            throw CredentialError.keychainWriteFailed(account: account)
        }
        if let refreshToken, !refreshToken.isEmpty {
            let refreshAccount = ProviderSecretAccount.refreshToken(providerID: credentialID)
            guard secrets.write(account: refreshAccount, value: refreshToken, timeout: 3) else {
                throw CredentialError.keychainWriteFailed(account: refreshAccount)
            }
        }

        let credential = CredentialIdentity(
            id: credentialID,
            kind: .subscriptionImport,
            secureReference: SecureReference(storage: .keychainAccount, name: account),
            source: .importedFromApp,
            expiresAt: expiresAt,
            lastVerifiedAt: now(),
            healthState: .ready
        )
        upsert(credential: credential, into: &registry)
        bindCredential(id: credentialID, in: &registry)
        try repository.saveRegistry(registry)
        return credential
    }

    // MARK: - 撤销（FR-IDT-08）

    /// 删除一条凭据：清 Keychain → 从所有引用它的实例解绑 → 移出注册表。
    ///
    /// **不碰**第三方 CLI/客户端里的原始登录态——那是用户在别处的资产，
    /// Copool 只是读过它，无权删除。
    func deleteCredential(credentialID: String) throws {
        var registry = repository.loadRegistry()
        guard let index = registry.credentials.firstIndex(where: { $0.id == credentialID }) else {
            throw CredentialError.credentialNotFound(credentialID)
        }
        let credential = registry.credentials[index]

        if credential.secureReference?.storage == .keychainAccount {
            let account = ProviderSecretAccount.apiKey(providerID: credentialID)
            guard secrets.delete(account: account, timeout: 3) else {
                // 删不掉就别改注册表：否则秘密还在 Keychain 里，而应用已经
                // 忘了它的存在，用户再也无从清理。
                throw CredentialError.keychainDeleteFailed(account: account)
            }
            _ = secrets.delete(account: ProviderSecretAccount.refreshToken(providerID: credentialID), timeout: 3)
        }

        registry.credentials.remove(at: index)
        for instanceIndex in registry.instances.indices {
            registry.instances[instanceIndex].credentialIdentityIDs.removeAll { $0 == credentialID }
            if registry.instances[instanceIndex].credentialID == credentialID {
                registry.instances[instanceIndex].credentialID =
                    registry.instances[instanceIndex].credentialIdentityIDs.first ?? ""
            }
        }
        try repository.saveRegistry(registry)
    }

    // MARK: - 通道的按需创建

    /// 确保某个 definition 至少有一个可挂凭据的实例，返回其 id。
    ///
    /// UI 列出的是**种子里的 23 家 provider**，而实例是用户配置出来的产物。
    /// 若要求用户先"添加通道"再"填凭据"，就多了一步没有信息量的仪式——
    /// 他想做的只有一件事：让这家能用。所以实例在第一次落凭据时按需创建。
    ///
    /// 已存在则原样返回，不覆盖用户改过的 endpoint 或显示名。
    /// - Parameter catalogSeed: 新实例建成后用来具化种子目录的闭包，入参是
    ///   刚生成的 instance id。传闭包而不是种子数组，是为了让 Behavior 不必
    ///   认识 `ProviderRegistrySeedLoader`——种子解析属于 Infrastructure，
    ///   由 Features 侧注入（同 `definition` 参数的理由）。
    @discardableResult
    func ensureInstance(
        definitionID: String,
        displayName: String,
        definition: ProviderDefinition?,
        catalogSeed: ((String) -> [ModelCatalogEntry])? = nil
    ) throws -> String {
        var registry = repository.loadRegistry()
        if let existing = registry.instances.first(where: { $0.definitionID == definitionID }) {
            // 已存在但目录是空的：M1 之前建的实例、或从 v1 迁移过来的实例都
            // 会落到这里。补一次种子而不是放着不管——否则用户看到的是一家
            // 「已配置好但一个模型都没有」的 provider，且没有任何自愈路径。
            if let catalogSeed, registry.catalogEntries(instanceID: existing.id).isEmpty {
                let seeded = CatalogBuilder().materializeSeedCatalog(
                    registry: registry,
                    instanceID: existing.id,
                    seedEntries: catalogSeed(existing.id)
                )
                if seeded.catalog.count != registry.catalog.count {
                    try repository.saveRegistry(seeded)
                }
            }
            return existing.id
        }

        let resolved = definition ?? registry.definition(id: definitionID)
        let dialects = resolved?.supportedProtocols ?? [.chat]
        // 默认协议取声明顺序里的第一个而不是 Set 的任意一个：Set 的遍历顺序
        // 每次进程都可能不同，那会让同一份配置在两次启动后走不同的协议。
        let preferred: APIDialect = APIDialect.allCases.first { dialects.contains($0) } ?? .chat

        let instance = ProviderInstance(
            id: UUID().uuidString,
            definitionID: definitionID,
            displayName: displayName,
            endpoint: resolved?.defaultBaseURL ?? "",
            credentialID: "",
            protocolBindings: [:],
            defaultProtocol: preferred,
            enabled: true,
            addedAt: now()
        )
        registry.instances.append(instance)
        // definition 不在注册表里时一并写入，否则实例会指向一个空定义，
        // 之后解析 baseURL / 凭据种类全都落空。
        if let resolved, registry.definition(id: definitionID) == nil {
            registry.definitions.append(resolved)
        }
        // 具化种子目录。少了这一步，刚配好凭据的 provider 会显示 0 个模型，
        // 而配置**之前**列表上写的是 8 个——用户只能得出"我把它配坏了"这个
        // 结论。实时发现不能替代这一步：不少 provider 的 `/models` 需要额外
        // 权限，甚至根本没有这个端点（FR-CAT-02）。
        if let catalogSeed {
            registry = CatalogBuilder().materializeSeedCatalog(
                registry: registry,
                instanceID: instance.id,
                seedEntries: catalogSeed(instance.id)
            )
        }
        try repository.saveRegistry(registry)
        return instance.id
    }

    // MARK: - 私有

    /// 同 id 覆盖、否则追加。共用组下第二次填写会走覆盖分支，
    /// 这正是"填一次三条通道都就绪"的实现。
    private func upsert(credential: CredentialIdentity, into registry: inout ProviderRegistryV2) {
        if let index = registry.credentials.firstIndex(where: { $0.id == credential.id }) {
            registry.credentials[index] = credential
        } else {
            registry.credentials.append(credential)
        }
    }

    /// 把凭据挂到所有该用它的实例上。共用组的场景下这会一次绑定多条通道。
    private func bindCredential(id credentialID: String, in registry: inout ProviderRegistryV2) {
        let snapshot = registry
        for index in registry.instances.indices {
            let instance = registry.instances[index]
            guard credentialIdentityID(forInstance: instance, in: snapshot) == credentialID else { continue }
            if registry.instances[index].credentialID.isEmpty {
                registry.instances[index].credentialID = credentialID
            }
            if !registry.instances[index].credentialIdentityIDs.contains(credentialID) {
                registry.instances[index].credentialIdentityIDs.append(credentialID)
            }
        }
    }

    private func mutate<T>(_ body: (inout ProviderRegistryV2) throws -> T) throws -> T {
        var registry = repository.loadRegistry()
        let result = try body(&registry)
        try repository.saveRegistry(registry)
        return result
    }

    private func mutateVoid(_ body: (inout ProviderRegistryV2) throws -> Void) throws {
        var registry = repository.loadRegistry()
        try body(&registry)
        try repository.saveRegistry(registry)
    }
}
