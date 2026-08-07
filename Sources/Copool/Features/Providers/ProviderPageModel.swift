import Foundation
import Combine

/// Preconfigured provider presets users can add with one tap.
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let protocolKind: ProviderProtocol
    let exampleModels: [String]

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", protocolKind: .chat, exampleModels: ["deepseek-chat", "deepseek-reasoner"]),
        ProviderPreset(id: "qwen", name: "Qwen", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", protocolKind: .chat, exampleModels: ["qwen3-max", "qwen3-plus"]),
        ProviderPreset(id: "zai", name: "Z.ai", baseURL: "https://api.z.ai/api/v1", protocolKind: .chat, exampleModels: ["glm-5", "glm-5-flash"]),
        ProviderPreset(id: "minimax", name: "MiniMax", baseURL: "https://api.minimax.chat/v1", protocolKind: .chat, exampleModels: ["MiniMax-M3", "MiniMax-M2.7"]),
        ProviderPreset(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", protocolKind: .chat, exampleModels: ["moonshot-v1-128k", "moonshot-v1-32k"]),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", protocolKind: .chat, exampleModels: ["anthropic/claude-sonnet-4.6", "deepseek/deepseek-chat"]),
        ProviderPreset(id: "volcengine", name: "火山方舟", baseURL: "https://ark.cn-beijing.volces.com/api/v3", protocolKind: .chat, exampleModels: ["doubao-seed-1-6"]),
        ProviderPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com", protocolKind: .anthropic, exampleModels: ["claude-sonnet-4-6", "claude-opus-4-7"]),
        // Gemini 走 Google 自己的 OpenAI 兼容面，不走原生 generateContent。
        //
        // 兼容面复用同一个 chat 转发器，于是重试分类、请求档案、出站头白名单、
        // usage 归集这些东西对它自动成立。原生路径每一样都得再实现一遍，而它
        // 换来的唯一区别是 Gemini 独有的少数字段——不值得多养一条协议分支。
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", protocolKind: .chat, exampleModels: ["gemini-3-pro", "gemini-3-flash"]),
    ]
}

@MainActor
final class ProviderPageModel: ObservableObject {
    let providerStoreRepository: ProviderStoreRepository
    let usageRepository: ThirdPartyUsageRepository?
    let onProvidersChanged: () -> Void

    private let rateLimitRepository: ProviderRateLimitFileRepository?
    private let usageLedger: UsageEventLedger?
    private let accountUsageService: ProviderAccountUsageService?
    /// M1 的注册表动作在 `+Registry.swift` 里，Swift 的 `private` 是文件级的，
    /// 所以这两个依赖必须是 internal。
    let registryRepository: ProviderRegistryV2Repository?
    let credentials: CredentialCoordinator?
    private let routeDecisionLedger: RouteDecisionLedger?
    /// 分流三态来源（B2）。注入闭包而非直接持有 ProxyCoordinator，便于单测与
    /// 解耦；nil 时摘要条维持默认 `.degraded`。
    private let proxySplitStateProvider: (@Sendable () async -> ProviderSplitState)?
    private var splitStateTask: Task<Void, Never>?
    private let importer = LocalSubscriptionImporter()

    @Published var providers: [ProviderConfig] = []
    @Published var detectedSubscriptions: [ImportedSubscription] = []
    @Published var isDetectingSubscriptions = false
    @Published var providerForm: ProviderFormDraft = .empty
    @Published var isTestingProviderConnection = false
    @Published var providerConnectionTestResult: String?
    @Published var refreshingProviderIDs: Set<String> = []
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    private let noticeScheduler = NoticeAutoDismissScheduler()
    private let paths: FileSystemPaths?

    /// Per-model probe results, keyed by "providerID|modelID".
    @Published var modelTestResults: [String: ModelTestResult] = [:]
    @Published var testingModelKeys: Set<String> = []

    /// Passively harvested rate-limit snapshots, keyed by provider id.
    @Published var rateLimits: [String: ProviderRateLimitSnapshot] = [:]
    /// Vendor account usage (balance/quota), keyed by provider id.
    @Published var accountUsage: [String: ProviderAccountUsage] = [:]
    /// Daily token aggregates from the usage ledger.
    @Published var usageAggregates: [DailyUsageAggregate] = []
    @Published var isRefreshingAccountUsage = false
    /// Recent explainable route decisions for the Routes sub-tab.
    @Published var recentRouteDecisions: [RouteDecisionTrace] = []
    /// trace 里的 id → 可读名字（FR-RTE-05）。
    ///
    /// trace 存的全是 id（`modelEntryID` / `providerInstanceID`），这是对的——
    /// 决策记录不该把显示名冻在里面，用户改个实例名，历史记录就会自相矛盾。
    /// 但 UI 上直接摊一串 UUID 等于没有可解释性，所以在渲染时按当前注册表翻译。
    /// 查不到就退回 id 本身：那条实例可能已经被删了，这本身也是有用的信息。
    @Published var routeEntityNames: [String: String] = [:]
    /// 当前的失败转移策略（FR-RTE-04）。跨供应商转移会换掉计费主体，只能由
    /// 用户明确选定，所以它是可见可改的设置，不是常量。
    @Published var fallbackPolicy: FallbackPolicy = .default

    /// Credential-aware catalog rows built from the v2 registry (AC-011).
    @Published var catalogRows: [CatalogBuilder.CatalogRow] = []
    @Published var catalogHiddenCount = 0

    // MARK: - M2 模型目录

    /// 管理视图的分组（SCR-PRV-02）。缺凭据的分组沉底。
    @Published var catalogGroups: [CatalogBuilder.ManagementGroup] = []
    /// 搜索词，同时匹配显示名与后端 ID（FR-CAT-08）。
    @Published var catalogQuery: String = ""
    /// 是否显示已隐藏的条目。默认显示——管理页里藏起"被藏起来的东西"会让
    /// 取消隐藏变成一个找不到入口的操作。
    @Published var catalogShowsHidden: Bool = true
    /// 批量操作的选中集，键是 `ModelCatalogEntry.id`。
    @Published var catalogSelection: Set<String> = []
    /// 正在刷新的实例。按实例而不是全局：一家慢不该让另一家的按钮也转圈。
    @Published var catalogRefreshingInstanceIDs: Set<String> = []
    /// 别名冲突（FR-CAT-07）。非空时目录页顶部要给出警示。
    @Published var catalogAliasConflicts: [CatalogCuration.AliasConflict] = []
    /// 专家模式：显示元数据出处等只对排障有意义的细节（FR-CAT-06）。
    @Published var catalogExpertMode: Bool = false

    /// Models the provider advertises but the user has not configured yet,
    /// keyed by provider id (curation candidates).
    @Published var discoverableModels: [String: [String]] = [:]
    @Published var discoveringModelIDs: Set<String> = []

    // MARK: - M1 供应商注册表

    /// 按共用凭据分组的通道列表（CMP-01）。
    @Published var providerGroups: [ProviderRegistryPresenter.GroupViewData] = []

    /// 第三方模型分流三态（B2 状态摘要条）。在 `loadProviders()` 与代理状态
    /// 变化时刷新——`providerSplitState()` 是 async，用 Task 桥到主线程赋值。
    @Published var splitState: ProviderSplitState = .degraded
    /// 当前打开的凭据录入面板（CMP-04）。
    @Published var credentialSheet: CredentialSheetContext?
    /// 当前打开的披露同意面板（CMP-05）。
    @Published var consentSheet: ConsentSheetContext?
    /// 种子解析失败时的原因。种子是构建产物，坏了要说清楚，而不是显示
    /// "一个供应商都没有"让用户以为是自己删掉了。
    @Published var registrySeedError: String?

    struct CredentialSheetContext: Identifiable, Equatable {
        var id: String { group.id }
        var group: ProviderRegistryPresenter.GroupViewData
    }

    struct ConsentSheetContext: Identifiable, Equatable {
        var id: String { group.id }
        var group: ProviderRegistryPresenter.GroupViewData
        var spec: ExternalSessionSpec
        var resolvedPath: String
    }

    init(
        providerStoreRepository: ProviderStoreRepository,
        usageRepository: ThirdPartyUsageRepository? = nil,
        paths: FileSystemPaths? = nil,
        rateLimitRepository: ProviderRateLimitFileRepository? = nil,
        usageLedger: UsageEventLedger? = nil,
        accountUsageService: ProviderAccountUsageService? = nil,
        registryRepository: ProviderRegistryV2Repository? = nil,
        routeDecisionLedger: RouteDecisionLedger? = nil,
        proxySplitStateProvider: (@Sendable () async -> ProviderSplitState)? = nil,
        onProvidersChanged: @escaping () -> Void = {}
    ) {
        self.providerStoreRepository = providerStoreRepository
        self.usageRepository = usageRepository
        self.paths = paths
        self.rateLimitRepository = rateLimitRepository
        self.usageLedger = usageLedger
        self.accountUsageService = accountUsageService
        self.registryRepository = registryRepository
        self.routeDecisionLedger = routeDecisionLedger
        self.proxySplitStateProvider = proxySplitStateProvider
        self.onProvidersChanged = onProvidersChanged
        // 注册表与同意日志都到位才建 Coordinator：缺任何一个都意味着这台机器
        // 还没走完迁移，此时凭据面板整体不可用，比半可用更容易解释。
        if let registryRepository, let paths {
            self.credentials = CredentialCoordinator(
                repository: registryRepository,
                secrets: KeychainSecretStore(),
                consentLog: ConsentAuditFileLog(path: paths.consentLogPath)
            )
        } else {
            self.credentials = nil
        }
    }

    /// Rebuilds the credential-aware catalog from the v2 registry. A v1-only
    /// installation (registry absent) shows an empty catalog with a hint.
    func loadCatalog() {
        guard let registryRepository else {
            catalogRows = []
            catalogHiddenCount = 0
            return
        }
        let registry = registryRepository.loadRegistry()
        let secrets = KeychainSecretStore()
        let result = CatalogBuilder().buildDefaultCatalog(registry: registry) { credentialID in
            guard let credential = registry.credential(id: credentialID),
                  let reference = credential.secureReference else {
                return false
            }
            switch reference.storage {
            case .keychainAccount:
                return secrets.read(account: reference.name) != nil
            case .environmentVariable:
                return ProcessInfo.processInfo.environment[reference.name] != nil
            case .externalSessionFile:
                // 只看源文件是否还在。**不读内容**——这里只回答"就绪与否"，
                // 真正读取要走 CredentialCoordinator 的同意门禁（FR-IDT-04）。
                return FileManager.default.fileExists(atPath: reference.name)
            }
        }
        catalogRows = result.rows
        catalogHiddenCount = result.hiddenCount
    }

    static func modelKey(providerID: String, modelID: String) -> String {
        "\(providerID)|\(modelID)"
    }

    /// Sends one real turn through the proxy to see whether the model answers.
    func testModel(providerID: String, modelID: String) async {
        guard let paths else { return }
        let key = Self.modelKey(providerID: providerID, modelID: modelID)
        guard !testingModelKeys.contains(key) else { return }
        testingModelKeys.insert(key)
        defer { testingModelKeys.remove(key) }

        let result = await ModelConnectivityTester(paths: paths).test(modelID: modelID)
        modelTestResults[key] = result
    }

    /// Probes every model of one provider.
    ///
    /// Sequential on purpose: firing a dozen live turns at one provider at
    /// once is a good way to get rate limited and misread it as failure.
    func testAllModels(providerID: String) async {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        for model in provider.models {
            await testModel(providerID: providerID, modelID: model.id)
        }
    }

    func loadProviders() {
        providers = (try? providerStoreRepository.loadProviders())?.providers ?? []
        reloadRouteDecisions()
        refreshUsageData()
        refreshSplitState()
    }

    /// 刷新分流三态，供摘要条（B2）在 `loadProviders()` 与代理状态变化后调用。
    /// 取消上一轮读取，避免快速启动/停止时旧结果覆盖新状态。
    func refreshSplitState() {
        splitStateTask?.cancel()
        guard let provider = proxySplitStateProvider else { return }
        splitStateTask = Task { [weak self] in
            let next = await provider()
            guard !Task.isCancelled else { return }
            self?.splitState = next
        }
    }

    /// 重新读取路由决策与它们的名字表（FR-RTE-05）。
    ///
    /// 名字表和记录必须**一起**刷新：分开刷会出现记录已经更新、名字还是上一轮
    /// 的状态，用户看到的是一条张冠李戴的路由结论。
    func reloadRouteDecisions() {
        recentRouteDecisions = routeDecisionLedger?.recent(limit: 50) ?? []
        routeEntityNames = buildRouteEntityNames()
        fallbackPolicy = registryRepository?.loadRegistry().fallbackPolicy ?? .default
    }

    /// 写回失败转移策略（FR-RTE-04）。
    ///
    /// 读改写整份注册表而不是只改这一个字段：注册表没有字段级写入接口，
    /// 局部写会把同一时刻其他改动覆盖掉。
    func updateFallbackPolicy(_ policy: FallbackPolicy) {
        guard let registryRepository else { return }
        var registry = registryRepository.loadRegistry()
        guard registry.fallbackPolicy != policy else { return }
        registry.fallbackPolicy = policy
        do {
            try registryRepository.saveRegistry(registry)
            fallbackPolicy = policy
        } catch {
            // 存不下就不要改内存里的值：让开关弹回原位，用户看到的状态和磁盘
            // 上的一致。悄悄保留一个存不下的设置，下次启动会莫名其妙变回去。
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    /// 从注册表 + v1 配置拼出 id → 显示名。
    ///
    /// 两个来源都要：v2 注册表覆盖内置通道，v1 `providers` 覆盖用户自建端点，
    /// 只查一边会让另一半永远显示成 UUID。
    private func buildRouteEntityNames() -> [String: String] {
        var names: [String: String] = [:]
        for provider in providers {
            names[provider.id] = provider.name
        }
        guard let registryRepository else { return names }
        let registry = registryRepository.loadRegistry()
        for instance in registry.instances {
            names[instance.id] = instance.displayName
        }
        for entry in registry.catalog {
            // 目录条目优先显示策展名，没有就用后端模型 ID——后者至少是用户
            // 在客户端里真正敲过的东西。
            names[entry.id] = entry.displayName ?? entry.backendModelID
        }
        return names
    }

    /// Refreshes the rate-limit snapshots, the ledger aggregates, and — in the
    /// background — the vendor account usage (balance/quota).
    func refreshUsageData() {
        rateLimits = rateLimitRepository?.loadSnapshots() ?? [:]
        usageAggregates = usageLedger?.dailyAggregates(days: 7) ?? []

        guard let accountUsageService else { return }
        let providersToQuery = providers
        isRefreshingAccountUsage = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var results: [String: ProviderAccountUsage] = [:]
            for provider in providersToQuery {
                results[provider.id] = await accountUsageService.fetchUsage(for: provider)
            }
            self.accountUsage = results
            self.isRefreshingAccountUsage = false
        }
    }

    /// Pulls the provider's advertised model list and keeps the ids the user
    /// has not configured yet, so the card can offer to add them.
    func discoverModels(providerID: String) async {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        guard !discoveringModelIDs.contains(providerID) else { return }
        discoveringModelIDs.insert(providerID)
        defer { discoveringModelIDs.remove(providerID) }

        let advertised = await ModelCapabilityDiscovery().listModelIDs(provider: provider)
        let configured = Set(provider.models.map { $0.id.lowercased() })
        let unconfigured = advertised.filter { !configured.contains($0.lowercased()) }
        discoverableModels[providerID] = unconfigured
    }

    /// Adds a curated model to the provider's config (with conservative
    /// defaults, like codex-router's `userModelEntry`).
    func addDiscoveredModel(providerID: String, modelID: String) {
        guard var provider = providers.first(where: { $0.id == providerID }) else { return }
        guard !provider.models.contains(where: { $0.id == modelID }) else { return }
        let entry = ModelCapabilityRegistry.lookup(modelID)
        provider.models.append(
            ProviderModel(
                id: modelID,
                displayName: modelID,
                contextWindow: entry?.contextWindow ?? ProviderModel.fallbackContextWindow,
                contextWindowSource: entry != nil ? .registry : .fallback,
                supportedReasoningEfforts: entry?.supportedReasoningEfforts,
                defaultReasoningEffort: entry?.defaultReasoningEffort,
                reasoningSource: entry != nil ? .registry : .fallback
            )
        )
        do {
            _ = try providerStoreRepository.mutateProviders { store in
                if let index = store.providers.firstIndex(where: { $0.id == providerID }) {
                    store.providers[index] = provider
                }
            }
            discoverableModels[providerID]?.removeAll { $0 == modelID }
            loadProviders()
            onProvidersChanged()
        } catch {
            notice = NoticeMessage(style: .error, text: L10n.tr("providers.curate.add_failed"))
        }
    }

    func detectSubscriptions() {
        isDetectingSubscriptions = true
        Task {
            // Antigravity's model list comes from the network, so detection
            // cannot block the main thread.
            let detected = await importer.detectAll()
            detectedSubscriptions = detected
            isDetectingSubscriptions = false
        }
    }

    func importSubscription(_ subscription: ImportedSubscription) {
        let existingProvider = providers.first {
            $0.name.lowercased() == subscription.providerName.lowercased()
        }
        let provider: ProviderConfig
        if let existingProvider {
            // Re-import: refresh the credentials only. Keep the model list and
            // any capabilities discovery already confirmed, and append model
            // ids the subscription now offers.
            var mergedModels = existingProvider.models
            for modelID in subscription.modelIDs
            where !mergedModels.contains(where: { $0.id == modelID }) {
                mergedModels.append(ProviderModel(id: modelID))
            }
            provider = ProviderConfig(
                id: existingProvider.id,
                name: existingProvider.name,
                baseURL: subscription.baseURL,
                apiKey: subscription.accessToken,
                refreshToken: subscription.refreshToken,
                authKind: subscription.authKind,
                models: mergedModels,
                modelProtocols: existingProvider.modelProtocols,
                defaultProtocol: subscription.protocolKind,
                addedAt: existingProvider.addedAt
            )
        } else {
            provider = ProviderConfig(
                name: subscription.providerName,
                baseURL: subscription.baseURL,
                apiKey: subscription.accessToken,
                refreshToken: subscription.refreshToken,
                authKind: subscription.authKind,
                models: subscription.modelIDs.map { ProviderModel(id: $0) },
                defaultProtocol: subscription.protocolKind
            )
        }
        do {
            _ = try providerStoreRepository.mutateProviders { store in
                if let index = store.providers.firstIndex(where: { $0.id == provider.id }) {
                    store.providers[index] = provider
                } else {
                    store.providers.append(provider)
                }
            }
            loadProviders()
            detectedSubscriptions.removeAll { $0.providerName == subscription.providerName }
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr(existingProvider == nil ? "providers.import.done" : "providers.refresh_auth.updated")
            )
            onProvidersChanged()
            Task { await discoverCapabilities(providerID: provider.id) }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    /// Re-reads the local login for one subscription-imported provider and
    /// updates only its credentials (access token / refresh token). The model
    /// list and discovered capabilities are preserved.
    func refreshProviderAuth(_ provider: ProviderConfig) {
        guard provider.supportsSubscriptionRefresh else { return }
        refreshingProviderIDs.insert(provider.id)
        Task {
            defer { refreshingProviderIDs.remove(provider.id) }
            let detected = await importer.detectAll()
            guard let subscription = detected.first(where: {
                $0.providerName.lowercased() == provider.name.lowercased()
            }) else {
                notice = NoticeMessage(style: .error, text: L10n.tr("providers.refresh_auth.not_found"))
                return
            }

            var updated = provider
            updated.baseURL = subscription.baseURL
            updated.apiKey = subscription.accessToken
            updated.refreshToken = subscription.refreshToken
            updated.authKind = subscription.authKind
            updated.defaultProtocol = subscription.protocolKind
            for modelID in subscription.modelIDs
            where !updated.models.contains(where: { $0.id == modelID }) {
                updated.models.append(ProviderModel(id: modelID))
            }

            do {
                _ = try providerStoreRepository.mutateProviders { store in
                    guard let index = store.providers.firstIndex(where: { $0.id == provider.id }) else { return }
                    store.providers[index] = updated
                }
                loadProviders()
                notice = NoticeMessage(style: .success, text: L10n.tr("providers.refresh_auth.updated"))
                onProvidersChanged()
                Task { await discoverCapabilities(providerID: provider.id) }
            } catch {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }
    }

    private var lastAutoDetectAt: Date?

    /// Silently re-detects local subscriptions (throttled to once per minute)
    /// so the import section stays current without requiring a manual tap.
    func detectSubscriptionsIfNeeded() {
        if let last = lastAutoDetectAt, Date().timeIntervalSince(last) < 60 { return }
        lastAutoDetectAt = Date()
        Task {
            let detected = await importer.detectAll()
            detectedSubscriptions = detected
        }
    }

    func applyPreset(_ preset: ProviderPreset) {
        providerForm = ProviderFormDraft(
            id: "",
            name: preset.name,
            baseURL: preset.baseURL,
            apiKey: "",
            modelListText: preset.exampleModels.joined(separator: ","),
            protocolMode: preset.protocolKind.rawValue
        )
        providerConnectionTestResult = nil
    }

    func beginEditingProvider(_ provider: ProviderConfig) {
        providerForm = ProviderFormDraft(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            modelListText: provider.models.map(\.id).joined(separator: ","),
            protocolMode: provider.defaultProtocol.rawValue
        )
        providerConnectionTestResult = nil
    }

    func saveProviderForm() {
        let draft = providerForm
        let modelIDs = draft.modelListText
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !modelIDs.isEmpty else {
            notice = NoticeMessage(style: .error, text: L10n.tr("settings.providers.invalid_form"))
            return
        }

        let protocolKind = ProviderProtocol(rawValue: draft.protocolMode) ?? .chat
        let existingProvider = providers.first(where: { $0.id == draft.id })
        let provider = ProviderConfig(
            id: draft.id.isEmpty ? UUID().uuidString : draft.id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespaces),
            apiKey: draft.apiKey.trimmingCharacters(in: .whitespaces),
            // Saving an imported provider must not drop its refresh token or
            // auth kind: without them the token expires and every later
            // request (capability discovery, test connection) fails with 401.
            refreshToken: existingProvider?.refreshToken,
            authKind: existingProvider?.authKind ?? .apiKey,
            models: modelIDs.map { modelID in
                // Keep capabilities discovery already confirmed for ids that
                // survive the edit; only brand-new ids start blank and get
                // probed again after save.
                if let old = existingProvider?.models.first(where: { $0.id == modelID }) {
                    return old
                }
                return ProviderModel(id: modelID)
            },
            modelProtocols: existingProvider?.modelProtocols ?? [:],
            defaultProtocol: protocolKind,
            addedAt: draft.id.isEmpty ? Int64(Date().timeIntervalSince1970) : 0
        )

        do {
            _ = try providerStoreRepository.mutateProviders { store in
                if let index = store.providers.firstIndex(where: { $0.id == provider.id }) {
                    store.providers[index] = provider
                } else {
                    store.providers.append(provider)
                }
            }
            loadProviders()
            providerForm = .empty
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.providers.saved"))
            onProvidersChanged()
            // Ask the provider what these models can actually do, then rewrite
            // the Codex catalog with the real numbers.
            Task { await discoverCapabilities(providerID: provider.id) }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    /// Refreshes one provider's model metadata in the background.
    ///
    /// Best-effort: a provider that will not answer keeps whatever is stored,
    /// and the catalog keeps working on the conservative defaults.
    func discoverCapabilities(providerID: String) async {
        guard let provider = (try? providerStoreRepository.loadProviders())?
            .providers.first(where: { $0.id == providerID }) else { return }

        let refreshed = await ModelCapabilityDiscovery().refresh(provider: provider)
        guard refreshed != provider.models else { return }

        do {
            _ = try providerStoreRepository.mutateProviders { store in
                guard let index = store.providers.firstIndex(where: { $0.id == providerID }) else { return }
                store.providers[index].models = refreshed
            }
            loadProviders()
            onProvidersChanged()
        } catch {
            // Discovery is an enhancement; failing to persist it must not
            // surface as an error over a save that already succeeded.
        }
    }

    func removeProvider(_ provider: ProviderConfig) {
        do {
            _ = try providerStoreRepository.mutateProviders { store in
                store.providers.removeAll { $0.id == provider.id }
            }
            loadProviders()
            onProvidersChanged()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func testProviderConnection() async {
        let draft = providerForm
        guard !draft.baseURL.isEmpty else {
            providerConnectionTestResult = L10n.tr("settings.providers.test_missing_url")
            return
        }
        isTestingProviderConnection = true
        providerConnectionTestResult = nil
        defer { isTestingProviderConnection = false }

        let base = draft.baseURL.trimmingCharacters(in: .whitespaces)
        let url = base.hasSuffix("/models") ? URL(string: base) : URL(string: "\(base)/models")
        guard let url else {
            providerConnectionTestResult = L10n.tr("settings.providers.test_invalid_url")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !draft.apiKey.isEmpty {
            request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            providerConnectionTestResult = (200..<300).contains(statusCode)
                ? L10n.tr("settings.providers.test_success")
                : L10n.tr("settings.providers.test_failed_format", String(statusCode))
        } catch {
            providerConnectionTestResult = L10n.tr("settings.providers.test_error_format", error.localizedDescription)
        }
    }
}
