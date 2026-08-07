import SwiftUI

/// 共用凭据组的分区（CMP-01）。
///
/// opencode Go 一份订阅带三条协议通道：分开列会让用户以为要填三次 Key。
/// 归到一个分区、组头显示一次凭据状态，才对得上"一份订阅"的心智模型。
/// 不属于任何组的 provider 自成一个单通道分区，走同一套渲染。
struct ProviderGroupSection: View {
    let title: String
    /// 组内共用的凭据状态。单通道分区时就是该通道自己的状态。
    let health: CredentialHealthState
    var throttled = false
    var failureReason: String?
    var lastVerifiedAt: Int64?
    let channels: [ProviderChannelRow]
    /// 组内多于一条通道时为 true，组头要说明"这把凭据被 N 条通道共用"。
    var isSharedCredential = false
    let onConfigureCredential: () -> Void
    var onRevokeCredential: (() -> Void)?
    let onSelectChannel: (ProviderChannelRow) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(channels) { channel in
                        ProviderChannelCard(
                            row: channel,
                            // 组头已经说过一次凭据状态，逐行重复只会让
                            // 三行一模一样的绿勾抢走注意力。
                            showsHealth: !isSharedCredential,
                            onSelect: { onSelectChannel(channel) }
                        )
                    }
                }
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                CredentialStatusBadge(state: health, throttled: throttled)

                Spacer(minLength: 0)

                Button(action: onConfigureCredential) {
                    Label(
                        L10n.tr(health == .unconfigured
                                ? "credentials.action.configure"
                                : "credentials.action.replace"),
                        systemImage: "key"
                    )
                }
                .buttonStyle(.frostedCapsule(prominent: health == .unconfigured, tint: .indigo))
                .font(.caption2)

                if let onRevokeCredential, health != .unconfigured {
                    Button(role: .destructive, action: onRevokeCredential) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.frostedCapsule(prominent: false, tint: .red))
                    .accessibilityLabel(L10n.tr("credentials.action.revoke"))
                }

                if channels.count > 1 {
                    CollapseChevronButton(isExpanded: isExpanded) {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    }
                }
            }

            if isSharedCredential {
                Label(
                    L10n.tr("credentials.group.shared_format", String(channels.count)),
                    systemImage: "link"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let failureReason, !failureReason.isEmpty {
                Text(failureReason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health != .ready {
                Text(L10n.tr(CredentialStatusBadge.hintKey(health)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 组内的一条通道。
private struct ProviderChannelCard: View {
    let row: ProviderChannelRow
    let showsHealth: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        ForEach(row.protocols, id: \.self) { dialect in
                            AccountTagView(
                                text: dialect.legacy.displayName,
                                backgroundColor: Color.teal.opacity(0.16),
                                foregroundColor: .teal,
                                font: .system(size: 9, weight: .semibold),
                                horizontalPadding: 6,
                                verticalPadding: 2
                            )
                        }
                    }

                    // baseURL 与它的来源必须同时显示：只显示值的话，用户设了
                    // 环境变量却看到内置默认值，会以为改动没生效（FR-PRV-06）。
                    HStack(spacing: 4) {
                        Text(row.baseURL.isEmpty ? "—" : row.baseURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(baseURLSourceText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text(modelCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if showsHealth {
                    CredentialStatusBadge(state: row.health, throttled: row.throttled, compact: true)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frostedRoundedSurface(cornerRadius: 10, prominent: false)
        .opacity(row.enabled ? 1 : 0.55)
    }

    private var baseURLSourceText: String {
        let base = L10n.tr(row.baseURLSourceKey)
        guard let detail = row.baseURLSourceDetail, !detail.isEmpty else { return base }
        // 环境变量来源要带上变量名——"来自环境变量"本身无法告诉用户
        // 该去改哪一个。名字不是秘密，值才是。
        return "\(base) \(detail)"
    }

    /// `catalogOnly` 的 provider 在发现之前没有模型，显示 0 会被读成
    /// "配置错了"。它其实是"还没问过上游"（FR-PRV-01）。
    private var modelCountText: String {
        if row.catalogOnly && row.modelCount == 0 {
            return L10n.tr("providers.channel.catalog_only")
        }
        return L10n.tr("providers.channel.model_count_format", String(row.modelCount))
    }
}
