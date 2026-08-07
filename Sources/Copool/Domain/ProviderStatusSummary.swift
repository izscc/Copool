import Foundation

/// Models 页顶部摘要条的数据投影（B2）。
///
/// 把用户最关心的两个问题压成一行可读结论：「现在能不能用」「为什么不能用」。
/// 规则是纯函数、无 IO——这样不必拉起整个视图就能单测：视图只负责把这份投影
/// 摆出来，规则变更不必改 UI。
///
/// 文案键全部复用既有 `proxy.split.state.*` 与 `credentials.health.*`，不新增。
struct ProviderStatusSummary: Equatable, Sendable {
    var splitState: ProviderSplitState
    var readyCount: Int
    /// unconfigured + expired + unauthorized：需要用户动手才能恢复的凭据。
    var needsAttentionCount: Int
    var throttledCount: Int
    var verifyingCount: Int
    var lastRouteOutcome: RouteDecisionTrace.Outcome?

    /// 逐态明细。`needsAttentionCount` 是聚合数，但视图要按
    /// `CredentialStatusBadge` 精确呈现「每一类」——把三态拆开，徽标才不会
    /// 把「未配置」误标成「未授权」。这三项是同一维度的展开，不是新指标。
    var unconfiguredCount: Int
    var expiredCount: Int
    var unauthorizedCount: Int

    /// 三项输入都已存在，不新建采集逻辑。`groups` 按 `GroupViewData.health`
    /// 聚合；一组共用凭据计一次，不按组内通道重复数。
    static func build(
        splitState: ProviderSplitState,
        groups: [ProviderRegistryPresenter.GroupViewData],
        latestTrace: RouteDecisionTrace?
    ) -> ProviderStatusSummary {
        var ready = 0
        var unconfigured = 0
        var expired = 0
        var unauthorized = 0
        var throttled = 0
        var verifying = 0
        for group in groups {
            switch group.health {
            case .ready: ready += 1
            case .unconfigured: unconfigured += 1
            case .expired: expired += 1
            case .unauthorized: unauthorized += 1
            case .verifying: verifying += 1
            }
            // 限流是正交维度：被限流的凭据仍可用，单列一栏，不并入「需关注」。
            if group.throttled { throttled += 1 }
        }
        return ProviderStatusSummary(
            splitState: splitState,
            readyCount: ready,
            needsAttentionCount: unconfigured + expired + unauthorized,
            throttledCount: throttled,
            verifyingCount: verifying,
            lastRouteOutcome: latestTrace?.outcome,
            unconfiguredCount: unconfigured,
            expiredCount: expired,
            unauthorizedCount: unauthorized
        )
    }
}
