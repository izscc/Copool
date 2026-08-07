import SwiftUI

/// Models 页顶部常驻摘要条（B2）。
///
/// 一行回答用户最常问的两件事：「现在能不能用」「为什么不能用」。输入只有
/// `ProviderStatusSummary`——规则在 Domain 算好了，这里只摆盘。
///
/// 文案全部复用既有键（`proxy.split.state.*` / `credentials.health.*`），不新增。
/// 状态色不是唯一区分手段：结论文案本身就能独立表达状态，每个计数徽标也都有
/// `accessibilityLabel`（`CredentialStatusBadge` 已遵循此规则，这里照它的做法）。
struct ProviderStatusBar: View {
    let summary: ProviderStatusSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutRules.sectionSpacing) {
            conclusion
            Spacer(minLength: 12)
            counts
        }
        .padding(.horizontal, LayoutRules.pagePadding)
        .padding(.vertical, 8)
        .frostedCapsuleSurface()
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // 左侧一句结论：分流三态直接复用 proxy.split.state.*，不自造同义文案。
    private var conclusion: some View {
        HStack(spacing: 5) {
            Text(L10n.tr(conclusionKey))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(conclusionColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = summary.lastRouteOutcome {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(L10n.tr(Self.outcomeKey(outcome)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // 右侧计数：只显示非零项，每类一个 compact 徽标（已带 accessibilityLabel）。
    // 顺序按「需关注 → 限流 → 验证中 → 就绪」，把问题排在前面。
    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 8) {
            if summary.unconfiguredCount > 0 {
                countBadge(state: .unconfigured, count: summary.unconfiguredCount)
            }
            if summary.expiredCount > 0 {
                countBadge(state: .expired, count: summary.expiredCount)
            }
            if summary.unauthorizedCount > 0 {
                countBadge(state: .unauthorized, count: summary.unauthorizedCount)
            }
            if summary.verifyingCount > 0 {
                countBadge(state: .verifying, count: summary.verifyingCount)
            }
            if summary.throttledCount > 0 {
                throttledBadge(count: summary.throttledCount)
            }
            if summary.readyCount > 0 {
                countBadge(state: .ready, count: summary.readyCount)
            }
        }
    }

    private func countBadge(state: CredentialHealthState, count: Int) -> some View {
        HStack(spacing: 3) {
            CredentialStatusBadge(state: state, compact: true)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CredentialStatusBadge.tint(state))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.tr(CredentialStatusBadge.labelKey(state))) \(count)")
    }

    // 限流是正交维度：被限流的凭据仍可用，用 hourglass 单独表示，不套 .ready 徽标
    // 以免「绿勾」误导成一切正常。图标与 CredentialStatusBadge 内部用的同款。
    private func throttledBadge(count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.tr("credentials.health.throttled")) \(count)")
    }

    // MARK: - 文案 / 颜色

    private var conclusionKey: String {
        switch summary.splitState {
        case .active: return "proxy.split.state.active"
        case .degraded: return "proxy.split.state.degraded"
        case .inconsistent: return "proxy.split.state.inconsistent"
        }
    }

    private static func outcomeKey(_ outcome: RouteDecisionTrace.Outcome) -> String {
        switch outcome {
        case .succeeded: return "models.routes.outcome.succeeded"
        case .failed: return "models.routes.outcome.failed"
        case .notRouted: return "models.routes.outcome.not_routed"
        case .pending: return "models.routes.outcome.pending"
        }
    }

    private var conclusionColor: Color {
        switch summary.splitState {
        case .active: return .green
        case .degraded: return .orange
        case .inconsistent: return .red
        }
    }

    /// degraded 态必须让用户看懂「原生 GPT 不受影响」——`degraded_help` 已有此
    /// 文案，作为 help/tooltip 挂上，不自造同义说明。
    private var helpText: String {
        switch summary.splitState {
        case .active: return L10n.tr("proxy.split.state.active_help")
        case .degraded: return L10n.tr("proxy.split.state.degraded_help")
        case .inconsistent: return L10n.tr("proxy.split.state.inconsistent_help")
        }
    }

    /// 整条摘要的无障碍读法：先读结论，再读各非零计数。
    private var accessibilitySummary: String {
        var parts = [L10n.tr(conclusionKey)]
        if summary.unconfiguredCount > 0 {
            parts.append("\(summary.unconfiguredCount) \(L10n.tr("credentials.health.unconfigured"))")
        }
        if summary.expiredCount > 0 {
            parts.append("\(summary.expiredCount) \(L10n.tr("credentials.health.expired"))")
        }
        if summary.unauthorizedCount > 0 {
            parts.append("\(summary.unauthorizedCount) \(L10n.tr("credentials.health.unauthorized"))")
        }
        if summary.verifyingCount > 0 {
            parts.append("\(summary.verifyingCount) \(L10n.tr("credentials.health.verifying"))")
        }
        if summary.throttledCount > 0 {
            parts.append("\(summary.throttledCount) \(L10n.tr("credentials.health.throttled"))")
        }
        if summary.readyCount > 0 {
            parts.append("\(summary.readyCount) \(L10n.tr("credentials.health.ready"))")
        }
        if let outcome = summary.lastRouteOutcome {
            parts.append(L10n.tr(Self.outcomeKey(outcome)))
        }
        return parts.joined(separator: " · ")
    }
}
