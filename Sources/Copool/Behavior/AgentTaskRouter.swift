import Foundation

/// One model the router may target, projected from the Codex catalog.
struct AgentCatalogModel: Equatable, Sendable {
    var slug: String
    var backendModel: String
    var provider: String
    var displayName: String?
    var supportedReasoningEfforts: [String]
    var defaultReasoningEffort: String?

    init(
        slug: String,
        backendModel: String,
        provider: String,
        displayName: String? = nil,
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.slug = slug
        self.backendModel = backendModel
        self.provider = provider
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// What the proxy knows about a subagent turn when it asks for a route.
struct AgentRouteRequest: Equatable, Sendable {
    var taskID: String?
    /// Prompt text, used only for overlap against user-authored labels.
    var taskText: String?
    var taskType: String?
    var tags: [String]
    /// Set when the parent turn named a profile outright.
    var profileID: String?
    /// Set when the parent turn named a model outright.
    var forcedModel: String?
    var reasoningEffort: String?
    /// Honour an explicitly requested effort even if the catalog does not
    /// list it — the provider stays the authority on what it accepts.
    var preserveReasoningEffort: Bool
    var requiredTools: [String]

    init(
        taskID: String? = nil,
        taskText: String? = nil,
        taskType: String? = nil,
        tags: [String] = [],
        profileID: String? = nil,
        forcedModel: String? = nil,
        reasoningEffort: String? = nil,
        preserveReasoningEffort: Bool = false,
        requiredTools: [String] = []
    ) {
        self.taskID = taskID
        self.taskText = taskText
        self.taskType = taskType
        self.tags = tags
        self.profileID = profileID
        self.forcedModel = forcedModel
        self.reasoningEffort = reasoningEffort
        self.preserveReasoningEffort = preserveReasoningEffort
        self.requiredTools = requiredTools
    }
}

struct AgentRoute: Equatable, Sendable {
    var model: String
    var backendModel: String
    var provider: String
    var reasoningEffort: String?
    var profileID: String?
    var profileName: String?
    var reason: String
}

enum AgentRouteOutcome: Equatable, Sendable {
    case routed(AgentRoute)
    /// Routing deliberately declined; the child keeps the parent's model.
    case passthrough(reason: String)
}

/// Scores saved profiles against a subagent task and picks a model.
///
/// Deliberately has no built-in keyword table: a profile only matches on
/// labels the user wrote themselves. Inferring capability from a provider or
/// model name would silently route work to models the user never chose for it.
struct AgentTaskRouter: Sendable {
    var profiles: [AgentProfile]
    var settings: AgentRoutingSettings
    var catalog: [AgentCatalogModel]

    init(profiles: [AgentProfile], settings: AgentRoutingSettings, catalog: [AgentCatalogModel]) {
        self.profiles = profiles
        self.settings = settings
        self.catalog = catalog
    }

    func resolve(_ request: AgentRouteRequest) -> AgentRouteOutcome {
        // An explicit binding from the parent turn outranks every setting,
        // including `off` — the user asked for this child by name.
        if let forced = Self.trimmed(request.forcedModel) {
            return resolveModel(forced, profile: nil, request: request, reason: "explicit model")
        }
        if let profileID = Self.trimmed(request.profileID) {
            guard let profile = profiles.first(where: { $0.id == profileID }) else {
                return .passthrough(reason: "profile \(profileID) is not configured")
            }
            guard profile.enabled else {
                return .passthrough(reason: "profile \(profile.name) is disabled")
            }
            guard profile.subagentEnabled else {
                return .passthrough(reason: "profile \(profile.name) is not enabled for subagents")
            }
            return resolveProfile(profile, request: request, reason: "explicit profile")
        }

        switch settings.mode {
        case .off:
            return .passthrough(reason: "agent routing is off")
        case .forced:
            if let model = Self.trimmed(settings.forcedModel) {
                return resolveModel(model, profile: nil, request: request, reason: "forced model")
            }
            if let profileID = Self.trimmed(settings.forcedProfileID),
               let profile = profiles.first(where: { $0.id == profileID }), profile.enabled, profile.subagentEnabled {
                return resolveProfile(profile, request: request, reason: "forced profile")
            }
            return .passthrough(reason: "forced routing has no usable target")
        case .auto:
            return resolveAuto(request)
        }
    }

    // MARK: - Auto matching

    private struct ScoredProfile {
        var profile: AgentProfile
        var match: MatchResult
    }

    private func resolveAuto(_ request: AgentRouteRequest) -> AgentRouteOutcome {
        let eligible = profiles.filter { $0.enabled && $0.subagentEnabled }
        var scored: [ScoredProfile] = []
        for profile in eligible {
            let match = Self.score(profile: profile, request: request)
            if match.score > Self.disqualified {
                scored.append(ScoredProfile(profile: profile, match: match))
            }
        }
        let candidates = scored.sorted { lhs, rhs in
            lhs.match.score == rhs.match.score
                ? lhs.profile.id < rhs.profile.id
                : lhs.match.score > rhs.match.score
        }

        guard !candidates.isEmpty else {
            return .passthrough(reason: "no profile is enabled for subagents")
        }

        let requestedType = Self.lower(request.taskType)
        // A "real" match means the profile earned points from something the
        // user labelled, not merely from its priority.
        let matched = candidates.first { $0.match.matchedUserLabels }

        if matched == nil, !requestedType.isEmpty, settings.strictMatching {
            return .passthrough(reason: "no profile matched task_type=\(requestedType)")
        }

        let fallback = settings.defaultProfileID.flatMap { defaultID in
            candidates.first { $0.profile.id == defaultID }
        } ?? candidates[0]
        let selected = matched ?? fallback
        return resolveProfile(selected.profile, request: request, reason: "auto: \(selected.match.reason)")
    }

    static let disqualified = -100_000

    struct MatchResult: Equatable {
        var score: Int
        var reason: String
        /// True when at least one user-authored label contributed.
        var matchedUserLabels: Bool
    }

    static func score(profile: AgentProfile, request: AgentRouteRequest) -> MatchResult {
        var score = profile.priority
        var reasons: [String] = []
        var matchedUserLabels = false

        let profileTypes = Set(profile.taskTypes.map(lower))
        let profileTags = Set(profile.tags.map(lower))

        let requestedType = lower(request.taskType)
        if !requestedType.isEmpty {
            if profileTypes.contains(requestedType) {
                score += 100
                reasons.append("task_type=\(requestedType)")
                matchedUserLabels = true
            } else if profileTags.contains(requestedType) {
                score += 65
                reasons.append("tag=\(requestedType)")
                matchedUserLabels = true
            }
        }

        for tag in Set(request.tags.map(lower)) where !tag.isEmpty {
            if profileTypes.contains(tag) || profileTags.contains(tag) {
                score += 20
                reasons.append("tag=\(tag)")
                matchedUserLabels = true
            }
        }

        // A profile that cannot service a required tool is not a candidate at
        // any priority.
        let requiredTools = Set(request.requiredTools.map(lower)).filter { !$0.isEmpty }
        if !requiredTools.isEmpty {
            let available = Set(profile.tools.map(lower))
            let missing = requiredTools.subtracting(available)
            if !missing.isEmpty {
                return MatchResult(
                    score: disqualified,
                    reason: "missing tools: \(missing.sorted().joined(separator: ","))",
                    matchedUserLabels: false
                )
            }
            score += requiredTools.count * 12
            reasons.append("required_tools")
        }

        // Codex's subagent bridge often supplies only prose, no task_type.
        // Overlap it against the labels the user wrote on this profile.
        let taskTokens = Set(tokens(request.taskText))
        if !taskTokens.isEmpty {
            let labelSource = ([profile.name, profile.summary] + profile.taskTypes + profile.tags)
                .joined(separator: " ")
            let hits = Set(tokens(labelSource)).intersection(taskTokens)
            if !hits.isEmpty {
                score += min(60, hits.count * 10)
                reasons.append("labels=\(hits.sorted().prefix(6).joined(separator: "|"))")
                matchedUserLabels = true
            }
        }

        return MatchResult(
            score: score,
            reason: reasons.isEmpty ? "priority" : reasons.joined(separator: ","),
            matchedUserLabels: matchedUserLabels
        )
    }

    /// Splits text into comparable tokens.
    ///
    /// CJK has no word breaks, so runs are also emitted as bigrams —
    /// otherwise "写单元测试" could never overlap a "单元测试" label.
    static func tokens(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let lowered = value.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        var result: Set<String> = []
        for part in parts {
            let text = String(part)
            if text.unicodeScalars.allSatisfy({ Self.isCJK($0) }) {
                if text.count >= 2 { result.insert(text) }
                let characters = Array(text)
                if characters.count >= 2 {
                    for index in 0..<(characters.count - 1) {
                        result.insert(String(characters[index...(index + 1)]))
                    }
                }
            } else if text.count >= 2 {
                result.insert(text)
            }
        }
        return Array(result.prefix(200))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(Int(scalar.value))
            || (0xF900...0xFAFF).contains(Int(scalar.value))
    }

    // MARK: - Resolution

    private func resolveProfile(_ profile: AgentProfile, request: AgentRouteRequest, reason: String) -> AgentRouteOutcome {
        let direct = resolveProfileDirect(profile, request: request, reason: reason)
        if case .routed = direct { return direct }

        // Walk the user's declared fallback chain before giving up. Guard
        // against a cycle so a profile pointing back at itself cannot spin.
        var visited: Set<String> = [profile.id]
        for fallbackID in profile.fallbackProfileIDs {
            guard !visited.contains(fallbackID) else { continue }
            visited.insert(fallbackID)
            guard let fallback = profiles.first(where: { $0.id == fallbackID }),
                  fallback.enabled, fallback.subagentEnabled else { continue }
            let outcome = resolveProfileDirect(
                fallback,
                request: request,
                reason: "\(reason); fallback=\(fallback.name)"
            )
            if case .routed = outcome { return outcome }
        }
        return direct
    }

    private func resolveProfileDirect(_ profile: AgentProfile, request: AgentRouteRequest, reason: String) -> AgentRouteOutcome {
        guard let modelRef = profile.modelRef, !modelRef.backendModel.isEmpty else {
            return .passthrough(reason: "profile \(profile.name) has no model")
        }
        return resolveModel(
            modelRef.catalogSlug ?? modelRef.backendModel,
            profile: profile,
            request: request,
            reason: reason,
            modelRef: modelRef
        )
    }

    private func resolveModel(
        _ value: String,
        profile: AgentProfile?,
        request: AgentRouteRequest,
        reason: String,
        modelRef: AgentModelRef? = nil
    ) -> AgentRouteOutcome {
        let wanted = Self.lower(value)
        let expectedProvider = Self.lower(modelRef?.provider)
        let expectedBackend = Self.lower(modelRef?.backendModel)

        let model = catalog.first { entry in
            if !expectedProvider.isEmpty, Self.lower(entry.provider) != expectedProvider { return false }
            if let slug = modelRef?.catalogSlug, Self.lower(entry.slug) == Self.lower(slug) { return true }
            if !expectedBackend.isEmpty, Self.lower(entry.backendModel) == expectedBackend { return true }
            if modelRef == nil {
                return Self.lower(entry.slug) == wanted
                    || Self.lower(entry.backendModel) == wanted
                    || Self.lower(entry.displayName) == wanted
            }
            return false
        }

        guard let model else {
            return .passthrough(reason: "model \(value) is not in the local catalog")
        }

        // The per-turn value beats the profile default; the target model beats
        // both, because a parent turn's `max` may not exist downstream.
        let requested = Self.trimmed(request.reasoningEffort)
        let effort = Self.normalizeReasoning(
            for: model,
            requested: requested ?? profile?.reasoningEffort,
            preserveExplicit: request.preserveReasoningEffort && requested != nil
        )

        return .routed(AgentRoute(
            model: model.slug,
            backendModel: model.backendModel,
            provider: model.provider,
            reasoningEffort: effort,
            profileID: profile?.id,
            profileName: profile?.name,
            reason: reason
        ))
    }

    /// Maps a requested effort onto what the target model actually offers.
    static func normalizeReasoning(
        for model: AgentCatalogModel,
        requested: String?,
        preserveExplicit: Bool
    ) -> String? {
        let supported = model.supportedReasoningEfforts.map(lower).filter { !$0.isEmpty }
        // An empty list means the catalog says this model has no selectable
        // effort; sending one would be a guess.
        guard !supported.isEmpty else { return nil }

        if let requested = trimmed(requested) {
            let lowered = lower(requested)
            if supported.contains(lowered) { return lowered }
            if preserveExplicit { return lowered }
        }
        if let declared = trimmed(model.defaultReasoningEffort), supported.contains(lower(declared)) {
            return lower(declared)
        }
        if supported.contains("medium") { return "medium" }
        return supported.first
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func lower(_ value: String?) -> String {
        (trimmed(value) ?? "").lowercased()
    }
}
