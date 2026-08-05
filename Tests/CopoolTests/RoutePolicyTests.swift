import XCTest
@testable import Copool

/// Phase 5 acceptance: AC-011 (credential-aware catalog), AC-012 (hard
/// constraints → score → selection with trace), provenance priority.
final class RoutePolicyTests: XCTestCase {
    private func makeRegistry() -> ProviderRegistryV2 {
        let instance = ProviderInstance(
            id: "inst-1",
            definitionID: "grok",
            displayName: "Grok",
            endpoint: "https://api.x.ai/v1",
            credentialID: "cred-1",
            protocolBindings: ["grok-4.5": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 0
        )
        let instanceNoCredential = ProviderInstance(
            id: "inst-2",
            definitionID: "deepseek",
            displayName: "DeepSeek",
            endpoint: "https://api.deepseek.com/v1",
            credentialID: "cred-missing",
            protocolBindings: ["deepseek-chat": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 0
        )
        let credential = CredentialIdentity(
            id: "cred-1",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "inst-1|apiKey"),
            source: .userEntered,
            scopes: [],
            expiresAt: nil,
            lastVerifiedAt: nil
        )
        let entry = ModelCatalogEntry(
            providerInstanceID: "inst-1",
            backendModelID: "grok-4.5",
            displayName: "grok-4.5",
            capabilities: ModelCapabilitiesV2(contextWindow: 256_000, supportedReasoningEfforts: ["low", "high"], defaultReasoningEffort: "high", supportsVision: true),
            metadataSources: ["contextWindow": .provider],
            visibility: .visible
        )
        let smallEntry = ModelCatalogEntry(
            providerInstanceID: "inst-1",
            backendModelID: "grok-4-mini",
            displayName: nil,
            capabilities: ModelCapabilitiesV2(contextWindow: 8_000, supportedReasoningEfforts: nil, defaultReasoningEffort: nil, supportsVision: false),
            metadataSources: ["contextWindow": .fallback],
            visibility: .visible
        )
        return ProviderRegistryV2(
            definitions: [],
            instances: [instance, instanceNoCredential],
            credentials: [credential],
            catalog: [entry, smallEntry],
            userDefinitions: []
        )
    }

    // MARK: - AC-011 credential-aware catalog

    func testCatalogHidesCredentialLessInstances() {
        let registry = makeRegistry()
        let secrets = KeychainSecretStore()
        let result = CatalogBuilder().buildDefaultCatalog(registry: registry) { credentialID in
            credentialID == "cred-1" // inst-1 has it, inst-2 does not
        }
        XCTAssertEqual(result.rows.count, 2) // both entries of inst-1
        XCTAssertTrue(result.rows.allSatisfy { $0.instance.id == "inst-1" })
        XCTAssertEqual(result.hiddenCount, 0) // inst-2 has no catalog entries
    }

    func testCatalogHiddenCountForDisabledInstance() {
        var registry = makeRegistry()
        registry.instances[0].enabled = false
        let result = CatalogBuilder().buildDefaultCatalog(registry: registry) { _ in true }
        XCTAssertEqual(result.rows.count, 0)
        XCTAssertEqual(result.hiddenCount, 2)
    }

    // MARK: - AC-012 hard constraints

    func testPlannerFiltersByCredentialAndContext() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (selected, trace) = planner.plan(
            requestID: "req-1",
            requestedModel: "grok-4.5",
            selectionKind: .auto,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": true, "cred-missing": false],
            constraints: RouteHardConstraints(
                allowedProviderInstanceIDs: [],
                requiredDialects: [.chat],
                minContextWindow: 100_000,
                requiredReasoningEfforts: nil,
                requiredCapabilities: [],
                targetBindingID: nil
            )
        )
        XCTAssertEqual(selected?.modelEntryID, "inst-1/grok-4.5")
        XCTAssertEqual(trace.selectedEntryID, "inst-1/grok-4.5")
        // Small entry rejected by context gate, and its rejection is in the trace.
        XCTAssertTrue(trace.candidates.contains { $0.modelEntryID == "inst-1/grok-4-mini" && $0.rejectedReason != nil })
    }

    func testPlannerRejectsCredentialMissing() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (_, trace) = planner.plan(
            requestID: "req-2",
            requestedModel: "anything",
            selectionKind: .explicit,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": true, "cred-missing": false],
            constraints: RouteHardConstraints(allowedProviderInstanceIDs: ["inst-2"], requiredDialects: [], minContextWindow: nil, requiredReasoningEfforts: nil, requiredCapabilities: [], targetBindingID: nil)
        )
        XCTAssertNil(trace.selectedEntryID)
    }

    func testPlannerPicksHigherScore() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (selected, _) = planner.plan(
            requestID: "req-3",
            requestedModel: "grok-4.5",
            selectionKind: .explicit,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": true, "cred-missing": false],
            constraints: RouteHardConstraints(allowedProviderInstanceIDs: [], requiredDialects: [.chat], minContextWindow: nil, requiredReasoningEfforts: nil, requiredCapabilities: [], targetBindingID: nil)
        )
        XCTAssertEqual(selected?.modelEntryID, "inst-1/grok-4.5")
        XCTAssertTrue(selected!.score > 0)
    }

    func testVisionCapabilityGate() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (_, trace) = planner.plan(
            requestID: "req-4",
            requestedModel: "grok-4.5",
            selectionKind: .auto,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": true, "cred-missing": false],
            constraints: RouteHardConstraints(allowedProviderInstanceIDs: [], requiredDialects: [], minContextWindow: nil, requiredReasoningEfforts: nil, requiredCapabilities: ["vision"], targetBindingID: nil)
        )
        XCTAssertEqual(trace.selectedEntryID, "inst-1/grok-4.5")
        XCTAssertTrue(trace.candidates.contains { $0.modelEntryID == "inst-1/grok-4-mini" && $0.rejectedReason == "no vision" })
    }

    // MARK: - Provenance priority

    func testLiveDiscoveryUpgradesProvenance() {
        var registry = makeRegistry()
        let builder = CatalogBuilder()
        let liveCaps = ["grok-4-mini": ModelCapabilitiesV2(contextWindow: 1_000_000, supportedReasoningEfforts: ["high"], defaultReasoningEffort: "high", supportsVision: true)]
        registry = builder.mergeLiveDiscovery(registry: registry, instanceID: "inst-1", liveModelIDs: ["grok-4-mini", "grok-4-new"], liveCapabilities: liveCaps)

        let mini = registry.catalog.first { $0.backendModelID == "grok-4-mini" }
        XCTAssertEqual(mini?.capabilities.contextWindow, 1_000_000)
        XCTAssertEqual(mini?.metadataSources["contextWindow"], .provider)
        let newModel = registry.catalog.first { $0.backendModelID == "grok-4-new" }
        XCTAssertNotNil(newModel)
        XCTAssertEqual(newModel?.metadataSources["contextWindow"], .provider)
    }
}
