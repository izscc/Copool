import SwiftUI

/// 模型目录管理（SCR-PRV-02）。
///
/// 一屏要同时回答四个问题：我有哪些模型、它们能力如何、这些数字可不可信、
/// 还差什么才能用。前三个靠分组和右侧的能力摘要，最后一个靠沉底的
/// 「缺少凭据」分组——把它排在最后而不是弹一个横幅，是因为用户通常只缺
/// 一两家，横幅会让他以为整页都不可用。
struct CatalogSection: View {
    let groups: [CatalogBuilder.ManagementGroup]
    let query: String
    let showsHidden: Bool
    let expertMode: Bool
    let selection: Set<String>
    let refreshingInstanceIDs: Set<String>
    let aliasConflicts: [CatalogCuration.AliasConflict]

    let onQueryChange: (String) -> Void
    let onToggleShowsHidden: () -> Void
    let onToggleExpertMode: () -> Void
    let onToggleSelection: (String) -> Void
    let onSelectAllInGroup: (CatalogBuilder.ManagementGroup) -> Void
    let onClearSelection: () -> Void
    let onBulkVisibility: (ModelVisibility) -> Void
    let onToggleVisibility: (String) -> Void
    let onRefresh: (String) -> Void
    let onConfigure: (String) -> Void

    private var ready: [CatalogBuilder.ManagementGroup] {
        groups.filter { !$0.needsCredential }
    }

    private var blocked: [CatalogBuilder.ManagementGroup] {
        groups.filter { $0.needsCredential }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchBar

            if !aliasConflicts.isEmpty {
                aliasConflictNotice
            }

            if groups.isEmpty {
                EmptyStateView(
                    title: L10n.tr("models.tab.catalog"),
                    message: query.isEmpty
                        ? L10n.tr("models.catalog.empty")
                        : L10n.tr("catalog.search.no_match")
                )
            } else {
                ForEach(ready) { group in
                    CatalogGroupCard(
                        group: group,
                        expertMode: expertMode,
                        selection: selection,
                        isRefreshing: group.instance.map { refreshingInstanceIDs.contains($0.id) } ?? false,
                        onToggleSelection: onToggleSelection,
                        onSelectAll: { onSelectAllInGroup(group) },
                        onToggleVisibility: onToggleVisibility,
                        onRefresh: onRefresh,
                        onConfigure: onConfigure
                    )
                }

                if !blocked.isEmpty {
                    blockedDisclosure
                }
            }

            if !selection.isEmpty {
                bulkBar
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("models.tab.catalog"))
                .font(.headline)
            Spacer(minLength: 0)
            Button(showsHidden
                   ? L10n.tr("catalog.filter.hide_hidden")
                   : L10n.tr("catalog.filter.show_hidden")) {
                onToggleShowsHidden()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.tint)
            // 专家模式只加信息不改行为：元数据出处对排障有用，对日常选模型
            // 是纯噪声，所以默认关掉而不是塞进每一行。
            Button(expertMode
                   ? L10n.tr("catalog.expert.on")
                   : L10n.tr("catalog.expert.off")) {
                onToggleExpertMode()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.tint)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                L10n.tr("catalog.search.placeholder"),
                text: Binding(get: { query }, set: onQueryChange)
            )
            .textFieldStyle(.plain)
            .font(.caption)
            if !query.isEmpty {
                Button {
                    onQueryChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 别名冲突必须显式报出来：两个条目抢同一个别名时，路由该去哪家没有
    /// 答案，而症状是"偶尔发到了错的 provider"——最难排查的那一类（FR-CAT-07）。
    private var aliasConflictNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                L10n.tr("catalog.alias.conflict_title"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            ForEach(aliasConflicts.prefix(3)) { conflict in
                Text(String(
                    format: L10n.tr("catalog.alias.conflict_format"),
                    conflict.alias,
                    conflict.entryIDs.count
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
    }

    // MARK: - 缺少凭据

    @State private var showsBlocked = false

    private var blockedDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsBlocked.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsBlocked ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(String(format: L10n.tr("catalog.blocked.title_format"), blocked.count))
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if showsBlocked {
                ForEach(blocked) { group in
                    CatalogGroupCard(
                        group: group,
                        expertMode: expertMode,
                        selection: selection,
                        isRefreshing: false,
                        onToggleSelection: onToggleSelection,
                        onSelectAll: { onSelectAllInGroup(group) },
                        onToggleVisibility: onToggleVisibility,
                        onRefresh: onRefresh,
                        onConfigure: onConfigure
                    )
                }
            }
        }
    }

    // MARK: - 批量操作

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text(String(format: L10n.tr("catalog.bulk.selected_format"), selection.count))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(L10n.tr("catalog.bulk.hide")) { onBulkVisibility(.hidden) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tint)
            Button(L10n.tr("catalog.bulk.show")) { onBulkVisibility(.visible) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tint)
            Button(L10n.tr("catalog.bulk.clear")) { onClearSelection() }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
    }
}

// MARK: - 分组卡片

/// 一个 provider 的目录分组。默认折起模型列表：一家网关能列两百个模型，
/// 全部展开会把其余 provider 挤出视野。
private struct CatalogGroupCard: View {
    let group: CatalogBuilder.ManagementGroup
    let expertMode: Bool
    let selection: Set<String>
    let isRefreshing: Bool
    let onToggleSelection: (String) -> Void
    let onSelectAll: () -> Void
    let onToggleVisibility: (String) -> Void
    let onRefresh: (String) -> Void
    let onConfigure: (String) -> Void

    @State private var expanded = false

    private var hiddenCount: Int {
        group.rows.filter { $0.isHidden }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let state = group.refreshState {
                refreshStateLine(state)
            }

            if expanded {
                if !group.rows.isEmpty {
                    ForEach(group.rows) { row in
                        CatalogEntryRow(
                            entry: row.entry,
                            expertMode: expertMode,
                            isSelected: selection.contains(row.id),
                            onToggleSelection: { onToggleSelection(row.id) },
                            onToggleVisibility: { onToggleVisibility(row.id) }
                        )
                    }
                    if hiddenCount > 0 {
                        Text(String(format: L10n.tr("catalog.hidden_footer_format"), hiddenCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if !group.pendingEntries.isEmpty {
                    // 预览：还没入库，只是让用户知道配好之后能拿到什么。
                    Text(L10n.tr("catalog.preview.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(group.pendingEntries.prefix(8), id: \.backendModelID) { entry in
                        CatalogEntryRow(
                            entry: entry,
                            expertMode: expertMode,
                            isSelected: false,
                            onToggleSelection: nil,
                            onToggleVisibility: nil
                        )
                    }
                    if group.pendingEntries.count > 8 {
                        Text(L10n.tr(
                            "providers.curate.more_format",
                            String(group.pendingEntries.count - 8)
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr("catalog.group.empty"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(group.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(String(format: L10n.tr("catalog.group.count_format"), group.modelCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if group.needsCredential {
                Button(L10n.tr("catalog.group.configure")) {
                    onConfigure(group.definitionID)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tint)
            } else if let instance = group.instance {
                if expanded && !group.rows.isEmpty {
                    Button(L10n.tr("catalog.bulk.select_all")) { onSelectAll() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.tr("catalog.refresh")) { onRefresh(instance.id) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    /// 上次刷新的结果。失败时说明目录仍是上次成功的那份——不写清楚的话，
    /// 用户会以为看到的数字已经被这次失败刷新过了（FR-CAT-03）。
    private func refreshStateLine(_ state: CatalogRefreshState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.succeeded ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(state.succeeded ? Color.secondary : Color.orange)
            Text(state.succeeded
                 ? String(
                    format: L10n.tr("catalog.refresh.success_format"),
                    Self.relativeTime(state.lastSuccessAt ?? state.lastAttemptAt),
                    state.discoveredCount ?? 0
                   )
                 : String(
                    format: L10n.tr("catalog.refresh.failure_format"),
                    Self.relativeTime(state.lastAttemptAt),
                    state.failureReason ?? ""
                   ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static func relativeTime(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 条目行

/// 一行模型。左侧是身份（显示名 + 后端 ID），右侧是能力摘要
/// （上下文窗口 · 推理档位）。
///
/// 后端 ID 始终显示而不是只在显示名缺失时显示：用户在别处（文档、其他
/// 客户端）看到的是后端 ID，把它藏起来会让两边对不上号（FR-CAT-07）。
private struct CatalogEntryRow: View {
    let entry: ModelCatalogEntry
    let expertMode: Bool
    let isSelected: Bool
    /// nil 表示这是预览行，不可操作。
    let onToggleSelection: (() -> Void)?
    let onToggleVisibility: (() -> Void)?

    private var isHidden: Bool { entry.visibility == .hidden }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let onToggleSelection {
                Button {
                    onToggleSelection()
                } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.effectiveDisplayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isHidden {
                        badge(L10n.tr("catalog.badge.hidden"), tint: .secondary)
                    }
                    if !entry.upstreamAvailable {
                        badge(L10n.tr("catalog.badge.delisted"), tint: .orange)
                    }
                }
                if entry.effectiveDisplayName != entry.backendModelID {
                    Text(entry.backendModelID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !entry.aliases.isEmpty {
                    Text(entry.aliases.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            capabilitySummary

            if let onToggleVisibility {
                Button {
                    onToggleVisibility()
                } label: {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isHidden ? L10n.tr("catalog.action.unhide") : L10n.tr("catalog.action.hide"))
            }
        }
        .padding(.vertical, 4)
        .opacity(isHidden ? 0.55 : 1)
    }

    /// 上下文窗口 · 推理档位。
    ///
    /// 档位为空时**整块不显示**，而不是显示"无"或摆一个空选择器：
    /// `nil`（没发现）和 `[]`（上游明确没有）对用户是同一件事——这里没得选，
    /// 而两者都不该被渲染成三个可点的假档位（FR-CAT-05）。
    private var capabilitySummary: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Text(contextWindowText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // 估算值必须打标：一个没有出处的数字被当成上游确认过的，
                // 用户会照着它设压缩阈值，然后在真实上限处撞墙（FR-CAT-06）。
                if entry.hasEstimatedContextWindow {
                    badge(L10n.tr("catalog.badge.estimated"), tint: .secondary)
                }
            }
            if entry.capabilities.showsReasoningEffortPicker {
                Text(entry.capabilities.effectiveReasoningEfforts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if expertMode {
                Text(String(
                    format: L10n.tr("catalog.provenance_format"),
                    Self.sourceLabel(entry.contextWindowSource),
                    Self.sourceLabel(entry.reasoningSource)
                ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var contextWindowText: String {
        guard let window = entry.capabilities.contextWindow else {
            return L10n.tr("catalog.context.unknown")
        }
        return "\(window / 1000)k"
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private static func sourceLabel(_ source: MetadataSource) -> String {
        switch source {
        case .provider: return L10n.tr("catalog.source.provider")
        case .registry: return L10n.tr("catalog.source.registry")
        case .fallback: return L10n.tr("catalog.source.fallback")
        }
    }
}
