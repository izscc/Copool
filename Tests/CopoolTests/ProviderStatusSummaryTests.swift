import XCTest
@testable import Copool

/// B2-2：纯函数 `ProviderStatusSummary.build` 的单测。
///
/// 覆盖判据要求的三组：五种健康态混合、三种分流态、latestTrace 为 nil。
final class ProviderStatusSummaryTests: XCTestCase {

    /// 造一个最小凭据组——只填 health/throttled，其余给空值，
    /// 因为 build() 只看这两个字段。
    private func group(
        id: String,
        health: CredentialHealthState,
        throttled: Bool = false
    ) -> ProviderRegistryPresenter.GroupViewData {
        ProviderRegistryPresenter.GroupViewData(
            id: id,
            title: id,
            credentialID: id,
            health: health,
            throttled: throttled,
            failureReason: nil,
            lastVerifiedAt: nil,
            channels: [],
            credentialKinds: [],
            credentialPrompt: nil,
            environmentVariableCandidates: [],
            externalSession: nil
        )
    }

    func test_mixedHealthStatesCountByState() {
        let groups = [
            group(id: "a", health: .ready),
            group(id: "b", health: .ready),
            group(id: "c", health: .unconfigured),
            group(id: "d", health: .expired),
            group(id: "e", health: .unauthorized),
            group(id: "f", health: .verifying),
            // 限流与上面正交：这条 ready 且被限流。
            group(id: "g", health: .ready, throttled: true)
        ]

        let summary = ProviderStatusSummary.build(
            splitState: .active,
            groups: groups,
            latestTrace: nil
        )

        XCTAssertEqual(summary.readyCount, 3)          // a, b, g
        XCTAssertEqual(summary.unconfiguredCount, 1)   // c
        XCTAssertEqual(summary.expiredCount, 1)        // d
        XCTAssertEqual(summary.unauthorizedCount, 1)   // e
        XCTAssertEqual(summary.verifyingCount, 1)     // f
        XCTAssertEqual(summary.throttledCount, 1)      // g
        XCTAssertEqual(summary.needsAttentionCount, 3) // c + d + e
        XCTAssertEqual(summary.splitState, .active)
        XCTAssertNil(summary.lastRouteOutcome)
    }

    func test_threeSplitStatesPropagateUnchanged() {
        let groups = [group(id: "a", health: .ready)]
        for state in [ProviderSplitState.active, .degraded, .inconsistent] {
            let summary = ProviderStatusSummary.build(
                splitState: state,
                groups: groups,
                latestTrace: nil
            )
            XCTAssertEqual(summary.splitState, state)
        }
    }

    func test_emptyGroupsYieldZeroCounts() {
        let summary = ProviderStatusSummary.build(
            splitState: .degraded,
            groups: [],
            latestTrace: nil
        )
        XCTAssertEqual(summary.readyCount, 0)
        XCTAssertEqual(summary.needsAttentionCount, 0)
        XCTAssertEqual(summary.throttledCount, 0)
        XCTAssertEqual(summary.verifyingCount, 0)
        XCTAssertNil(summary.lastRouteOutcome)
    }

    func test_latestTraceNilAndPresent() {
        let groups = [group(id: "a", health: .ready)]

        // nil → outcome nil
        XCTAssertNil(ProviderStatusSummary.build(
            splitState: .active, groups: groups, latestTrace: nil
        ).lastRouteOutcome)

        // 有 trace → 取 trace.outcome（其余字段走默认值，build() 只看 outcome）
        let trace = RouteDecisionTrace(
            requestID: "r1",
            selectionKind: .auto,
            requestedModel: "m",
            constraints: RouteHardConstraints(),
            outcome: .failed
        )
        let summary = ProviderStatusSummary.build(
            splitState: .active, groups: groups, latestTrace: trace
        )
        XCTAssertEqual(summary.lastRouteOutcome, .failed)
    }
}
