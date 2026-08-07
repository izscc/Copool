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
            credentials: ["cred-1": .ready, "cred-missing": .notReady],
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
            credentials: ["cred-1": .ready, "cred-missing": .notReady],
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
            credentials: ["cred-1": .ready, "cred-missing": .notReady],
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
            credentials: ["cred-1": .ready, "cred-missing": .notReady],
            constraints: RouteHardConstraints(allowedProviderInstanceIDs: [], requiredDialects: [], minContextWindow: nil, requiredReasoningEfforts: nil, requiredCapabilities: ["vision"], targetBindingID: nil)
        )
        XCTAssertEqual(trace.selectedEntryID, "inst-1/grok-4.5")
        XCTAssertTrue(trace.candidates.contains { $0.modelEntryID == "inst-1/grok-4-mini" && $0.rejectedReason == "missing vision" })
    }

    func testPlannerFiltersExpandedCapabilitiesAndRegion() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (_, trace) = planner.plan(
            requestID: "req-capabilities",
            requestedModel: "grok-4.5",
            selectionKind: .auto,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": .ready],
            constraints: RouteHardConstraints(
                requiredCapabilities: ["tools", "vision"],
                requiredRegion: "us"
            )
        )
        XCTAssertNil(trace.selectedEntryID)
        XCTAssertTrue(trace.candidates.contains { $0.rejectedReason == "missing tools" })
    }

    func testPlannerUsesRuntimeMetricsInScoreAndTrace() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let metrics = [
            "inst-1/grok-4.5": RouteRuntimeMetrics(
                healthScore: 0.5,
                quotaRemaining: 0.25,
                latencyMilliseconds: 1_500,
                costIndex: 0.2,
                userPriority: 0.7,
                sessionAffinity: 0.9
            )
        ]
        let (selected, trace) = planner.plan(
            requestID: "req-metrics",
            requestedModel: "grok-4.5",
            selectionKind: .auto,
            entries: [registry.catalog[0]],
            instances: registry.instances,
            credentials: ["cred-1": .ready],
            constraints: RouteHardConstraints(),
            metrics: metrics
        )
        XCTAssertEqual(selected?.modelEntryID, "inst-1/grok-4.5")
        XCTAssertTrue(selected?.reasons.contains { $0.contains("health") } == true)
        XCTAssertTrue(trace.candidates.first?.reasons.contains { $0.contains("affinity") } == true)
    }

    func testPlannerHonorsExplicitEntryID() {
        let registry = makeRegistry()
        let planner = RoutePlanner()
        let (_, trace) = planner.plan(
            requestID: "req-explicit",
            requestedModel: "grok-4.5",
            selectionKind: .explicit,
            entries: registry.catalog,
            instances: registry.instances,
            credentials: ["cred-1": .ready],
            constraints: RouteHardConstraints(requestedEntryID: "inst-1/grok-4-mini")
        )
        XCTAssertEqual(trace.selectedEntryID, "inst-1/grok-4-mini")
        XCTAssertTrue(trace.candidates.contains { $0.rejectedReason == "explicit model mismatch" })
    }

    func testReplaySafetyRejectsToolRequestsWithoutIdempotency() {
        XCTAssertFalse(SwiftNativeProxyRuntimeService.thirdPartyReplayIsSafe(object: ["tools": [["type": "function"]]], headers: [:]))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.thirdPartyReplayIsSafe(object: ["tools": [["type": "function"]], "idempotency_key": "req-1"], headers: [:]))
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

    // MARK: - 失败转移顺序（FR-RTE-04）

    private func candidate(
        _ id: String,
        provider: String,
        score: Double,
        rejected: String? = nil
    ) -> RouteCandidateScore {
        RouteCandidateScore(
            modelEntryID: id,
            providerInstanceID: provider,
            dialect: .chat,
            score: score,
            reasons: [],
            rejectedReason: rejected
        )
    }

    /// `.sameProvider` 只在同一实例内改投，且被硬约束淘汰过的候选不参与——
    /// 它们连第一轮都没通过，转移时同样不合格。
    func testFallbackOrderSameProviderSkipsRejectedAndOtherProviders() {
        let planner = RoutePlanner(fallback: FallbackPolicy(strategy: .sameProvider, maxAttempts: 3))
        let selected = candidate("inst-1/a", provider: "inst-1", score: 0.9)
        let pool = [
            selected,
            candidate("inst-1/b", provider: "inst-1", score: 0.8),
            candidate("inst-2/c", provider: "inst-2", score: 0.85),
            candidate("inst-1/d", provider: "inst-1", score: 0.7, rejected: "no credential"),
        ]
        let order = planner.fallbackOrder(after: selected, from: pool).map(\.modelEntryID)
        XCTAssertEqual(order, ["inst-1/b"])
    }

    /// `.anyEligible` 放开供应商限制，但仍按分数降序，且不含选中项本身。
    func testFallbackOrderAnyEligibleRanksByScoreAndExcludesSelected() {
        let planner = RoutePlanner(fallback: FallbackPolicy(strategy: .anyEligible, maxAttempts: 5))
        let selected = candidate("inst-1/a", provider: "inst-1", score: 0.9)
        let pool = [
            selected,
            candidate("inst-1/b", provider: "inst-1", score: 0.5),
            candidate("inst-2/c", provider: "inst-2", score: 0.85),
        ]
        let order = planner.fallbackOrder(after: selected, from: pool).map(\.modelEntryID)
        XCTAssertEqual(order, ["inst-2/c", "inst-1/b"])
        XCTAssertFalse(order.contains("inst-1/a"))
    }

    /// `.none` 表示不转移，次数配置得再大也不产生任何备选。
    func testFallbackOrderNoneYieldsNothing() {
        let planner = RoutePlanner(fallback: FallbackPolicy(strategy: .none, maxAttempts: 10))
        let selected = candidate("inst-1/a", provider: "inst-1", score: 0.9)
        let pool = [selected, candidate("inst-1/b", provider: "inst-1", score: 0.8)]
        XCTAssertTrue(planner.fallbackOrder(after: selected, from: pool).isEmpty)
    }

    /// 次数封顶：配置超过 `maxAllowedAttempts` 时按上限截断，避免一条请求
    /// 在多家 provider 之间连环重试。
    func testFallbackOrderClampsToMaxAllowedAttempts() {
        let planner = RoutePlanner(fallback: FallbackPolicy(strategy: .anyEligible, maxAttempts: 99))
        let selected = candidate("inst-0/a", provider: "inst-0", score: 1.0)
        let pool = [selected] + (1...10).map {
            candidate("inst-\($0)/m", provider: "inst-\($0)", score: 0.5)
        }
        let order = planner.fallbackOrder(after: selected, from: pool)
        XCTAssertEqual(order.count, FallbackPolicy.maxAllowedAttempts)
    }

    /// 同分时按 id 兜底排序，保证同一份注册表在两次请求里给出同一个顺序——
    /// 顺序抖动会让"重试第二次就好了"这类现象无法复现。
    func testFallbackOrderIsStableForTiedScores() {
        let planner = RoutePlanner(fallback: FallbackPolicy(strategy: .anyEligible, maxAttempts: 3))
        let selected = candidate("inst-0/a", provider: "inst-0", score: 1.0)
        let tied = [
            candidate("inst-1/m", provider: "inst-1", score: 0.5),
            candidate("inst-2/m", provider: "inst-2", score: 0.5),
            candidate("inst-3/m", provider: "inst-3", score: 0.5),
        ]
        let forward = planner.fallbackOrder(after: selected, from: [selected] + tied).map(\.modelEntryID)
        let reversed = planner.fallbackOrder(after: selected, from: [selected] + tied.reversed()).map(\.modelEntryID)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, ["inst-3/m", "inst-2/m", "inst-1/m"])
    }

    /// `anyReady` 是规格文本里最宽一档的别名，解码时必须落到 `.anyEligible`，
    /// 否则老配置读进来会直接抛错。
    func testFallbackStrategyDecodesAnyReadyAlias() throws {
        let decoded = try JSONDecoder().decode(
            FallbackPolicy.self,
            from: Data(#"{"strategy":"anyReady","maxAttempts":2}"#.utf8)
        )
        XCTAssertEqual(decoded.strategy, .anyEligible)
        XCTAssertEqual(decoded.effectiveMaxAttempts, 2)
    }

    /// `.none` 的次数恒为 0：策略说不转移，次数就不该还有值。
    func testFallbackPolicyNoneHasZeroEffectiveAttempts() {
        XCTAssertEqual(FallbackPolicy(strategy: .none, maxAttempts: 5).effectiveMaxAttempts, 0)
    }
}
