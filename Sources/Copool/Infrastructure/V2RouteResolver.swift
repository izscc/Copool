import Foundation

/// Wires the pure `RoutePlanner` into production routing (AC-012).
///
/// When the v2 registry is present and version 2, every third-party model
/// request is resolved through: hard-filter → score → select, with the full
/// decision trace appended to `RouteDecisionLedger`. The selected provider
/// instance id (a stable v1-inherited UUID, AC-005) is what the caller uses
/// to find the concrete v1 `ProviderConfig` for the upstream request.
/// If the v2 registry is empty or stale, the resolver returns nil and the
/// caller falls back to the legacy v1 route matching (no behavior change).
struct V2RouteResolver: Sendable {
    let registryRepository: ProviderRegistryV2Repository
    let ledger: RouteDecisionLedger

    struct Resolution: Sendable, Equatable {
        let instance: ProviderInstance
        let entry: ModelCatalogEntry
        let trace: RouteDecisionTrace
    }

    /// Resolves a client model id through the v2 registry + RoutePlanner.
    /// `requestID` ties the trace to the HTTP request for auditability.
    func resolve(requestID: String, requestedModel: String, requiredCapabilities: Set<String> = []) -> Resolution? {
        let registry = registryRepository.loadRegistry()
        guard registry.version == ProviderRegistryV2.currentVersion,
              !registry.instances.isEmpty,
              !registry.catalog.isEmpty else {
            return nil
        }

        let planner = RoutePlanner(
            weights: .default,
            fallback: FallbackPolicy(strategy: .sameProvider, maxAttempts: 3)
        )

        // Credential gate: a credential reference existing in the registry
        // means the secret itself lives in the Keychain (AC-003); the planner
        // must never see a secret value.
        let credentials = Dictionary(
            uniqueKeysWithValues: registry.credentials.map { ($0.id, $0.secureReference != nil) }
        )

        // Candidate entries: catalog rows whose backend model matches the
        // client model id (plain id or namespaced suffix), else all entries
        // (the planner's dialect/context gates then decide).
        let normalized = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = registry.catalog.filter { entry in
            entry.backendModelID == normalized || entry.id.hasSuffix("/\(normalized)")
        }
        let entries = matching.isEmpty ? registry.catalog : matching

        let constraints = RouteHardConstraints(
            allowedProviderInstanceIDs: [],
            requiredDialects: [],
            minContextWindow: nil,
            requiredReasoningEfforts: nil,
            requiredCapabilities: requiredCapabilities,
            targetBindingID: nil
        )

        let (selected, trace) = planner.plan(
            requestID: requestID,
            requestedModel: requestedModel,
            selectionKind: .auto,
            entries: entries,
            instances: registry.instances,
            credentials: credentials,
            constraints: constraints
        )

        // Always record the trace — even a failed resolution is explainable.
        ledger.append(trace)

        guard let selected,
              let instance = registry.instances.first(where: { $0.id == selected.providerInstanceID }),
              let entry = registry.catalog.first(where: { $0.id == selected.modelEntryID }) else {
            return nil
        }
        return Resolution(instance: instance, entry: entry, trace: trace)
    }
}
