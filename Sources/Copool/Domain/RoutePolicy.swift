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
}

/// Scoring weights for auto routing.
struct RouteWeights: Codable, Equatable, Sendable {
    var contextFit: Double
    var reasoningFit: Double
    var freshness: Double
    var costIndex: Double

    static let `default` = RouteWeights(contextFit: 1.0, reasoningFit: 0.8, freshness: 0.3, costIndex: 0.5)
}

/// Failover policy.
struct FallbackPolicy: Codable, Equatable, Sendable {
    enum Strategy: String, Codable, Equatable, Sendable {
        case none
        case sameProvider
        case anyEligible
    }

    var strategy: Strategy
    var maxAttempts: Int
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
        usageOrigin: CanonicalUsage.Origin = .vendor
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
    }
}

/// Routes a request against the v2 registry: hard-filter → score → select,
/// recording an explainable trace. Pure and testable; the runtime wires it to
/// the registry store.
struct RoutePlanner: Sendable {
    var weights: RouteWeights
    var fallback: FallbackPolicy

    init(weights: RouteWeights = .default, fallback: FallbackPolicy = FallbackPolicy(strategy: .anyEligible, maxAttempts: 3)) {
        self.weights = weights
        self.fallback = fallback
    }

    /// Filters and scores `entries`, returns the best eligible candidate plus
    /// the trace. `credentialAvailable` gates catalog availability (AC-011:
    /// a credential-less instance never enters the default catalog).
    func plan(
        requestID: String,
        requestedModel: String,
        selectionKind: ModelSelectionKind,
        entries: [ModelCatalogEntry],
        instances: [ProviderInstance],
        credentials: [String: Bool],
        constraints: RouteHardConstraints
    ) -> (selected: RouteCandidateScore?, trace: RouteDecisionTrace) {
        var candidates: [RouteCandidateScore] = []
        var rejected: [RouteCandidateScore] = []

        for entry in entries {
            guard let instance = instances.first(where: { $0.id == entry.providerInstanceID }) else {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: entry.providerInstanceID, dialect: .chat, score: 0, reasons: [], rejectedReason: "instance not found"))
                continue
            }
            // Credential gate (AC-011): missing credential → not routable.
            if credentials[instance.credentialID] != true {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "credential missing"))
                continue
            }
            // Instance must be enabled.
            guard instance.enabled else {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "instance disabled"))
                continue
            }
            // Target binding gate.
            if let bindingID = constraints.targetBindingID,
               !constraints.allowedProviderInstanceIDs.isEmpty,
               !constraints.allowedProviderInstanceIDs.contains(instance.id) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: instance.defaultProtocol, score: 0, reasons: [], rejectedReason: "not allowed for target \(bindingID)"))
                continue
            }
            // Dialect gate.
            let dialect = instance.defaultProtocol
            if !constraints.requiredDialects.isEmpty && !constraints.requiredDialects.contains(dialect) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "dialect mismatch"))
                continue
            }
            // Context gate.
            if let minContext = constraints.minContextWindow,
               let window = entry.capabilities.contextWindow,
               window < minContext {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "context too small"))
                continue
            }
            // Reasoning gate.
            if let required = constraints.requiredReasoningEfforts,
               let supported = entry.capabilities.supportedReasoningEfforts,
               !required.contains(where: { supported.contains($0) }) {
                rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "reasoning effort unsupported"))
                continue
            }
            // Capability gate.
            if !constraints.requiredCapabilities.isEmpty {
                let hasVision = entry.capabilities.supportsVision == true
                if constraints.requiredCapabilities.contains("vision") && !hasVision {
                    rejected.append(RouteCandidateScore(modelEntryID: entry.id, providerInstanceID: instance.id, dialect: dialect, score: 0, reasons: [], rejectedReason: "no vision"))
                    continue
                }
            }

            let score = score(entry: entry, instance: instance)
            candidates.append(
                RouteCandidateScore(
                    modelEntryID: entry.id,
                    providerInstanceID: instance.id,
                    dialect: dialect,
                    score: score,
                    reasons: scoreReasons(entry: entry, instance: instance)
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
            usageOrigin: .vendor
        )
        return (selected, trace)
    }

    private func score(entry: ModelCatalogEntry, instance: ProviderInstance) -> Double {
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
        return score
    }

    private func scoreReasons(entry: ModelCatalogEntry, instance: ProviderInstance) -> [String] {
        var reasons: [String] = []
        if let window = entry.capabilities.contextWindow {
            reasons.append("context \(window)")
        }
        if let source = entry.metadataSources["contextWindow"] {
            reasons.append("source \(source.rawValue)")
        }
        reasons.append("provider \(instance.displayName)")
        return reasons
    }
}
