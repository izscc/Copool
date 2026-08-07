import SwiftUI

struct ProxyPageView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutRules.sectionSpacing) {
                subTabPicker
                switch model.subTab {
                case .overview:
                    // Keep the original three blocks intact so the second tab
                    // never looks "incomplete" after the sub-tab split.
                    ApiProxySectionView(model: model)
                    RemoteServersSectionView(model: model)
                    PublicAccessSection(model: model, onCopy: PlatformClipboard.copy)
                case .targets:
                    ProxyTargetsSection(model: model)
                    ProxyTargetConfigSection(model: model)
                case .remote:
                    RemoteServersSectionView(model: model)
                case .publicAccess:
                    PublicAccessSection(model: model, onCopy: PlatformClipboard.copy)
                case .logs:
                    ProxyLogsSection(model: model)
                }
            }
            .padding(LayoutRules.pagePadding)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
        .task {
            await model.loadIfNeeded()
            model.refreshTargetSnapshots()
        }
        .onChange(of: model.subTab) { _, newValue in
            if newValue == .targets {
                model.refreshTargetSnapshots()
            }
        }
    }

    private var subTabPicker: some View {
        CapsuleSubTabBar(
            selection: $model.subTab,
            tabs: ProxySubTab.allCases.map { ($0, $0.label) }
        )
    }
}

/// Targets sub-tab (AC-008): one card per target binding — stable route key,
/// endpoint, dialect, credential state. Read-only; editing stays in the
/// Providers tab.
private struct ProxyTargetsSection: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("proxy.targets.title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("proxy.targets.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.targetSnapshots.isEmpty {
                Text(L10n.tr("proxy.targets.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.targetSnapshots) { target in
                    HStack(spacing: 10) {
                        Image(systemName: target.enabled ? "circle.inset.filled" : "circle.dashed")
                            .foregroundStyle(target.enabled ? .green : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                                .font(.caption.weight(.medium))
                            Text(target.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(target.endpoint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(target.dialect)
                                Text("·")
                                Text(L10n.tr("proxy.targets.models_format", String(target.modelCount)))
                                if !target.credentialed {
                                    Text(L10n.tr("proxy.targets.no_credential"))
                                        .foregroundStyle(.orange)
                                }
                                // 目录漂移后写在磁盘上的那份配置已经不是当前目录了
                                // （FR-CAT-11）。只对该目标启用的 provider 判定，
                                // 改别家 provider 不会点亮这里。
                                if model.targetBindingCoordinator?.isStale(bindingID: target.id) == true {
                                    Text(L10n.tr("targets.badge.stale"))
                                        .foregroundStyle(.orange)
                                        .help(L10n.tr("targets.badge.stale_help"))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
                    if target.id == "cursor" || target.id == "opencode" {
                        HStack(spacing: 6) {
                            Button(L10n.tr("targets.action.plan")) {
                                model.targetConfigCoordinator?.planTarget(target.id, port: 8787)
                            }
                            Button(L10n.tr("targets.action.apply")) {
                                model.targetConfigCoordinator?.applyTarget(target.id, port: 8787)
                            }
                            .disabled(model.targetConfigCoordinator?.targetPlanSummaries[target.id] == nil)
                            Button(L10n.tr("targets.action.rollback")) {
                                model.targetConfigCoordinator?.rollbackTarget(target.id)
                            }
                            Button(L10n.tr("targets.action.uninstall"), role: .destructive) {
                                model.targetConfigCoordinator?.uninstallTarget(target.id)
                            }
                        }
                        .font(.caption2)
                    }
                    if let summary = model.targetConfigCoordinator?.targetPlanSummaries[target.id] {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
    }
}

/// Codex target config management (AC-101/AC-007): plan → confirm → apply →
/// verify, plus rollback. Never writes without explicit user confirmation.
private struct ProxyTargetConfigSection: View {
    @ObservedObject var model: ProxyPageModel
    @State private var confirmApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("proxy.targets.config_title"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.targetConfigCoordinator?.codexManaged == true {
                    AccountTagView(
                        text: L10n.tr("proxy.targets.config_managed"),
                        backgroundColor: Color.green.opacity(0.16),
                        foregroundColor: .green
                    )
                }
            }
            Text(L10n.tr("proxy.targets.config_subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary = model.targetConfigCoordinator?.codexPlanSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(L10n.tr("proxy.targets.config_plan")) {
                    model.targetConfigCoordinator?.planCodexApply()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.tr("proxy.targets.config_apply")) {
                    confirmApply = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.targetConfigCoordinator?.codexPlanSummary == nil)

                Button(L10n.tr("proxy.targets.config_rollback")) {
                    model.targetConfigCoordinator?.rollbackCodex()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.targetConfigCoordinator?.lastAppliedTargetID == nil)
            }

            if let notice = model.targetConfigCoordinator?.notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .confirmationDialog(
            L10n.tr("proxy.targets.config_confirm_title"),
            isPresented: $confirmApply,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("proxy.targets.config_confirm_apply"), role: .destructive) {
                model.targetConfigCoordinator?.applyCodexPlan()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("proxy.targets.config_confirm_message"))
        }
    }
}

/// Logs sub-tab: local proxy process log tail plus a shortcut to remote logs.
private struct ProxyLogsSection: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("proxy.logs.title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("proxy.logs.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LocalLogTailView(model: model)

            if !model.remoteServers.isEmpty {
                Divider()
                Text(L10n.tr("proxy.logs.remote_title"))
                    .font(.caption.weight(.medium))
                ForEach(model.remoteServers) { server in
                    HStack {
                        Text(server.label)
                            .font(.caption)
                        Spacer()
                        Button(L10n.tr("proxy.logs.open_remote")) {
                            Task { await model.readRemoteLogs(server: server) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
    }
}

/// Tail of the in-process proxy log (last 60 lines, read from the app's
/// stderr capture if available, else a note).
private struct LocalLogTailView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        let lines = ProxyProcessLogTail.recentLines(limit: 60)
        if lines.isEmpty {
            Text(L10n.tr("proxy.logs.empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
