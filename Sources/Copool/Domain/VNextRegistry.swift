import Foundation

// MARK: - vNext registry domain (Phase 2)
//
// Clean split required by the PRD (docs/11_data_model.md):
//   ProviderDefinition (public, no secrets)
//   1---* ProviderInstance (user config) *---1 CredentialIdentity (ref only)
//   ProviderInstance 1---* ModelCatalogEntry (stable unique key)
//
// Invariants enforced by the type system:
//   - No secret value is Codable/Equatable/loggable: CredentialIdentity holds
//     only a SecureReference (keychain account / env var name).
//   - No ID derives from displayName (AC-005): instance ids are stable UUIDs
//     inherited from v1 and model entries key off instanceID + backendModelID.

/// API dialect spoken by a provider endpoint (maps to the legacy
/// `ProviderProtocol` values).
enum APIDialect: String, Codable, Equatable, Sendable, CaseIterable {
    case chat
    case responses
    case anthropic
    case google

    init(_ legacy: ProviderProtocol) {
        switch legacy {
        case .chat: self = .chat
        case .responses: self = .responses
        case .anthropic: self = .anthropic
        case .google: self = .google
        }
    }

    var legacy: ProviderProtocol {
        switch self {
        case .chat: return .chat
        case .responses: return .responses
        case .anthropic: return .anthropic
        case .google: return .google
        }
    }
}

/// How a provider authenticates (no values, only kinds).
enum CredentialKind: String, Codable, Equatable, Sendable, CaseIterable {
    case apiKey
    /// 凭据只以环境变量名的形式存在，运行时按名读取（FR-IDT-03）。
    case environmentReference
    case oauthDeviceFlow
    /// 复用第三方 CLI 的本机登录态，不复制其内容（FR-IDT-04）。
    case externalCLISession
    case subscriptionImport

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // MIG-03：v2 落盘里写的是 "oauth"，读到时映射到细化后的取值。
        if raw == "oauth" {
            self = .oauthDeviceFlow
            return
        }
        guard let value = CredentialKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的 CredentialKind: \(raw)"
            )
        }
        self = value
    }
}

/// 凭据健康五态（FR-IDT-07）。
enum CredentialHealthState: String, Codable, Equatable, Sendable, CaseIterable {
    case ready
    case unconfigured
    case expired
    case unauthorized
    case verifying
}

/// 复用第三方 CLI 登录态的规格（FR-IDT-04）。只描述来源与披露文案，
/// 不含任何凭据值——读取本身还要过 SEC-08 的披露确认。
struct ExternalSessionSpec: Codable, Equatable, Sendable {
    var cliName: String
    var sessionPathHint: String?
    var disclosure: String
    var requiresExplicitConsent: Bool

    init(
        cliName: String,
        sessionPathHint: String? = nil,
        disclosure: String,
        requiresExplicitConsent: Bool = true
    ) {
        self.cliName = cliName
        self.sessionPathHint = sessionPathHint
        self.disclosure = disclosure
        self.requiresExplicitConsent = requiresExplicitConsent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliName = try container.decode(String.self, forKey: .cliName)
        sessionPathHint = try container.decodeIfPresent(String.self, forKey: .sessionPathHint)
        disclosure = try container.decodeIfPresent(String.self, forKey: .disclosure) ?? ""
        // 缺省即需要确认——披露门禁不允许因为字段缺失而被绕过。
        requiresExplicitConsent = try container.decodeIfPresent(Bool.self, forKey: .requiresExplicitConsent) ?? true
    }
}

/// Where a credential originally came from.
enum CredentialSource: String, Codable, Equatable, Sendable {
    case userEntered
    case importedFromApp
    case environment
    case keychainMigrated
}

/// Opaque reference to a stored secret. Never carries the value.
struct SecureReference: Codable, Equatable, Sendable {
    enum Storage: String, Codable, Equatable, Sendable {
        case keychainAccount
        case environmentVariable
        /// 第三方 CLI 会话文件的路径。**不复制其内容**——运行时按需读取，
        /// 读取前还要过 SEC-08 的同意门禁（FR-IDT-04）。
        case externalSessionFile
    }

    var storage: Storage
    /// Keychain account name、环境变量名，或会话文件路径。
    var name: String
}

/// Public definition of a provider (registry entry, no user data).
struct ProviderDefinition: Codable, Equatable, Sendable, Identifiable {
    /// 未声明前缀时的限流头默认前缀（FR-RUN-04）。
    static let defaultRateLimitHeaderPrefix = "x-ratelimit-"

    /// Stable id, e.g. "deepseek". Never derived from displayName.
    var id: String
    var displayName: String
    var ownership: String
    var supportedProtocols: Set<APIDialect>
    var defaultBaseURL: String
    var credentialKinds: Set<CredentialKind>
    var isBuiltIn: Bool
    /// 覆盖 baseURL 的环境变量名。三级优先级的第二级（FR-PRV-06）。
    var baseURLEnvironmentVariable: String?
    /// 候选凭据环境变量名，按声明顺序探测（FR-IDT-03）。
    var environmentVariables: [String]
    var credentialPrompt: String?
    /// 无内置模型，目录完全依赖实时发现（FR-PRV-01）。
    var catalogOnly: Bool
    /// 同组 provider 共用一把凭据（opencode-go 三通道，FR-PRV-02）。
    var sharedCredentialGroup: String?
    var externalSession: ExternalSessionSpec?
    /// 该 provider 的默认请求 profile；模型条目可逐个覆盖（FR-PRO-05）。
    var requestProfileID: String?
    var rateLimitHeaderPrefix: String
    /// 上游是否返回限流头。false 时 UI 显示"该服务不提供配额信息"，
    /// 而不是显示 0 或未知数字——后者会被读成"配额已用尽"。
    var publishesRateLimitHeaders: Bool
    var notes: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case ownership
        case supportedProtocols
        case defaultBaseURL
        case credentialKinds
        case isBuiltIn
        // 种子数据用的是简短键名，落盘沿用同一套，避免两份 schema。
        case baseURLEnvironmentVariable = "baseUrlEnv"
        case environmentVariables
        case credentialPrompt
        case catalogOnly
        case sharedCredentialGroup
        case externalSession
        case requestProfileID = "requestProfile"
        case rateLimitHeaderPrefix
        case publishesRateLimitHeaders
        case notes
    }

    init(
        id: String,
        displayName: String,
        ownership: String,
        supportedProtocols: Set<APIDialect>,
        defaultBaseURL: String,
        credentialKinds: Set<CredentialKind>,
        isBuiltIn: Bool,
        baseURLEnvironmentVariable: String? = nil,
        environmentVariables: [String] = [],
        credentialPrompt: String? = nil,
        catalogOnly: Bool = false,
        sharedCredentialGroup: String? = nil,
        externalSession: ExternalSessionSpec? = nil,
        requestProfileID: String? = nil,
        rateLimitHeaderPrefix: String = ProviderDefinition.defaultRateLimitHeaderPrefix,
        publishesRateLimitHeaders: Bool = true,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.ownership = ownership
        self.supportedProtocols = supportedProtocols
        self.defaultBaseURL = defaultBaseURL
        self.credentialKinds = credentialKinds
        self.isBuiltIn = isBuiltIn
        self.baseURLEnvironmentVariable = baseURLEnvironmentVariable
        self.environmentVariables = environmentVariables
        self.credentialPrompt = credentialPrompt
        self.catalogOnly = catalogOnly
        self.sharedCredentialGroup = sharedCredentialGroup
        self.externalSession = externalSession
        self.requestProfileID = requestProfileID
        self.rateLimitHeaderPrefix = rateLimitHeaderPrefix
        self.publishesRateLimitHeaders = publishesRateLimitHeaders
        self.notes = notes
    }

    /// 新增字段一律 `decodeIfPresent`：v2 落盘里没有它们，缺字段就报错会让
    /// 老用户的注册表整份读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        ownership = try container.decodeIfPresent(String.self, forKey: .ownership) ?? ""
        supportedProtocols = try container.decodeIfPresent(Set<APIDialect>.self, forKey: .supportedProtocols) ?? [.chat]
        defaultBaseURL = try container.decodeIfPresent(String.self, forKey: .defaultBaseURL) ?? ""
        credentialKinds = try container.decodeIfPresent(Set<CredentialKind>.self, forKey: .credentialKinds) ?? [.apiKey]
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        baseURLEnvironmentVariable = try container.decodeIfPresent(String.self, forKey: .baseURLEnvironmentVariable)
        environmentVariables = try container.decodeIfPresent([String].self, forKey: .environmentVariables) ?? []
        credentialPrompt = try container.decodeIfPresent(String.self, forKey: .credentialPrompt)
        catalogOnly = try container.decodeIfPresent(Bool.self, forKey: .catalogOnly) ?? false
        sharedCredentialGroup = try container.decodeIfPresent(String.self, forKey: .sharedCredentialGroup)
        externalSession = try container.decodeIfPresent(ExternalSessionSpec.self, forKey: .externalSession)
        requestProfileID = try container.decodeIfPresent(String.self, forKey: .requestProfileID)
        rateLimitHeaderPrefix = try container.decodeIfPresent(String.self, forKey: .rateLimitHeaderPrefix)
            ?? ProviderDefinition.defaultRateLimitHeaderPrefix
        publishesRateLimitHeaders = try container.decodeIfPresent(Bool.self, forKey: .publishesRateLimitHeaders) ?? true
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// One provider's credential as stored (reference only — no value).
struct CredentialIdentity: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: CredentialKind
    var secureReference: SecureReference?
    var source: CredentialSource
    var scopes: [String]
    var expiresAt: Int64?
    var lastVerifiedAt: Int64?
    var healthState: CredentialHealthState
    /// 最近一次失败原因。**写入前必须脱敏**——上游错误体里常带 key 片段
    /// 与账号邮箱，原样入库等于把秘密落盘（INV-1）。
    var lastFailureReason: String?
    /// 限流解除时刻（Unix 秒）。nil = 未被限流。
    ///
    /// 与 `healthState` 正交（FR-RTE-03）：被限流的凭据 `healthState` 仍是
    /// `.ready`——它没坏，只是此刻该降权。存的是**解除时刻**而不是布尔量，
    /// 因为布尔量需要有人主动来清除；进程重启、用户关掉窗口、定时器被系统
    /// 掐掉，任何一种都会让这个标记永久卡住，把一家 provider 无声地降权到
    /// 天荒地老。存时刻则是自愈的：时间一过，它自己就不再成立。
    var throttledUntil: Int64?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case secureReference
        case source
        case scopes
        case expiresAt
        case lastVerifiedAt
        case healthState
        case lastFailureReason
        case throttledUntil
    }

    init(
        id: String,
        kind: CredentialKind,
        secureReference: SecureReference? = nil,
        source: CredentialSource,
        scopes: [String] = [],
        expiresAt: Int64? = nil,
        lastVerifiedAt: Int64? = nil,
        healthState: CredentialHealthState = .unconfigured,
        lastFailureReason: String? = nil,
        throttledUntil: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.secureReference = secureReference
        self.source = source
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.lastVerifiedAt = lastVerifiedAt
        self.healthState = healthState
        self.lastFailureReason = lastFailureReason
        self.throttledUntil = throttledUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(CredentialKind.self, forKey: .kind)
        secureReference = try container.decodeIfPresent(SecureReference.self, forKey: .secureReference)
        source = try container.decodeIfPresent(CredentialSource.self, forKey: .source) ?? .userEntered
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
        lastVerifiedAt = try container.decodeIfPresent(Int64.self, forKey: .lastVerifiedAt)
        // v2 没有 healthState：有 secureReference 才可能就绪，否则未配置。
        // 真正的就绪与否由 M1 的状态机在下一次校验时改写。
        healthState = try container.decodeIfPresent(CredentialHealthState.self, forKey: .healthState)
            ?? (secureReference == nil ? .unconfigured : .ready)
        lastFailureReason = try container.decodeIfPresent(String.self, forKey: .lastFailureReason)
        throttledUntil = try container.decodeIfPresent(Int64.self, forKey: .throttledUntil)
    }

    /// 路由门禁三态（FR-RTE-03）。`now` 显式传入，便于测试锁定边界。
    func gateState(now: Int64) -> CredentialGateState {
        switch healthState {
        case .unconfigured, .expired, .unauthorized:
            return .notReady
        case .verifying:
            // 校验中的凭据还没被证明可用，但也没被证否。降权而不是淘汰：
            // 首次配置期间把整家 provider 排除掉，用户会看到"刚加完就用不了"。
            return .throttled
        case .ready:
            if let throttledUntil, throttledUntil > now { return .throttled }
            return .ready
        }
    }
}

/// Per-model capability facts with provenance.
struct ModelCapabilitiesV2: Codable, Equatable, Sendable {
    var contextWindow: Int?
    /// 推理档位。**`nil` 表示未知，`[]` 表示上游明确不支持**——两者语义不同，
    /// 不可合并：未知时不该显示档位选择器，明确不支持时也不该，但前者一旦
    /// 发现到真实档位就要补上，后者不该被任何推断覆盖（FR-CAT-05）。
    var supportedReasoningEfforts: [String]?
    var defaultReasoningEffort: String?
    /// 可接受的输入模态（text / image / audio…）。空表示未知。
    var inputModalities: [String]
    var supportsVision: Bool?
    var supportsTools: Bool?
    var supportsParallelTools: Bool?
    var supportsAudio: Bool?
    var supportsRealtime: Bool?
    var supportsComputerUse: Bool?
    var supportsStructuredOutput: Bool?
    var costIndex: Double?
    var region: String?

    private enum CodingKeys: String, CodingKey {
        case contextWindow
        case supportedReasoningEfforts
        case defaultReasoningEffort
        case inputModalities
        case supportsVision
        case supportsTools
        case supportsParallelTools
        case supportsAudio
        case supportsRealtime
        case supportsComputerUse
        case supportsStructuredOutput
        case costIndex
        case region
    }

    init(
        contextWindow: Int? = nil,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil,
        inputModalities: [String] = [],
        supportsVision: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsParallelTools: Bool? = nil,
        supportsAudio: Bool? = nil,
        supportsRealtime: Bool? = nil,
        supportsComputerUse: Bool? = nil,
        supportsStructuredOutput: Bool? = nil,
        costIndex: Double? = nil,
        region: String? = nil
    ) {
        self.contextWindow = contextWindow
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsParallelTools = supportsParallelTools
        self.supportsAudio = supportsAudio
        self.supportsRealtime = supportsRealtime
        self.supportsComputerUse = supportsComputerUse
        self.supportsStructuredOutput = supportsStructuredOutput
        self.costIndex = costIndex
        self.region = region
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        supportedReasoningEfforts = try container.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts)
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities) ?? []
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
        supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools)
        supportsParallelTools = try container.decodeIfPresent(Bool.self, forKey: .supportsParallelTools)
        supportsAudio = try container.decodeIfPresent(Bool.self, forKey: .supportsAudio)
        supportsRealtime = try container.decodeIfPresent(Bool.self, forKey: .supportsRealtime)
        supportsComputerUse = try container.decodeIfPresent(Bool.self, forKey: .supportsComputerUse)
        supportsStructuredOutput = try container.decodeIfPresent(Bool.self, forKey: .supportsStructuredOutput)
        costIndex = try container.decodeIfPresent(Double.self, forKey: .costIndex)
        region = try container.decodeIfPresent(String.self, forKey: .region)
    }

    // MARK: - 推理档位（FR-CAT-05：绝对不猜测）

    /// 可提供给用户的推理档位。**未知即为空**。
    ///
    /// 与 v1 的 `ProviderModel.effectiveReasoningEfforts` 刻意相反：后者在
    /// `nil` 时兜底 `["low","medium","high"]`。那三档是猜的，猜错就是上游
    /// 400，而用户看到的只是"请求失败"，无从知晓是因为界面给了它一个上游
    /// 不认识的字段。少给一个选择器远比这个便宜。
    var effectiveReasoningEfforts: [String] {
        supportedReasoningEfforts ?? []
    }

    /// 是否显示推理档位选择器。
    ///
    /// `nil`（未发现）与 `[]`（上游明确表示没有）在这里的答案相同，但两者
    /// **不可在存储层合并**：前者遇到真实发现结果要补上，后者不该被任何
    /// 推断覆盖。所以这是一个计算属性，而不是落盘时的规范化。
    var showsReasoningEffortPicker: Bool {
        !effectiveReasoningEfforts.isEmpty
    }

    /// 本次请求该附加的档位；返回 `nil` 表示**不附加任何推理参数**。
    ///
    /// 用户请求了一个未声明的档位时不做就近取整——静默把 `high` 降成 `low`
    /// 会让用户以为模型在偷工减料。返回声明列表里的默认值，让行为可解释。
    func resolvedReasoningEffort(requested: String?) -> String? {
        let supported = effectiveReasoningEfforts
        guard !supported.isEmpty else { return nil }
        if let requested, supported.contains(requested) { return requested }
        if let declared = defaultReasoningEffort, supported.contains(declared) { return declared }
        return supported.contains("medium") ? "medium" : supported.first
    }
}

/// 一次实时模型发现的结果（FR-CAT-03）。
///
/// 存在的理由是"发现失败不清空已有目录，只标记上次刷新失败 + 时间 + 原因"。
/// 把失败当作"上游现在只有 0 个模型"是最坏的处理：用户策展过的目录会在一次
/// 网络抖动后消失，而他完全无法把这件事和刚才那次点击联系起来。
struct CatalogRefreshState: Codable, Equatable, Sendable {
    var lastAttemptAt: Int64
    var lastSuccessAt: Int64?
    /// **已脱敏**的失败原因；`nil` 表示上次尝试成功（INV-1）。
    var failureReason: String?
    /// 上次成功时上游列出的模型数。
    var discoveredCount: Int?
    /// 上次成功时新入库的条目数。用于回答"刷新到底做了什么"。
    var addedCount: Int?

    var succeeded: Bool { failureReason == nil }

    init(
        lastAttemptAt: Int64,
        lastSuccessAt: Int64? = nil,
        failureReason: String? = nil,
        discoveredCount: Int? = nil,
        addedCount: Int? = nil
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failureReason = failureReason
        self.discoveredCount = discoveredCount
        self.addedCount = addedCount
    }
}

/// Provenance per metadata field (provider > registry > fallback).
enum MetadataSource: String, Codable, Equatable, Sendable {
    case provider
    case registry
    case fallback

    init(_ legacy: ModelMetadataSource) {
        switch legacy {
        case .provider: self = .provider
        case .registry: self = .registry
        case .fallback: self = .fallback
        }
    }
}

/// How visible a model is in pickers.
enum ModelVisibility: String, Codable, Equatable, Sendable {
    case visible
    case hidden
    case curated
}

/// 目录条目的来源。用于区分"种子发的"与"用户自己加的"，
/// 种子升级时前者整体替换，后者原样保留（MIG-03）。
enum ModelCatalogOrigin: String, Codable, Equatable, Sendable {
    case seed
    case discovered
    case userAdded
}

/// Stable catalog entry: unique key = providerInstanceID + backendModelID.
struct ModelCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    var providerInstanceID: String
    var backendModelID: String
    var displayName: String?
    /// Stable user-managed aliases; display names are not routing identity.
    var aliases: [String]
    var capabilities: ModelCapabilitiesV2
    var metadataSources: [String: MetadataSource]
    var visibility: ModelVisibility
    /// 指向 `ProviderRegistryV2.requestProfiles` 的键；nil 时回落到
    /// provider 的默认 profile，再落空则用保守默认（FR-PRO-05）。
    var requestProfileID: String?
    /// 建议触发压缩的 token 阈值，恒小于 contextWindow。
    var autoCompactThreshold: Int?
    var origin: ModelCatalogOrigin
    /// 上游是否仍提供该模型。下架的条目标 false 后保留记录，不静默删除，
    /// 否则用户会以为是自己误删（FR-CAT-04）。
    var upstreamAvailable: Bool

    /// Stable unique key (AC-011): instance + backend model.
    var id: String { "\(providerInstanceID)/\(backendModelID)" }

    /// 选择器里显示的名字。`displayName` 为空时退到后端 id——显示一个空行
    /// 会让用户以为条目坏了（FR-CAT-07）。
    var effectiveDisplayName: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return backendModelID
        }
        return displayName
    }

    /// 上下文窗口的来源层。缺记录时按 `fallback` 处理——没有出处的数字就是
    /// 估算值，不该被显示成上游确认过的（FR-CAT-06）。
    var contextWindowSource: MetadataSource {
        metadataSources["contextWindow"] ?? .fallback
    }

    /// 推理档位的来源层。同上。
    var reasoningSource: MetadataSource {
        metadataSources["reasoningEfforts"] ?? metadataSources["reasoning"] ?? .fallback
    }

    /// 当前上下文窗口是不是估算值。UI 必须给它打「估算」标记（FR-CAT-06）。
    var hasEstimatedContextWindow: Bool {
        capabilities.contextWindow == nil || contextWindowSource == .fallback
    }

    /// 搜索匹配显示名与后端 ID 两者，别名也算（FR-CAT-08 / SCR-PRV-02）。
    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        if backendModelID.lowercased().contains(needle) { return true }
        if effectiveDisplayName.lowercased().contains(needle) { return true }
        return aliases.contains { $0.lowercased().contains(needle) }
    }

    private enum CodingKeys: String, CodingKey {
        case providerInstanceID
        case backendModelID
        case displayName
        case aliases
        case capabilities
        case metadataSources
        case visibility
        case requestProfileID
        case autoCompactThreshold
        case origin
        case upstreamAvailable
    }

    init(
        providerInstanceID: String,
        backendModelID: String,
        displayName: String? = nil,
        aliases: [String] = [],
        capabilities: ModelCapabilitiesV2 = ModelCapabilitiesV2(),
        metadataSources: [String: MetadataSource] = [:],
        visibility: ModelVisibility = .visible,
        requestProfileID: String? = nil,
        autoCompactThreshold: Int? = nil,
        origin: ModelCatalogOrigin = .userAdded,
        upstreamAvailable: Bool = true
    ) {
        self.providerInstanceID = providerInstanceID
        self.backendModelID = backendModelID
        self.displayName = displayName
        self.aliases = aliases
        self.capabilities = capabilities
        self.metadataSources = metadataSources
        self.visibility = visibility
        self.requestProfileID = requestProfileID
        self.autoCompactThreshold = autoCompactThreshold
        self.origin = origin
        self.upstreamAvailable = upstreamAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerInstanceID = try container.decode(String.self, forKey: .providerInstanceID)
        backendModelID = try container.decode(String.self, forKey: .backendModelID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        capabilities = try container.decodeIfPresent(ModelCapabilitiesV2.self, forKey: .capabilities) ?? ModelCapabilitiesV2()
        metadataSources = try container.decodeIfPresent([String: MetadataSource].self, forKey: .metadataSources) ?? [:]
        visibility = try container.decodeIfPresent(ModelVisibility.self, forKey: .visibility) ?? .visible
        requestProfileID = try container.decodeIfPresent(String.self, forKey: .requestProfileID)
        autoCompactThreshold = try container.decodeIfPresent(Int.self, forKey: .autoCompactThreshold)
        // v2 存量条目全部是用户手动加的（种子这次才引入）——MIG-02。
        origin = try container.decodeIfPresent(ModelCatalogOrigin.self, forKey: .origin) ?? .userAdded
        upstreamAvailable = try container.decodeIfPresent(Bool.self, forKey: .upstreamAvailable) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerInstanceID, forKey: .providerInstanceID)
        try container.encode(backendModelID, forKey: .backendModelID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(metadataSources, forKey: .metadataSources)
        try container.encode(visibility, forKey: .visibility)
        try container.encodeIfPresent(requestProfileID, forKey: .requestProfileID)
        try container.encodeIfPresent(autoCompactThreshold, forKey: .autoCompactThreshold)
        try container.encode(origin, forKey: .origin)
        try container.encode(upstreamAvailable, forKey: .upstreamAvailable)
    }
}

/// 请求体差异档案（DM-06）。描述某个上游对推理参数与工具声明的特殊要求。
struct RequestProfile: Codable, Equatable, Sendable {
    /// 该上游用哪个字段表达"要思考多久"。
    enum ReasoningParameter: String, Codable, Equatable, Sendable, CaseIterable {
        case none
        case reasoningEffort
        case thinking
        case enableThinking
        case thinkingBudget
    }

    var reasoningParameter: ReasoningParameter
    /// 上游是否接受"关闭思考"。**默认 false**：猜错方向的代价不对称——
    /// 误以为可关就会发出被拒的字段直接 400，误以为不可关只是少一个开关。
    var supportsDisable: Bool
    /// 上游强制的档位，用户选择在此被忽略。
    var forcedEffort: String?
    /// 兼容面会拒绝各厂商原生 thinking 参数，转发前必须剥离。
    var stripVendorNativeThinking: Bool
    /// 该通道需要附加的托管工具声明（由上游决定何时调用）。
    var injectHostedTools: [String]
    var notes: String?

    /// 未命中 profile 时的保守默认：不附加任何非标准字段（FR-PRO-05）。
    static let conservativeDefault = RequestProfile()

    private enum CodingKeys: String, CodingKey {
        case reasoningParameter
        case supportsDisable
        case forcedEffort
        case stripVendorNativeThinking
        case injectHostedTools
        case notes
    }

    init(
        reasoningParameter: ReasoningParameter = .none,
        supportsDisable: Bool = false,
        forcedEffort: String? = nil,
        stripVendorNativeThinking: Bool = false,
        injectHostedTools: [String] = [],
        notes: String? = nil
    ) {
        self.reasoningParameter = reasoningParameter
        self.supportsDisable = supportsDisable
        self.forcedEffort = forcedEffort
        self.stripVendorNativeThinking = stripVendorNativeThinking
        self.injectHostedTools = injectHostedTools
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoningParameter = try container.decodeIfPresent(ReasoningParameter.self, forKey: .reasoningParameter) ?? .none
        supportsDisable = try container.decodeIfPresent(Bool.self, forKey: .supportsDisable) ?? false
        forcedEffort = try container.decodeIfPresent(String.self, forKey: .forcedEffort)
        stripVendorNativeThinking = try container.decodeIfPresent(Bool.self, forKey: .stripVendorNativeThinking) ?? false
        injectHostedTools = try container.decodeIfPresent([String].self, forKey: .injectHostedTools) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// User-configured provider channel (billable endpoint).
struct ProviderInstance: Codable, Equatable, Sendable, Identifiable {
    /// Stable route key (AC-005). v1 UUIDs are inherited as-is.
    var id: String
    var definitionID: String
    var displayName: String
    var endpoint: String
    var credentialID: String
    var protocolBindings: [String: APIDialect]
    var defaultProtocol: APIDialect
    var enabled: Bool
    var addedAt: Int64
    /// 用户对 baseURL 的显式覆盖。三级优先级的第一级（FR-PRV-06）。
    var baseURLOverride: String?
    /// 多账号：同一通道下可挂多把凭据轮换。`credentialID` 是其中的首选，
    /// 保留它是为了让既有路由路径不必一次性改写。
    var credentialIdentityIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case definitionID
        case displayName
        case endpoint
        case credentialID
        case protocolBindings
        case defaultProtocol
        case enabled
        case addedAt
        case baseURLOverride
        case credentialIdentityIDs
    }

    init(
        id: String,
        definitionID: String,
        displayName: String,
        endpoint: String,
        credentialID: String,
        protocolBindings: [String: APIDialect],
        defaultProtocol: APIDialect,
        enabled: Bool,
        addedAt: Int64,
        baseURLOverride: String? = nil,
        credentialIdentityIDs: [String] = []
    ) {
        self.id = id
        self.definitionID = definitionID
        self.displayName = displayName
        self.endpoint = endpoint
        self.credentialID = credentialID
        self.protocolBindings = protocolBindings
        self.defaultProtocol = defaultProtocol
        self.enabled = enabled
        self.addedAt = addedAt
        self.baseURLOverride = baseURLOverride
        self.credentialIdentityIDs = credentialIdentityIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        definitionID = try container.decode(String.self, forKey: .definitionID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        credentialID = try container.decodeIfPresent(String.self, forKey: .credentialID) ?? ""
        protocolBindings = try container.decodeIfPresent([String: APIDialect].self, forKey: .protocolBindings) ?? [:]
        defaultProtocol = try container.decodeIfPresent(APIDialect.self, forKey: .defaultProtocol) ?? .chat
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        addedAt = try container.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
        baseURLOverride = try container.decodeIfPresent(String.self, forKey: .baseURLOverride)
        // v2 只有单把凭据：把它作为多账号列表的唯一成员，语义等价。
        let identityIDs = try container.decodeIfPresent([String].self, forKey: .credentialIdentityIDs)
        credentialIdentityIDs = identityIDs ?? (credentialID.isEmpty ? [] : [credentialID])
    }
}

/// Versioned v2 registry store (no secrets by construction).
struct ProviderRegistryV2: Codable, Equatable, Sendable {
    /// 3：新增 `requestProfiles` 与 `CredentialKind` 语义细化（MIG-02）。
    static let currentVersion = 3

    var version: Int
    var definitions: [ProviderDefinition]
    var instances: [ProviderInstance]
    var credentials: [CredentialIdentity]
    var catalog: [ModelCatalogEntry]
    /// Definitions the user overrode or added (user overlay layer).
    var userDefinitions: [ProviderDefinition]
    /// 请求体差异档案，键由 `ModelCatalogEntry.requestProfileID` 与
    /// `ProviderDefinition.requestProfileID` 引用（DM-08）。
    var requestProfiles: [String: RequestProfile]
    /// 每个实例上次实时发现的结果，键是 instance id（FR-CAT-03）。
    ///
    /// 放在这里而不是 `ProviderInstance` 上：这是运行痕迹，不是用户配置。
    /// 混进配置里，导出/对比配置时会多出一堆每次刷新都在变的噪声字段。
    var catalogRefreshStates: [String: CatalogRefreshState]
    /// 失败转移策略（FR-RTE-04）。换 provider 意味着换计费主体，这一档只能由
    /// 用户明确选定，所以它是配置而非常量——原先硬编码在 `V2RouteResolver` 里，
    /// 用户无从关闭。
    var fallbackPolicy: FallbackPolicy

    private enum CodingKeys: String, CodingKey {
        case version
        case definitions
        case instances
        case credentials
        case catalog
        case userDefinitions
        case requestProfiles
        case catalogRefreshStates
        case fallbackPolicy
    }

    init(
        version: Int = ProviderRegistryV2.currentVersion,
        definitions: [ProviderDefinition] = [],
        instances: [ProviderInstance] = [],
        credentials: [CredentialIdentity] = [],
        catalog: [ModelCatalogEntry] = [],
        userDefinitions: [ProviderDefinition] = [],
        requestProfiles: [String: RequestProfile] = [:],
        catalogRefreshStates: [String: CatalogRefreshState] = [:],
        fallbackPolicy: FallbackPolicy = .default
    ) {
        self.fallbackPolicy = fallbackPolicy
        self.version = version
        self.definitions = definitions
        self.instances = instances
        self.credentials = credentials
        self.catalog = catalog
        self.userDefinitions = userDefinitions
        self.requestProfiles = requestProfiles
        self.catalogRefreshStates = catalogRefreshStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        definitions = try container.decodeIfPresent([ProviderDefinition].self, forKey: .definitions) ?? []
        instances = try container.decodeIfPresent([ProviderInstance].self, forKey: .instances) ?? []
        credentials = try container.decodeIfPresent([CredentialIdentity].self, forKey: .credentials) ?? []
        catalog = try container.decodeIfPresent([ModelCatalogEntry].self, forKey: .catalog) ?? []
        userDefinitions = try container.decodeIfPresent([ProviderDefinition].self, forKey: .userDefinitions) ?? []
        requestProfiles = try container.decodeIfPresent([String: RequestProfile].self, forKey: .requestProfiles) ?? [:]
        catalogRefreshStates = try container
            .decodeIfPresent([String: CatalogRefreshState].self, forKey: .catalogRefreshStates) ?? [:]
        // 老 registry 没有这个字段，落到 `.default`（同供应商、3 次）——与该字段
        // 引入前 `V2RouteResolver` 里硬编码的行为一致，升级不改变既有路由结果。
        fallbackPolicy = try container.decodeIfPresent(FallbackPolicy.self, forKey: .fallbackPolicy) ?? .default
    }

    func definition(id: String) -> ProviderDefinition? {
        definitions.first { $0.id == id } ?? userDefinitions.first { $0.id == id }
    }

    func instance(id: String) -> ProviderInstance? {
        instances.first { $0.id == id }
    }

    func credential(id: String) -> CredentialIdentity? {
        credentials.first { $0.id == id }
    }

    func catalogEntries(instanceID: String) -> [ModelCatalogEntry] {
        catalog.filter { $0.providerInstanceID == instanceID }
    }

    /// 目录条目 → provider 默认 → 保守默认。三级都落空时不附加任何
    /// 非标准字段，而不是猜一个（FR-PRO-05）。
    func requestProfile(for entry: ModelCatalogEntry) -> RequestProfile {
        if let id = entry.requestProfileID, let profile = requestProfiles[id] {
            return profile
        }
        guard let instance = instance(id: entry.providerInstanceID),
              let fallbackID = definition(id: instance.definitionID)?.requestProfileID,
              let profile = requestProfiles[fallbackID] else {
            return .conservativeDefault
        }
        return profile
    }
}

// MARK: - Migration journal

/// One completed (or rolled back) v1→v2 migration step.
struct MigrationEntry: Codable, Equatable, Sendable {
    var journalID: String
    var migratedAt: Int64
    var fromVersion: Int
    var toVersion: Int
    /// Shadow writes land in a sidecar before the active store flips.
    var shadowed: Bool
    var verified: Bool
    var rolledBack: Bool?
    /// Fingerprint of the source (v1) store, for idempotence.
    var sourceHash: String
    /// 失败原因（已脱敏，INV-1）。`verified == false` 时才有值。
    ///
    /// 成功的记录不带这个字段：老账本解码时它自然是 nil，不需要迁移账本本身。
    var failureReason: String?

    init(
        journalID: String,
        migratedAt: Int64,
        fromVersion: Int,
        toVersion: Int,
        shadowed: Bool,
        verified: Bool,
        rolledBack: Bool? = nil,
        sourceHash: String,
        failureReason: String? = nil
    ) {
        self.journalID = journalID
        self.migratedAt = migratedAt
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.shadowed = shadowed
        self.verified = verified
        self.rolledBack = rolledBack
        self.sourceHash = sourceHash
        self.failureReason = failureReason
    }
}

/// Append-only migration ledger (migration-journal.json).
struct MigrationJournal: Codable, Equatable, Sendable {
    var version: Int
    var entries: [MigrationEntry]

    static let currentVersion = 1

    init(version: Int = MigrationJournal.currentVersion, entries: [MigrationEntry] = []) {
        self.version = version
        self.entries = entries
    }

    func lastEntry(sourceHash: String) -> MigrationEntry? {
        entries.last { $0.sourceHash == sourceHash }
    }
}
