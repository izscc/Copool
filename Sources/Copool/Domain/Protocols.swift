import Foundation

protocol AccountsStoreRepository: Sendable {
    func loadStore() throws -> AccountsStore
    func saveStore(_ store: AccountsStore) throws
    func mutateStore(_ transform: (inout AccountsStore) throws -> Void) throws -> AccountsStore
}

extension AccountsStoreRepository {
    func mutateStore(_ transform: (inout AccountsStore) throws -> Void) throws -> AccountsStore {
        var store = try loadStore()
        try transform(&store)
        try saveStore(store)
        return store
    }
}

protocol SettingsRepository: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
}

protocol ProviderStoreRepository: Sendable {
    func loadProviders() throws -> ProviderStore
    func saveProviders(_ store: ProviderStore) throws
    func mutateProviders(_ transform: (inout ProviderStore) throws -> Void) throws -> ProviderStore
    /// One-shot migration hook (e.g. plaintext secrets → keychain). Default
    /// no-op; implementations must be idempotent and non-throwing.
    func migrateLegacySecretsIfNeeded()
}

extension ProviderStoreRepository {
    func mutateProviders(_ transform: (inout ProviderStore) throws -> Void) throws -> ProviderStore {
        var store = try loadProviders()
        try transform(&store)
        try saveProviders(store)
        return store
    }

    func migrateLegacySecretsIfNeeded() {}
}

/// v2/v3 注册表的读写面。Behavior 层只认这个协议——原子写、chmod 0600
/// 这些落盘细节属于 Infrastructure，协调器不该知道。
protocol ProviderRegistryRepository: Sendable {
    func loadRegistry() -> ProviderRegistryV2
    func saveRegistry(_ registry: ProviderRegistryV2) throws
}

/// 目标绑定存储的读写面。同上，Behavior 只认协议。
protocol TargetBindingRepositoryProtocol: Sendable {
    func load() throws -> TargetBindingStore
    func save(_ store: TargetBindingStore) throws
}

/// 复用第三方登录态前的同意审计（FR-IDT-06 / SEC-08）。
///
/// 只追加、不改写：审计日志一旦可被覆盖，就失去了"用户确实授权过"的
/// 证明力。写失败必须抛错——记不下同意就不该执行读取动作。
protocol ConsentAuditLog: Sendable {
    func append(_ record: ConsentRecord) throws
    func records() -> [ConsentRecord]
}

protocol ThirdPartyUsageRepository: Sendable {
    func loadUsage() throws -> ThirdPartyUsageStore
    func saveUsage(_ store: ThirdPartyUsageStore) throws
}

protocol AgentProfileRepository: Sendable {
    func loadAgents() throws -> AgentProfileStore
    func saveAgents(_ store: AgentProfileStore) throws
    func mutateAgents(_ transform: (inout AgentProfileStore) throws -> Void) throws -> AgentProfileStore
    func loadRouteEvents() throws -> AgentRouteEventStore
    func appendRouteEvent(_ event: AgentRouteEvent) throws
}

extension AgentProfileRepository {
    func mutateAgents(_ transform: (inout AgentProfileStore) throws -> Void) throws -> AgentProfileStore {
        var store = try loadAgents()
        try transform(&store)
        try saveAgents(store)
        return store
    }
}

protocol AuthRepository: Sendable {
    func readCurrentAuth() throws -> JSONValue
    func readCurrentAuthOptional() throws -> JSONValue?
    func readAuth(from url: URL) throws -> JSONValue
    func writeCurrentAuth(_ auth: JSONValue) throws
    func removeCurrentAuth() throws
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue
    func exchangeAuth(email: String, refreshToken: String) async throws -> JSONValue
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth
    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue
}

protocol UsageService: Sendable {
    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot
}

protocol WorkspaceMetadataService: Sendable {
    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata]
}

protocol DateProviding: Sendable {
    func unixSecondsNow() -> Int64
    func unixMillisecondsNow() -> Int64
}

extension DateProviding {
    func unixMillisecondsNow() -> Int64 {
        unixSecondsNow() * 1_000
    }
}

extension AuthRepository {
    func exchangeAuth(email: String, refreshToken: String) async throws -> JSONValue {
        _ = email
        _ = refreshToken
        throw AppError.invalidData(L10n.tr("error.opencode.missing_refresh_token"))
    }

    func readCurrentExtractedAuth() -> ExtractedAuth? {
        guard let auth = try? readCurrentAuthOptional(),
              let extracted = try? extractAuth(from: auth) else {
            return nil
        }
        return extracted
    }

    func currentAuthAccountKey() -> String? {
        readCurrentExtractedAuth()?.accountKey
    }

    func refreshChatGPTAuth(_ auth: JSONValue) async throws -> JSONValue {
        auth
    }
}

protocol ProxyRuntimeService: Sendable {
    func status() async -> ApiProxyStatus
    func start(preferredPort: Int?) async throws -> ApiProxyStatus
    func stop() async -> ApiProxyStatus
    func refreshAPIKey() async throws -> ApiProxyStatus
    func syncAccountsStore() async throws

    /// 第三方分流当前处于哪一态（A2）。
    func providerSplitState() async -> ProviderSplitState
    /// 收敛不一致态，返回是否真的做了剥离（A2 自愈）。
    @discardableResult
    func reconcileProviderSplit() async -> Bool
}

extension ProxyRuntimeService {
    /// 默认实现让不托管 Codex 配置的实现（远端代理、测试替身）无需关心分流：
    /// 它们不写 config.toml，也就永远不会进入不一致态。
    func providerSplitState() async -> ProviderSplitState {
        await status().running ? .active : .degraded
    }

    @discardableResult
    func reconcileProviderSplit() async -> Bool { false }
}

protocol CloudflaredServiceProtocol: Sendable {
    func status() async -> CloudflaredStatus
    func install() async throws -> CloudflaredStatus
    func start(_ input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus
    func stop() async -> CloudflaredStatus
}

protocol RemoteProxyServiceProtocol: Sendable {
    func status(server: RemoteServerConfig) async -> RemoteProxyStatus
    func discover(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance]
    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func syncAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus
    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String
    func uninstall(server: RemoteServerConfig, removeRemoteDirectory: Bool) async throws -> RemoteProxyStatus
}

protocol RemoteAccountsMutationSyncServiceProtocol: Sendable {
    func syncConfiguredRemoteAccounts() async -> RemoteAccountsMutationSyncReport
}

protocol ChatGPTAppServiceProtocol: Sendable {
    func launchApp() throws
    func syncThirdPartyModels(providers: [ProviderConfig]) throws
    func syncThirdPartyModels(providers: [ProviderConfig], registry: ProviderRegistryV2) throws
}

extension ChatGPTAppServiceProtocol {
    func syncThirdPartyModels(providers: [ProviderConfig]) throws {
        _ = providers
    }

    func syncThirdPartyModels(providers: [ProviderConfig], registry: ProviderRegistryV2) throws {
        _ = registry
        try syncThirdPartyModels(providers: providers)
    }
}

protocol ChatGPTOAuthLoginServiceProtocol: Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens
    func signInWithChatGPT(timeoutSeconds: TimeInterval, forcedWorkspaceID: String?) async throws -> ChatGPTOAuthTokens
}

extension ChatGPTOAuthLoginServiceProtocol {
    func signInWithChatGPT(timeoutSeconds: TimeInterval, forcedWorkspaceID: String?) async throws -> ChatGPTOAuthTokens {
        _ = forcedWorkspaceID
        return try await signInWithChatGPT(timeoutSeconds: timeoutSeconds)
    }
}

protocol EditorAppServiceProtocol: Sendable {
    func listInstalledApps() -> [InstalledEditorApp]
    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?)
}

protocol OpencodeAuthSyncServiceProtocol: Sendable {
    func syncFromCodexAuth(_ authJSON: JSONValue) throws
}

protocol LaunchAtStartupServiceProtocol: Sendable {
    func setEnabled(_ enabled: Bool) throws
    func syncWithStoreValue(_ enabled: Bool) throws
}

protocol ProxyControlRemoteCommandServiceProtocol: Sendable {
    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws
    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot?
    func enqueueCommand(_ command: ProxyControlCommand) async throws
    func pullPendingCommand() async throws -> ProxyControlCommand?
}

protocol ProxyLocalCommandServiceProtocol: Sendable {
    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot
}

@MainActor
protocol AccountsManualRefreshServiceProtocol: AnyObject {
    var lastRefreshNotice: String? { get }
    func performManualRefresh() async throws -> [AccountSummary]
    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary]
}

extension AccountsManualRefreshServiceProtocol {
    var lastRefreshNotice: String? { nil }

    func performManualRefresh() async throws -> [AccountSummary] {
        try await performManualRefresh(onPartialUpdate: { _ in })
    }
}

@MainActor
protocol AccountsLocalMutationSyncServiceProtocol: AnyObject {
    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary])
    func syncLocalAccountsMutationNow() async
}
