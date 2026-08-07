import SwiftUI

/// 内置供应商注册表分区（SCR-PRV-01）。
///
/// 与下方的"自定义端点"列表并列而不是混排：注册表条目是内置的、可恢复默认的，
/// 自定义端点是用户造的、删了就没了。两者的删除语义完全不同，混在一张列表里
/// 会让"删除"这个动作变得无法预期。
struct ProviderRegistrySection: View {
    let groups: [ProviderRegistryPresenter.GroupViewData]
    var seedError: String?
    let onConfigure: (ProviderRegistryPresenter.GroupViewData) -> Void
    let onRevoke: (ProviderRegistryPresenter.GroupViewData) -> Void

    /// 未配置的条目默认折起。23 家全展开会把已配好的那两三家淹掉，
    /// 而用户每天要看的正是那几家。
    @State private var showsUnconfigured = false

    private var configured: [ProviderRegistryPresenter.GroupViewData] {
        groups.filter { $0.health != .unconfigured }
    }

    private var unconfigured: [ProviderRegistryPresenter.GroupViewData] {
        groups.filter { $0.health == .unconfigured }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let seedError {
                seedFailureNotice(seedError)
            } else if groups.isEmpty {
                EmptyStateView(
                    title: L10n.tr("providers.registry.title"),
                    message: L10n.tr("providers.registry.empty")
                )
            } else {
                ForEach(configured) { group in
                    section(for: group)
                }

                if !unconfigured.isEmpty {
                    unconfiguredDisclosure
                }
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("providers.registry.title"))
                .font(.headline)
            Spacer(minLength: 0)
            if !groups.isEmpty {
                Text(L10n.tr(
                    "providers.registry.count_format",
                    String(configured.count),
                    String(groups.count)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var unconfiguredDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsUnconfigured.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsUnconfigured ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(L10n.tr("providers.registry.available_format", String(unconfigured.count)))
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if showsUnconfigured {
                ForEach(unconfigured) { group in
                    section(for: group)
                }
            }
        }
    }

    private func section(for group: ProviderRegistryPresenter.GroupViewData) -> some View {
        ProviderGroupSection(
            title: group.title,
            health: group.health,
            throttled: group.throttled,
            failureReason: group.failureReason,
            lastVerifiedAt: group.lastVerifiedAt,
            channels: group.channels,
            isSharedCredential: group.isSharedCredential,
            onConfigureCredential: { onConfigure(group) },
            onRevokeCredential: group.health == .unconfigured ? nil : { onRevoke(group) },
            // 点通道行等同于配置这把凭据：M1 阶段通道本身没有独立的可编辑
            // 属性，多开一个空面板只会让人以为功能坏了。逐通道设置在 M2 引入。
            onSelectChannel: { _ in onConfigure(group) }
        )
    }

    /// 种子解析失败要说清是构建产物的问题，并给出可执行的下一步。
    /// 静默显示空列表会让用户去翻自己的配置，而那里根本没有问题。
    private func seedFailureNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.tr("providers.registry.seed_failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("providers.registry.seed_failed.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false, tint: .orange.opacity(0.12))
    }
}
