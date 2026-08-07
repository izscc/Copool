import Foundation

/// Protocol spoken by a third-party provider endpoint.
enum ProviderProtocol: String, Codable, Equatable, Sendable {
    case chat          // OpenAI-compatible /chat/completions
    case responses     // OpenAI /responses
    case anthropic     // Anthropic /v1/messages
    case google        // Google Gemini :generateContent / :streamGenerateContent

    /// Human-readable protocol label for UI.
    var displayName: String {
        switch self {
        case .chat: return "OpenAI Chat"
        case .responses: return "Responses"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        }
    }
}

/// How a provider authenticates.
enum ProviderAuthKind: String, Codable, Equatable, Sendable {
    case apiKey             // static API key
    case subscriptionImport // local subscription login imported from another app
}

/// Where a piece of model metadata came from, so a confident value is never
/// overwritten by a guess.
enum ModelMetadataSource: String, Codable, Equatable, Sendable {
    /// Returned by the provider's own API. Authoritative.
    case provider
    /// Taken from a shared registry of known models. Good, not certain.
    case registry
    /// Nothing was available; a conservative default is in use.
    case fallback
}

/// A single backend model id exposed by a provider.
struct ProviderModel: Codable, Equatable, Hashable, Sendable {
    var id: String
    var displayName: String?
    /// Usable context in tokens. `nil` means undiscovered.
    var contextWindow: Int?
    var contextWindowSource: ModelMetadataSource?
    /// Reasoning levels this model actually accepts.
    ///
    /// An empty array is meaningful — it says the provider declared no
    /// selectable levels, so this model is automatic-only. `nil` means the
    /// capability has not been discovered yet.
    var supportedReasoningEfforts: [String]?
    var defaultReasoningEffort: String?
    var reasoningSource: ModelMetadataSource?

    init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        contextWindowSource: ModelMetadataSource? = nil,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil,
        reasoningSource: ModelMetadataSource? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.contextWindowSource = contextWindowSource
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.reasoningSource = reasoningSource
    }

    /// Conservative default used when nothing better is known.
    static let fallbackContextWindow = 200_000

    var effectiveContextWindow: Int {
        contextWindow ?? Self.fallbackContextWindow
    }

    /// **v1 兼容路径专用。新代码不要用它。**
    ///
    /// `nil`（未发现）时兜底三档是 v1 的既有行为。它与 FR-CAT-05 的"绝对不
    /// 猜测"直接冲突——猜错的代价是请求被上游 400 拒掉，而用户在界面上看不到
    /// 任何线索。但 v1 存量用户的模型元数据大多是空的，此刻改掉等于让他们
    /// 一次升级就集体丢失档位选择器，所以保留到迁移完成为止（MIG-02）。
    ///
    /// v2 路径用 `ModelCapabilitiesV2.effectiveReasoningEfforts`，
    /// 同一份数据的 v2 语义读法是 `declaredReasoningEfforts`。
    var effectiveReasoningEfforts: [String] {
        supportedReasoningEfforts ?? ["low", "medium", "high"]
    }

    /// v2 语义：**只报已知的档位，未知就是空**（FR-CAT-05）。
    ///
    /// 与 `effectiveReasoningEfforts` 的唯一差别是 `nil` 的处理。区分两者而
    /// 不是加一个布尔开关，是因为调用点想要哪套语义在读代码时必须一目了然——
    /// 一个 `guessWhenUnknown: false` 参数只会被复制粘贴到不该用它的地方。
    var declaredReasoningEfforts: [String] {
        supportedReasoningEfforts ?? []
    }

    /// Whether a newly discovered value may replace what is stored.
    ///
    /// Provider metadata wins over a registry lookup, which wins over the
    /// fallback; a refresh that lost access to the provider must not
    /// downgrade a value the provider previously confirmed.
    static func shouldReplace(_ current: ModelMetadataSource?, with incoming: ModelMetadataSource) -> Bool {
        func rank(_ source: ModelMetadataSource?) -> Int {
            switch source {
            case .provider: return 3
            case .registry: return 2
            case .fallback: return 1
            case nil: return 0
            }
        }
        return rank(incoming) >= rank(current)
    }
}

/// User-configured third-party channel (OpenAI-compatible endpoint).
struct ProviderConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var refreshToken: String?
    var authKind: ProviderAuthKind
    var models: [ProviderModel]
    var modelProtocols: [String: ProviderProtocol]
    var defaultProtocol: ProviderProtocol
    var addedAt: Int64

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        apiKey: String,
        refreshToken: String? = nil,
        authKind: ProviderAuthKind = .apiKey,
        models: [ProviderModel] = [],
        modelProtocols: [String: ProviderProtocol] = [:],
        defaultProtocol: ProviderProtocol = .chat,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.refreshToken = refreshToken
        self.authKind = authKind
        self.models = models
        self.modelProtocols = modelProtocols
        self.defaultProtocol = defaultProtocol
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiKey
        case refreshToken
        case authKind
        case models
        case modelProtocols
        case defaultProtocol
        case addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        // These keys are accepted only for one-way migration from v1 files.
        // New encodings never write them; ProviderFileRepository hydrates the
        // values from SecureStore at the transport boundary.
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        authKind = try container.decodeIfPresent(ProviderAuthKind.self, forKey: .authKind) ?? .apiKey
        models = try container.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        modelProtocols = try container.decodeIfPresent([String: ProviderProtocol].self, forKey: .modelProtocols) ?? [:]
        defaultProtocol = try container.decodeIfPresent(ProviderProtocol.self, forKey: .defaultProtocol) ?? .chat
        addedAt = try container.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
    }

    /// Secret values are deliberately excluded from every ProviderConfig
    /// encoding. The decoder remains backward-compatible with v1 plaintext
    /// fields so ProviderFileRepository can migrate old files safely.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(authKind, forKey: .authKind)
        try container.encode(models, forKey: .models)
        try container.encode(modelProtocols, forKey: .modelProtocols)
        try container.encode(defaultProtocol, forKey: .defaultProtocol)
        try container.encode(addedAt, forKey: .addedAt)
    }

    /// Stable routing namespace. Provider display names are mutable and must
    /// never become persistent route identity.
    var routePrefix: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The pre-vNext name namespace accepted only as a compatibility alias.
    var legacyRoutePrefix: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Namespace-safe model id exposed to the client using stable identity.
    func clientModelID(for backendModel: String) -> String {
        "\(routePrefix)/\(backendModel)"
    }

    /// Legacy model namespace used to read already-persisted catalog entries.
    func legacyClientModelID(for backendModel: String) -> String {
        "\(legacyRoutePrefix)/\(backendModel)"
    }

    func matchesClientModel(_ requested: String, backendModel: String) -> Bool {
        requested == backendModel
            || requested == clientModelID(for: backendModel)
            || requested == legacyClientModelID(for: backendModel)
    }

    func resolvedProtocol(forModel backendModel: String) -> ProviderProtocol {
        modelProtocols[backendModel] ?? defaultProtocol
    }

    /// Enumerates every backend model with the stable client-visible id.
    var clientModels: [(clientID: String, backendID: String)] {
        models.map { (clientModelID(for: $0.id), $0.id) }
    }

    /// Whether this provider maps to a local subscription login that can be
    /// re-read for fresh credentials (Claude Code, Grok, Cursor, Antigravity).
    ///
    /// Matches on auth kind, refresh token, name and endpoint so providers
    /// imported before the subscription flags existed still get the refresh
    /// affordance.
    var supportsSubscriptionRefresh: Bool {
        if authKind == .subscriptionImport || refreshToken != nil { return true }
        let name = self.name.lowercased()
        let url = baseURL.lowercased()
        let knownNames = ["claude", "grok", "cursor", "antigravity", "agy"]
        return knownNames.contains(name)
            || url.contains("generativelanguage")
            || url.contains("x.ai")
            || url.contains("api.anthropic.com")
            || url.contains("api2.cursor.sh")
    }
}

/// Persisted collection of third-party providers.
struct ProviderStore: Codable, Equatable, Sendable {
    var version: Int
    var providers: [ProviderConfig]

    static let currentVersion = 1

    init(version: Int = ProviderStore.currentVersion, providers: [ProviderConfig] = []) {
        self.version = version
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? ProviderStore.currentVersion
        providers = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
    }
}

/// Aggregated third-party usage for one provider/model pair.
struct ThirdPartyUsageEntry: Codable, Equatable, Sendable, Identifiable {
    var providerID: String
    var providerName: String
    var modelID: String
    var requests: Int
    var promptTokens: Int
    var completionTokens: Int
    var lastUsedAt: Int64

    var id: String { "\(providerID)|\(modelID)" }

    var totalTokens: Int { promptTokens + completionTokens }
}

/// Persisted ledger of third-party usage, keyed by provider/model.
struct ThirdPartyUsageStore: Codable, Equatable, Sendable {
    var version: Int
    var entries: [ThirdPartyUsageEntry]

    static let currentVersion = 1

    init(version: Int = ThirdPartyUsageStore.currentVersion, entries: [ThirdPartyUsageEntry] = []) {
        self.version = version
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? ThirdPartyUsageStore.currentVersion
        entries = try container.decodeIfPresent([ThirdPartyUsageEntry].self, forKey: .entries) ?? []
    }

    mutating func record(
        providerID: String,
        providerName: String,
        modelID: String,
        promptTokens: Int,
        completionTokens: Int,
        at unixSeconds: Int64
    ) {
        if let index = entries.firstIndex(where: { $0.providerID == providerID && $0.modelID == modelID }) {
            entries[index].requests += 1
            entries[index].promptTokens += promptTokens
            entries[index].completionTokens += completionTokens
            entries[index].lastUsedAt = unixSeconds
        } else {
            entries.append(
                ThirdPartyUsageEntry(
                    providerID: providerID,
                    providerName: providerName,
                    modelID: modelID,
                    requests: 1,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    lastUsedAt: unixSeconds
                )
            )
        }
    }
}

/// Editable form state for one provider (shared by Settings and Provider page).
struct ProviderFormDraft: Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var modelListText: String
    var protocolMode: String

    static let empty = ProviderFormDraft(
        id: "",
        name: "",
        baseURL: "",
        apiKey: "",
        modelListText: "",
        protocolMode: ProviderProtocol.chat.rawValue
    )
}
