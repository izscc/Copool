import Foundation

// MARK: - Route policy & decision trace (Phase 5)

/// How the caller selected a model (docs/12_api_contracts: explicit / alias /
/// auto).
enum ModelSelectionKind: String, Codable, Equatable, Sendable {
    case explicit
    case alias
    case auto
}

/// Hard constraints applied before scoring (AC-012: "先硬过滤后评分").
struct RouteHardConstraints: Codable, Equatable, Sendable {
    /// Provider instances that may be used; empty = all enabled.
    var allowedProviderInstanceIDs: [String]
    /// Protocols the route must support.
    var requiredDialects: Set<APIDialect>
    /// Minimum context window.
    var minContextWindow: Int?
    /// Reasoning effort must be in this set, when the caller requires it.
    var requiredReasoningEfforts: [String]?
    /// Capabilities the model must have (e.g. vision, tools).
    var requiredCapabilities: Set<String>
    /// Must be available to the target binding.
    var targetBindingID: String?
    /// Explicit backend model or stable catalog alias, when selected.
    var requestedEntryID: String?
    /// User budget remaining for this request, when enforced.
    var remainingBudget: Double?
    /// Region restriction for residency/endpoint policy.
    var requiredRegion: String?

    init(
        allowedProviderInstanceIDs: [String] = [],
        requiredDialects: Set<APIDialect> = [],
        minContextWindow: Int? = nil,
        requiredReasoningEfforts: [String]? = nil,
        requiredCapabilities: Set<String> = [],
        targetBindingID: String? = nil,
        requestedEntryID: String? = nil,
        remainingBudget: Double? = nil,
        requiredRegion: String? = nil
    ) {
        self.allowedProviderInstanceIDs = allowedProviderInstanceIDs
        self.requiredDialects = requiredDialects
        self.minContextWindow = minContextWindow
        self.requiredReasoningEfforts = requiredReasoningEfforts
        self.requiredCapabilities = requiredCapabilities
        self.targetBindingID = targetBindingID
        self.requestedEntryID = requestedEntryID
        self.remainingBudget = remainingBudget
        self.requiredRegion = requiredRegion
    }
}

/// Runtime facts used for scoring without storing provider secrets.
struct RouteRuntimeMetrics: Codable, Equatable, Sendable {
    var healthScore: Double
    var quotaRemaining: Double?
    var latencyMilliseconds: Double?
    var costIndex: Double?
    var userPriority: Double
    var sessionAffinity: Double

    static let `default` = RouteRuntimeMetrics(
        healthScore: 1,
        quotaRemaining: nil,
        latencyMilliseconds: nil,
        costIndex: nil,
        userPriority: 0,
        sessionAffinity: 0
    )
}

/// 凭据门禁三态（FR-RTE-03）。
///
/// 关键点是 `.throttled` **不是硬淘汰**：一个 provider 被限流几十秒，不该让
/// 它名下的所有模型在这段时间里彻底消失——那会把「稍等一下就好」放大成
/// 「整家 provider 下线」，用户看到的是路由莫名其妙全部涌向备用渠道、账单
/// 结构突变。正确做法是让它带着降权继续参与打分：有更好的候选就自然让位，
/// 没有别的候选时它仍然可用。
///
/// 这个枚举**只描述凭据的状态，不携带任何密文**。RoutePlanner 拿到的是
/// 这个值，而不是密钥本身（FR-RTE-03 的硬性要求）。
enum CredentialGateState: String, Codable, Equatable, Sendable {
    /// 凭据存在且可用。
    case ready
    /// 凭据缺失、已撤销、或已被标记为 unauthorized（401）。硬淘汰。
    case notReady
    /// 凭据可用但正在被上游限流（429）。降权参与打分，不淘汰。
    case throttled

    /// 硬过滤是否应当淘汰这个候选。
    var isHardExcluded: Bool { self == .notReady }

    /// 打分时的乘数。
    ///
    /// 0.35 是刻意选的：足够低，使得任何一个 `.ready` 的同类候选都会赢过
    /// 被限流的这个；又足够高，使得在「只剩它」时它的分数不会掉到被
    /// 其他淘汰规则误伤的地步。
    var scoreMultiplier: Double {
        switch self {
        case .ready: return 1.0
        case .throttled: return 0.35
        case .notReady: return 0
        }
    }
}


/// Request-side routing context. It is intentionally secret-free.
struct RouteRequestContext: Codable, Equatable, Sendable {
    var targetBindingID: String?
    var sessionID: String?
    var requestedCapabilities: Set<String>
    var requestedRegion: String?
    var remainingBudget: Double?
    var explicitEntryID: String?
    var alias: String?
    var selectionKind: ModelSelectionKind

    static let `default` = RouteRequestContext(
        targetBindingID: nil,
        sessionID: nil,
        requestedCapabilities: [],
        requestedRegion: nil,
        remainingBudget: nil,
        explicitEntryID: nil,
        alias: nil,
        selectionKind: .auto
    )
}

extension RouteHardConstraints {
    init(request: RouteRequestContext, allowedProviderInstanceIDs: [String] = [], requiredDialects: Set<APIDialect> = [], minContextWindow: Int? = nil, requiredReasoningEfforts: [String]? = nil) {
        self.init(
            allowedProviderInstanceIDs: allowedProviderInstanceIDs,
            requiredDialects: requiredDialects,
            minContextWindow: minContextWindow,
            requiredReasoningEfforts: requiredReasoningEfforts,
            requiredCapabilities: request.requestedCapabilities,
            targetBindingID: request.targetBindingID,
            requestedEntryID: request.explicitEntryID,
            remainingBudget: request.remainingBudget,
            requiredRegion: request.requestedRegion
        )
    }
}

/// Scoring weights for auto routing.
struct RouteWeights: Codable, Equatable, Sendable {
    var contextFit: Double
    var reasoningFit: Double
    var freshness: Double
    var costIndex: Double
    var health: Double
    var quota: Double
    var latency: Double
    var priority: Double
    var affinity: Double

    init(
        contextFit: Double,
        reasoningFit: Double,
        freshness: Double,
        costIndex: Double,
        health: Double = 0.8,
        quota: Double = 0.6,
        latency: Double = 0.4,
        priority: Double = 0.3,
        affinity: Double = 0.3
    ) {
        self.contextFit = contextFit
        self.reasoningFit = reasoningFit
        self.freshness = freshness
        self.costIndex = costIndex
        self.health = health
        self.quota = quota
        self.latency = latency
        self.priority = priority
        self.affinity = affinity
    }

    static let `default` = RouteWeights(contextFit: 1.0, reasoningFit: 0.8, freshness: 0.3, costIndex: 0.5)
}

/// Failover policy (FR-RTE-04：三档，从不转移到跨供应商转移)。
struct FallbackPolicy: Codable, Equatable, Sendable {
    enum Strategy: String, Codable, Equatable, Sendable, CaseIterable {
        /// 不转移：这一条失败就直接把错误交给客户端。
        case none
        /// 只在同一个供应商实例内换模型。
        case sameProvider
        /// 任何通过硬约束（含凭据就绪）的候选都可以接。
        case anyEligible

        /// 规格文本把最宽的一档写作 `anyReady`，实现里叫 `anyEligible`——
        /// 硬约束本身就包含凭据就绪，两者是同一档。这里只接受别名解码，
        /// 编码仍写 `anyEligible`，避免同一语义在磁盘上出现两种拼法。
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "none": self = .none
            case "sameProvider": self = .sameProvider
            case "anyEligible", "anyReady": self = .anyEligible
            default:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown fallback strategy \(raw)")
                )
            }
        }
    }

    var strategy: Strategy
    var maxAttempts: Int

    /// 转移次数封顶。放开会让一条请求在 23 家 provider 之间连环重试，
    /// 用户等到超时，账单上却是一串真实调用。
    static let maxAllowedAttempts = 5

    /// 默认：同供应商换模型，最多 3 次。跨供应商不做默认，因为换 provider
    /// 意味着换计费主体，那应当是用户明确选的。
    static let `default` = FallbackPolicy(strategy: .sameProvider, maxAttempts: 3)

    /// 归一化后的尝试次数。`.none` 强制为 0：策略说不转移，次数就不该还有值。
    var effectiveMaxAttempts: Int {
        guard strategy != .none else { return 0 }
        return min(max(maxAttempts, 0), Self.maxAllowedAttempts)
    }
}

/// One candidate that passed hard filtering, with its score.
struct RouteCandidateScore: Codable, Equatable, Sendable, Identifiable {
    var modelEntryID: String
    var providerInstanceID: String
    var dialect: APIDialect
    var score: Double
    var reasons: [String]
    /// Filtered out when non-nil (kept in the trace for explainability).
    var rejectedReason: String?

    var id: String { modelEntryID }
}

/// The full decision path for one request: filters, scores, selection,
/// retries and the failure chain (PRD "路由决策可解释").
struct RouteDecisionTrace: Codable, Equatable, Sendable, Identifiable {
    /// 请求实际发出后的结局（FR-RTE-05）。
    ///
    /// 路由决策与请求结果是**两个时刻**：trace 在选中候选那一刻就落盘（否则
    /// 请求崩了就什么都看不到），结局要等上游回来才知道。`.pending` 不是
    /// "未知"的占位，它是一条真实信息——代理在这条请求上挂住了。
    enum Outcome: String, Codable, Equatable, Sendable {
        case pending
        case succeeded
        case failed
        /// 解析阶段就没选出候选（未知模型 / 全被硬约束淘汰），请求从未发出。
        case notRouted
    }

    var id: String
    var at: Int64
    var requestID: String
    var selectionKind: ModelSelectionKind
    var requestedModel: String
    var resolvedModel: String?
    var constraints: RouteHardConstraints
    var candidates: [RouteCandidateScore]
    var selectedEntryID: String?
    var fallbackAttempts: [String]
    var failureChain: [String]
    var usageOrigin: CanonicalUsage.Origin
    /// 端到端耗时（毫秒）。请求还没回来时为 nil。
    var durationMS: Int?
    /// 上游 HTTP 状态码。非 HTTP 失败（超时、连不上）时为 nil。
    var httpStatus: Int?
    var outcome: Outcome

    /// 被选中的那条候选。UI 要 provider 名和方言，这些只在候选里有。
    ///
    /// 解码旧 jsonl 行时 `outcome` 缺省为 `.pending`，所以不能靠它判断
    /// "有没有选中"——用 `selectedEntryID`。
    var selectedCandidate: RouteCandidateScore? {
        guard let selectedEntryID else { return nil }
        return candidates.first { $0.modelEntryID == selectedEntryID && $0.rejectedReason == nil }
    }

    /// 是否发生了转移。`fallbackAttempts` 记的是"换了哪些候选再试"，
    /// 非空即转移过。
    var didFailover: Bool { !fallbackAttempts.isEmpty }

    init(
        id: String = UUID().uuidString,
        at: Int64 = Int64(Date().timeIntervalSince1970),
        requestID: String,
        selectionKind: ModelSelectionKind,
        requestedModel: String,
        resolvedModel: String? = nil,
        constraints: RouteHardConstraints,
        candidates: [RouteCandidateScore] = [],
        selectedEntryID: String? = nil,
        fallbackAttempts: [String] = [],
        failureChain: [String] = [],
        usageOrigin: CanonicalUsage.Origin = .vendor,
        durationMS: Int? = nil,
        httpStatus: Int? = nil,
        outcome: Outcome = .pending
    ) {
        self.id = id
        self.at = at
        self.requestID = requestID
        self.selectionKind = selectionKind
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.constraints = constraints
        self.candidates = candidates
        self.selectedEntryID = selectedEntryID
        self.fallbackAttempts = fallbackAttempts
        self.failureChain = failureChain
        self.usageOrigin = usageOrigin
        self.durationMS = durationMS
        self.httpStatus = httpStatus
        self.outcome = outcome
    }

    // 手写 `init(from:)`：老 jsonl 行没有这三个字段，用合成实现会让整行解码
    // 失败——升级一次版本，用户此前所有的路由记录会一次性消失。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Int64.self, forKey: .at)
        requestID = try container.decode(String.self, forKey: .requestID)
        selectionKind = try container.decode(ModelSelectionKind.self, forKey: .selectionKind)
        requestedModel = try container.decode(String.self, forKey: .requestedModel)
        resolvedModel = try container.decodeIfPresent(String.self, forKey: .resolvedModel)
        constraints = try container.decode(RouteHardConstraints.self, forKey: .constraints)
        candidates = try container.decodeIfPresent([RouteCandidateScore].self, forKey: .candidates) ?? []
        selectedEntryID = try container.decodeIfPresent(String.self, forKey: .selectedEntryID)
        fallbackAttempts = try container.decodeIfPresent([String].self, forKey: .fallbackAttempts) ?? []
        failureChain = try container.decodeIfPresent([String].self, forKey: .failureChain) ?? []
        usageOrigin = try container.decodeIfPresent(CanonicalUsage.Origin.self, forKey: .usageOrigin) ?? .vendor
        durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS)
        httpStatus = try container.decodeIfPresent(Int.self, forKey: .httpStatus)
        // 老记录没有结局字段。按 `selectedEntryID` 推断而不是一律 `.pending`：
        // 一条选中了候选的老记录标成"挂起中"会让用户以为代理卡住了。
        outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
            ?? (selectedEntryID == nil ? .notRouted : .pending)
    }
}

/// Routes a request against the v2 registry: hard-filter → score → select,
/// recording an explainable trace. Pure and testable; the runtime wires it to
/// the registry store.
struct RoutePlanner: Sendable {
    var weights: RouteWeights
    var fallback: FallbackPolicy

    init(weights: RouteWeights = .default, fallback: FallbackPolicy = .default) {
        self.weights = weights
        self.fallback = fallback
    }

    /// Filters and scores `entries`, returns the best eligible candidate plus
    /// the trace. `credentials` maps credential ID to its gate state (FR-RTE-03).
    func plan(
        requestID: String,
        requestedModel: String,
        selectionKind: ModelSelectionKind,
        entries: [ModelCatalogEntry],
        instances: [ProviderInstance],
        credentials: [String: CredentialGateState],
        constraints: RouteHardConstraints,
        metrics: [String: RouteRuntimeMetrics] = [:]
    ) -> (selected: RouteCandidateScore?, trace: RouteDecisionTrace) {
        var candidates: [RouteCandidateScore] = []
        var rejected: [RouteCandidateScore] = []

        for entry in entries {
            if let requestedEntryID = constraints.requestedEntryID,
               entry.id != requestedEntryID {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: entry.providerInstanceID, dialect: .chat, score: 0, reasons: [], rejectedReason: "explicit model mismatch"))
                continue
            }
            if !constraints.allowedProviderInstanceIDs.isEmpty,
               !constraints.allowedProviderInstanceIDs.contains(entry.providerInstanceID) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: entry.providerInstanceID, dialect: .chat, score: 0, reasons: [], rejectedReason: "provider not allowed"))
                continue
            }
            guard let instance = instances.first(where: { $0.id == entry.providerInstanceID }) else {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: entry.providerInstanceID, dialect: .chat, score: 0, reasons: [], rejectedReason: "instance not found"))
                continue
            }
            // Credential gate (FR-RTE-03): .notReady → hard exclude;
            // .throttled → participate with reduced weight.
            let credState = credentials[instance.credentialID] ?? .notReady
            if credState.isHardExcluded {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "credential not ready"))
                continue
            }
            // Instance must be enabled.
            guard instance.enabled else {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "instance disabled"))
                continue
            }
            // Target binding gate. A target with no provider allowlist is a
            // valid unrestricted target; a non-empty list is authoritative.
            if let bindingID = constraints.targetBindingID,
               !constraints.allowedProviderInstanceIDs.isEmpty,
               !constraints.allowedProviderInstanceIDs.contains(instance.id) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "not allowed for target \(bindingID)"))
                continue
            }
            let dialect = instance.defaultProtocol
            if !constraints.requiredDialects.isEmpty && !constraints.requiredDialects.contains(dialect) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "dialect mismatch"))
                continue
            }
            if let minContext = constraints.minContextWindow {
                guard let window = entry.capabilities.contextWindow, window >= minContext else {
                    rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "context too small"))
                    continue
                }
            }
            if let required = constraints.requiredReasoningEfforts {
                guard let supported = entry.capabilities.supportedReasoningEfforts,
                      required.contains(where: { supported.contains($0) }) else {
                    rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "reasoning effort unsupported"))
                    continue
                }
            }
            if let region = constraints.requiredRegion {
                guard entry.capabilities.region == region else {
                    rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "region mismatch"))
                    continue
                }
            }
            if let budget = constraints.remainingBudget,
               let cost = entry.capabilities.costIndex,
               cost > budget {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "budget exceeded"))
                continue
            }
            let unsupportedCapability = constraints.requiredCapabilities.first { capability in
                switch capability {
                case "vision": return entry.capabilities.supportsVision != true
                case "tools": return entry.capabilities.supportsTools != true
                case "parallel_tools": return entry.capabilities.supportsParallelTools != true
                case "audio": return entry.capabilities.supportsAudio != true
                case "realtime": return entry.capabilities.supportsRealtime != true
                case "computer_use": return entry.capabilities.supportsComputerUse != true
                case "structured_output": return entry.capabilities.supportsStructuredOutput != true
                default: return false
                }
            }
            if let unsupportedCapability {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "missing \(unsupportedCapability)"))
                continue
            }

            let runtime = metrics[entry.id] ?? .default
            guard runtime.healthScore > 0 else {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "unhealthy"))
                continue
            }
            // 被限流的凭据降权后仍然参与排序（FR-RTE-03）。
            let score = score(entry: entry, instance: instance, metrics: runtime)
                * credState.scoreMultiplier
            var reasons = scoreReasons(entry: entry, instance: instance, metrics: runtime)
            if credState == .throttled {
                reasons.append(String(format: "credential throttled (×%.2f)", credState.scoreMultiplier))
            }
            candidates.append(
                RouteCandidateScore(
                    modelEntryID: entry.id,
                    providerInstanceID: instance.id,
                    dialect: dialect,
                    score: score,
                    reasons: reasons
                )
            )
        }

        let sorted = candidates.sorted { $0.score > $1.score }
        let selected = sorted.first
        let trace = RouteDecisionTrace(
            requestID: requestID,
            selectionKind: selectionKind,
            requestedModel: requestedModel,
            resolvedModel: selected?.modelEntryID,
            constraints: constraints,
            candidates: candidates + rejected,
            selectedEntryID: selected?.modelEntryID,
            fallbackAttempts: [],
            failureChain: [],
            usageOrigin: .vendor,
            // 选出来了才谈得上"请求结果"。没选出来的这条 trace 到此为止，
            // 不会有第二次写入，结局当场就定了。
            outcome: selected == nil ? .notRouted : .pending
        )
        return (selected, trace)
    }

    /// 选中项失败后，按转移策略给出可以依次改投的候选（FR-RTE-04）。
    ///
    /// 只排序、不发请求：planner 是纯函数，它不知道也不该知道哪一次上游调用
    /// 失败了。运行时按这个顺序往下试，试过谁就把谁记进 trace 的
    /// `fallbackAttempts`——于是"为什么这条请求最后落在第三家"在路由 tab 里
    /// 是可读的。
    ///
    /// 传入的 `candidates` 可以直接是 trace 里那份（含被淘汰项），被硬约束
    /// 淘汰过的在这里会再滤一次：它们连第一轮都没通过，转移时同样不合格。
    func fallbackOrder(
        after selected: RouteCandidateScore?,
        from candidates: [RouteCandidateScore]
    ) -> [RouteCandidateScore] {
        guard let selected, fallback.strategy != .none else { return [] }
        let budget = fallback.effectiveMaxAttempts
        guard budget > 0 else { return [] }

        let pool = candidates.filter { candidate in
            guard candidate.rejectedReason == nil else { return false }
            guard candidate.modelEntryID != selected.modelEntryID else { return false }
            switch fallback.strategy {
            case .none:
                return false
            case .sameProvider:
                return candidate.providerInstanceID == selected.providerInstanceID
            case .anyEligible:
                return true
            }
        }
        // 同分时用 id 兜底排序：字典序本身没有意义，但它让同一份注册表在两次
        // 请求里给出同一个转移顺序。顺序抖动会让"重试第二次就好了"这类现象
        // 无法复现，诊断时最难受的就是这个。
        return pool
            .sorted { ($0.score, $0.modelEntryID) > ($1.score, $1.modelEntryID) }
            .prefix(budget)
            .map { $0 }
    }

    private func score(entry: ModelCatalogEntry, instance: ProviderInstance, metrics: RouteRuntimeMetrics) -> Double {
        var score: Double = 0
        if let window = entry.capabilities.contextWindow {
            score += weights.contextFit * min(1, Double(window) / 1_000_000)
        }
        if let efforts = entry.capabilities.supportedReasoningEfforts, !efforts.isEmpty {
            score += weights.reasoningFit * 0.8
        }
        if let source = entry.metadataSources["contextWindow"] {
            switch source {
            case .provider: score += weights.freshness * 1.0
            case .registry: score += weights.freshness * 0.5
            case .fallback: score += weights.freshness * 0.1
            }
        }
        score += weights.health * min(max(metrics.healthScore, 0), 1)
        if let quota = metrics.quotaRemaining {
            score += weights.quota * min(max(quota, 0), 1)
        }
        if let latency = metrics.latencyMilliseconds {
            score += weights.latency * max(0, 1 - min(latency / 2_000, 1))
        }
        let cost = metrics.costIndex ?? entry.capabilities.costIndex
        if let cost {
            score += weights.costIndex * max(0, 1 - min(cost, 1))
        }
        score += weights.priority * metrics.userPriority
        score += weights.affinity * metrics.sessionAffinity
        return score
    }

    private func scoreReasons(entry: ModelCatalogEntry, instance: ProviderInstance, metrics: RouteRuntimeMetrics) -> [String] {
        var reasons: [String] = []
        if let window = entry.capabilities.contextWindow {
            reasons.append("context \(window)")
        }
        if let source = entry.metadataSources["contextWindow"] {
            reasons.append("source \(source.rawValue)")
        }
        reasons.append("provider \(instance.displayName)")
        reasons.append(String(format: "health %.2f", metrics.healthScore))
        if let quota = metrics.quotaRemaining { reasons.append(String(format: "quota %.2f", quota)) }
        if let latency = metrics.latencyMilliseconds { reasons.append(String(format: "latency %.0fms", latency)) }
        if let cost = metrics.costIndex ?? entry.capabilities.costIndex { reasons.append(String(format: "cost %.2f", cost)) }
        if metrics.userPriority != 0 { reasons.append(String(format: "priority %.2f", metrics.userPriority)) }
        if metrics.sessionAffinity != 0 { reasons.append(String(format: "affinity %.2f", metrics.sessionAffinity)) }
        return reasons
    }
}
