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

    private let importer = LocalSubscriptionImporter()

    @Published var providers: [ProviderConfig] = []
    @Published var detectedSubscriptions: [ImportedSubscription] = []
    @Published var isDetectingSubscriptions = false
    @Published var providerForm: ProviderFormDraft = .empty
    @Published var isTestingProviderConnection = false
    @Published var providerConnectionTestResult: String?
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    private let noticeScheduler = NoticeAutoDismissScheduler()

    init(
        providerStoreRepository: ProviderStoreRepository,
        usageRepository: ThirdPartyUsageRepository? = nil,
        onProvidersChanged: @escaping () -> Void = {}
    ) {
        self.providerStoreRepository = providerStoreRepository
        self.usageRepository = usageRepository
        self.onProvidersChanged = onProvidersChanged
    }

    func loadProviders() {
        providers = (try? providerStoreRepository.loadProviders())?.providers ?? []
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
        let provider = ProviderConfig(
            name: subscription.providerName,
            baseURL: subscription.baseURL,
            apiKey: subscription.accessToken,
            refreshToken: subscription.refreshToken,
            authKind: subscription.authKind,
            models: subscription.modelIDs.map { ProviderModel(id: $0) },
            defaultProtocol: subscription.protocolKind
        )
        do {
            _ = try providerStoreRepository.mutateProviders { store in
                store.providers.removeAll { $0.name.lowercased() == provider.name.lowercased() }
                store.providers.append(provider)
            }
            loadProviders()
            detectedSubscriptions.removeAll { $0.providerName == subscription.providerName }
            notice = NoticeMessage(style: .success, text: L10n.tr("providers.import.done"))
            onProvidersChanged()
            Task { await discoverCapabilities(providerID: provider.id) }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
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
        let provider = ProviderConfig(
            id: draft.id.isEmpty ? UUID().uuidString : draft.id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespaces),
            apiKey: draft.apiKey.trimmingCharacters(in: .whitespaces),
            models: modelIDs.map { ProviderModel(id: $0) },
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
