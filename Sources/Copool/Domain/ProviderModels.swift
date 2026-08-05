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

    /// Levels to offer for this model. Undiscovered models keep the common
    /// three; a provider that explicitly returned none keeps none.
    var effectiveReasoningEfforts: [String] {
        supportedReasoningEfforts ?? ["low", "medium", "high"]
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        authKind = try container.decodeIfPresent(ProviderAuthKind.self, forKey: .authKind) ?? .apiKey
        models = try container.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        modelProtocols = try container.decodeIfPresent([String: ProviderProtocol].self, forKey: .modelProtocols) ?? [:]
        defaultProtocol = try container.decodeIfPresent(ProviderProtocol.self, forKey: .defaultProtocol) ?? .chat
        addedAt = try container.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
    }

    /// Normalized routing key used as the model namespace prefix in ChatGPT.app.
    var routePrefix: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Namespace-safe model id exposed to the client, e.g. `deepseek/deepseek-chat`.
    func clientModelID(for backendModel: String) -> String {
        "\(routePrefix)/\(backendModel)"
    }

    func resolvedProtocol(forModel backendModel: String) -> ProviderProtocol {
        modelProtocols[backendModel] ?? defaultProtocol
    }

    /// Enumerates every backend model with the client-visible id.
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
