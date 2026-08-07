import SwiftUI

/// 凭据健康状态徽标（CMP-02）。
///
/// 五态各有固定的图标 + 颜色 + 文案（IA-09 状态语言）。这三者绑定在一起，
/// 不允许调用方各自挑选——颜色语义一旦在页面之间漂移，用户就得重新学一遍
/// "橙色到底代表警告还是进行中"。
///
/// 限流（`throttled`）是**正交**维度而非第六态：被限流的凭据仍然可用，只是
/// 权重该降低。把它显示成故障会引导用户去重填一把好用的 Key。
struct CredentialStatusBadge: View {
    let state: CredentialHealthState
    var throttled = false
    /// 紧凑模式只显示图标，用于列表行尾这类横向空间紧张的位置。
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            icon
            if !compact {
                Text(L10n.tr(Self.labelKey(state)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Self.tint(state))
                    .lineLimit(1)
            }
            if throttled {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L10n.tr("credentials.health.throttled"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help(L10n.tr(Self.hintKey(state)))
    }

    /// 进行中用转轮而不是静态图标：静态图标无法表达"正在发生"，
    /// 用户会以为界面卡住了。
    @ViewBuilder
    private var icon: some View {
        if state == .verifying {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: Self.symbol(state))
                .font(.caption)
                .foregroundStyle(Self.tint(state))
        }
    }

    private var accessibilityText: String {
        let base = L10n.tr(Self.labelKey(state))
        guard throttled else { return base }
        return "\(base) · \(L10n.tr("credentials.health.throttled"))"
    }

    // MARK: - IA-09 状态语言

    static func symbol(_ state: CredentialHealthState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .expired: return "exclamationmark.circle.fill"
        case .unauthorized: return "xmark.circle.fill"
        case .unconfigured: return "circle.dotted"
        // 实际不会走到——verifying 用 ProgressView 呈现。保留是为了让
        // 这个函数在任何状态下都有定义，调用方不必先做状态判断。
        case .verifying: return "circle.dotted"
        }
    }

    static func tint(_ state: CredentialHealthState) -> Color {
        switch state {
        case .ready: return .green
        case .expired: return .orange
        case .unauthorized: return .red
        case .unconfigured, .verifying: return .secondary
        }
    }

    static func labelKey(_ state: CredentialHealthState) -> String {
        "credentials.health.\(state.rawValue)"
    }

    static func hintKey(_ state: CredentialHealthState) -> String {
        "credentials.health.\(state.rawValue).hint"
    }
}

/// 凭据状态 + 一句解释，用于卡片内的展开区域。
///
/// 徽标只答"是什么"，这里答"接下来做什么"。失败原因**已在写入注册表前
/// 脱敏**（INV-1），这里直接显示是安全的。
struct CredentialStatusDetail: View {
    let state: CredentialHealthState
    var throttled = false
    var failureReason: String?
    var lastVerifiedAt: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CredentialStatusBadge(state: state, throttled: throttled)

            Text(L10n.tr(CredentialStatusBadge.hintKey(state)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failureReason, !failureReason.isEmpty {
                Text(failureReason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastVerifiedAt, lastVerifiedAt > 0 {
                Text(L10n.tr("credentials.health.last_verified_format", Self.relativeTime(lastVerifiedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 相对时间比绝对时间戳更好读："3 分钟前"能直接回答"这个状态新不新"，
    /// 而 1755123456 需要用户自己换算。
    private static func relativeTime(_ epochSeconds: Int64) -> String {
        let elapsed = Int64(Date().timeIntervalSince1970) - epochSeconds
        if elapsed < 60 { return L10n.tr("common.time.just_now") }
        if elapsed < 3600 { return L10n.tr("common.time.minutes_ago_format", String(elapsed / 60)) }
        if elapsed < 86_400 { return L10n.tr("common.time.hours_ago_format", String(elapsed / 3600)) }
        return L10n.tr("common.time.days_ago_format", String(elapsed / 86_400))
    }
}
