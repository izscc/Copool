import Foundation

/// Marks a subagent turn the proxy has already routed, so every follow-up
/// turn of the same child keeps the same model.
struct AgentRouteBinding: Sendable {
    var route: AgentRoute
    var expiresAt: Int64
}

extension SwiftNativeProxyRuntimeService {
    /// How long a child stays pinned to its chosen model.
    static let agentRouteBindingTTLSeconds: Int64 = 30 * 60
    static let maxAgentRouteBindings = 200

    /// True when this Responses request is a Codex subagent turn.
    ///
    /// Codex fires a prewarm request for a child before the real turn, using
    /// the same markers. Routing it would burn a task record and, worse, pin
    /// the binding from a request that carries no task text to match on.
    static func isSubagentTurn(headers: [String: String], object: [String: Any]) -> Bool {
        if isPrewarmTurn(headers: headers, object: object) { return false }

        if normalizedForwardHeader(headers["x-openai-subagent"]) != nil { return true }
        if normalizedForwardHeader(headers["x-codex-parent-thread-id"]) != nil { return true }
        if normalizedForwardHeader(headers["x-codex-subagent-kind"]) != nil { return true }

        let metadata = object["client_metadata"] as? [String: Any] ?? [:]
        for source in [object, metadata] {
            if let threadSource = source["thread_source"] as? String,
               threadSource.caseInsensitiveCompare("subagent") == .orderedSame {
                return true
            }
            if let flag = source["x-openai-subagent"] {
                if let bool = flag as? Bool, bool { return true }
                if let text = flag as? String, text == "1" || text.lowercased() == "true" { return true }
            }
            if let parent = source["parent_thread_id"] as? String, !parent.isEmpty { return true }
        }
        if let nested = object["source"] as? [String: Any], nested["subagent"] as? Bool == true {
            return true
        }
        return false
    }

    /// Codex prewarms a child connection before dispatching real work.
    static func isPrewarmTurn(headers: [String: String], object: [String: Any]) -> Bool {
        if let kind = normalizedForwardHeader(headers["x-codex-turn-kind"]),
           kind.lowercased().contains("prewarm") {
            return true
        }
        let metadata = object["client_metadata"] as? [String: Any] ?? [:]
        for source in [object, metadata] {
            if let kind = source["turn_kind"] as? String, kind.lowercased().contains("prewarm") {
                return true
            }
        }
        // A prewarm carries no conversation to work on.
        if object["prewarm"] as? Bool == true { return true }
        return false
    }

    /// Pulls the parts of a subagent request the router scores against.
    static func agentRouteRequest(headers: [String: String], object: [String: Any]) -> AgentRouteRequest {
        let metadata = object["client_metadata"] as? [String: Any] ?? [:]

        func firstString(_ keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = metadata[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func firstList(_ keys: [String]) -> [String] {
            for key in keys {
                if let value = object[key] as? [String], !value.isEmpty { return value }
                if let value = metadata[key] as? [String], !value.isEmpty { return value }
            }
            return []
        }

        let taskID = firstString(["session_id", "thread_id", "conversation_id"])
            ?? normalizedForwardHeader(headers["session_id"])
            ?? normalizedForwardHeader(headers["x-codex-thread-id"])

        let requestedEffort = (object["reasoning"] as? [String: Any])?["effort"] as? String
            ?? object["reasoning_effort"] as? String
            ?? metadata["reasoning_effort"] as? String

        return AgentRouteRequest(
            taskID: taskID,
            taskText: extractSubagentTaskText(object),
            taskType: firstString(["task_type", "taskType"]),
            tags: firstList(["tags"]),
            profileID: firstString(["agent_profile_id", "profile_id", "subagent_profile_id"]),
            forcedModel: firstString(["forced_model", "subagent_model", "child_model", "agent_model"]),
            reasoningEffort: requestedEffort,
            preserveReasoningEffort: requestedEffort != nil,
            requiredTools: firstList(["required_tools"])
        )
    }

    /// Collects the child's instructions so user-authored profile labels have
    /// something to match against.
    static func extractSubagentTaskText(_ object: [String: Any]) -> String {
        var parts: [String] = []
        if let instructions = object["instructions"] as? String, !instructions.isEmpty {
            parts.append(instructions)
        }
        if let input = object["input"] as? String {
            parts.append(input)
        } else if let items = object["input"] as? [Any] {
            for item in items {
                guard let entry = item as? [String: Any] else { continue }
                // Only user-authored turns describe the task; assistant output
                // and tool traces would drown the signal.
                let role = (entry["role"] as? String)?.lowercased()
                guard role == nil || role == "user" || role == "developer" else { continue }
                if let text = entry["content"] as? String {
                    parts.append(text)
                    continue
                }
                for raw in entry["content"] as? [Any] ?? [] {
                    guard let part = raw as? [String: Any] else { continue }
                    if let text = part["text"] as? String, !text.isEmpty { parts.append(text) }
                }
            }
        }
        return parts.joined(separator: "\n").prefix(8000).description
    }

    // MARK: - Catalog

    /// Projects the routable third-party models for the router.
    ///
    /// Only configured providers are offered: routing a child to a native
    /// model the proxy would just forward gains nothing and risks pinning a
    /// child to the parent's own model.
    func agentCatalogModels() -> [AgentCatalogModel] {
        let providers = (try? providerRepository?.loadProviders())??.providers ?? []
        var models: [AgentCatalogModel] = []
        for provider in providers {
            for model in provider.models {
                models.append(AgentCatalogModel(
                    slug: model.id,
                    backendModel: model.id,
                    provider: provider.name,
                    displayName: model.id,
                    supportedReasoningEfforts: ["low", "medium", "high"],
                    defaultReasoningEffort: "medium"
                ))
            }
        }
        return models
    }

    // MARK: - Routing

    /// Chooses a model for a subagent turn, reusing an earlier decision when
    /// the same child comes back for another turn.
    func resolveAgentRoute(headers: [String: String], object: [String: Any]) -> AgentRoute? {
        guard let agentRepository else { return nil }
        guard Self.isSubagentTurn(headers: headers, object: object) else { return nil }

        let now = dateProvider.unixSecondsNow()
        agentRouteBindings = agentRouteBindings.filter { $0.value.expiresAt > now }

        let request = Self.agentRouteRequest(headers: headers, object: object)
        if let taskID = request.taskID,
           let binding = agentRouteBindings[taskID],
           request.forcedModel == nil {
            agentRouteBindings[taskID] = AgentRouteBinding(
                route: binding.route,
                expiresAt: now + Self.agentRouteBindingTTLSeconds
            )
            return binding.route
        }

        guard let store = try? agentRepository.loadAgents() else { return nil }
        let router = AgentTaskRouter(
            profiles: store.profiles,
            settings: store.settings,
            catalog: agentCatalogModels()
        )

        switch router.resolve(request) {
        case .passthrough(let reason):
            // `off` is the default state; logging it would fill the activity
            // list with noise before the user has configured anything.
            if store.settings.mode != .off || request.profileID != nil || request.forcedModel != nil {
                try? agentRepository.appendRouteEvent(AgentRouteEvent(
                    at: now,
                    taskID: request.taskID,
                    resolved: false,
                    reason: reason
                ))
            }
            return nil
        case .routed(let route):
            try? agentRepository.appendRouteEvent(AgentRouteEvent(
                at: now,
                taskID: request.taskID,
                profileID: route.profileID,
                profileName: route.profileName,
                model: route.model,
                reasoningEffort: route.reasoningEffort,
                resolved: true,
                reason: route.reason
            ))
            if let taskID = request.taskID {
                agentRouteBindings[taskID] = AgentRouteBinding(
                    route: route,
                    expiresAt: now + Self.agentRouteBindingTTLSeconds
                )
                while agentRouteBindings.count > Self.maxAgentRouteBindings {
                    guard let oldest = agentRouteBindings.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
                    agentRouteBindings.removeValue(forKey: oldest)
                }
            }
            return route
        }
    }

    /// Rewrites a subagent request onto the routed model.
    static func applyAgentRoute(_ route: AgentRoute, to object: [String: Any]) -> [String: Any] {
        var result = object
        result["model"] = route.model
        // The parent's effort may not exist on the child model; the router
        // already normalized it, so never let the inherited value through.
        result.removeValue(forKey: "reasoning")
        result.removeValue(forKey: "reasoning_effort")
        if let effort = route.reasoningEffort {
            result["reasoning"] = ["effort": effort]
            result["reasoning_effort"] = effort
        }
        // A worker has no dispatcher of its own, so keep its turn sequential.
        result["parallel_tool_calls"] = false
        return result
    }
}
