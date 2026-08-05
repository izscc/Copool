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
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", protocolKind: .google, exampleModels: ["gemini-3-pro", "gemini-3-flash"]),
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
    private let registryRepository: ProviderRegistryV2Repository?
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

    /// Credential-aware catalog rows built from the v2 registry (AC-011).
    @Published var catalogRows: [CatalogBuilder.CatalogRow] = []
    @Published var catalogHiddenCount = 0

    /// Models the provider advertises but the user has not configured yet,
    /// keyed by provider id (curation candidates).
    @Published var discoverableModels: [String: [String]] = [:]
    @Published var discoveringModelIDs: Set<String> = []

    init(
        providerStoreRepository: ProviderStoreRepository,
        usageRepository: ThirdPartyUsageRepository? = nil,
        paths: FileSystemPaths? = nil,
        rateLimitRepository: ProviderRateLimitFileRepository? = nil,
        usageLedger: UsageEventLedger? = nil,
        accountUsageService: ProviderAccountUsageService? = nil,
        registryRepository: ProviderRegistryV2Repository? = nil,
        onProvidersChanged: @escaping () -> Void = {}
    ) {
        self.providerStoreRepository = providerStoreRepository
        self.usageRepository = usageRepository
        self.paths = paths
        self.rateLimitRepository = rateLimitRepository
        self.usageLedger = usageLedger
        self.accountUsageService = accountUsageService
        self.registryRepository = registryRepository
        self.onProvidersChanged = onProvidersChanged
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
        refreshUsageData()
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
