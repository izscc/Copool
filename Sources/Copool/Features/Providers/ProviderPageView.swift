import SwiftUI

/// Third-party model management page: onboarding, local subscription import,
/// provider presets, and the provider list.
struct ProviderPageView: View {
    @ObservedObject var model: ProviderPageModel

    private enum SubTab: String, CaseIterable {
        case providers
        case catalog
        case routes
        case usage
    }

    @State private var subTab: SubTab = .providers

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                ProviderStatusBar(summary: statusSummary)
                CapsuleSubTabBar(
                    selection: $subTab,
                    tabs: SubTab.allCases.map { ($0, L10n.tr("models.tab.\($0.rawValue)")) }
                )
                .padding(.horizontal, LayoutRules.pagePadding)
                .onChange(of: subTab) { _, newValue in
                    if newValue == .catalog {
                        model.loadManagementCatalog()
                    }
                }

                switch subTab {
                case .providers:
                    providersContent
                case .catalog:
                    CatalogSection(
                        groups: model.catalogGroups,
                        query: model.catalogQuery,
                        showsHidden: model.catalogShowsHidden,
                        expertMode: model.catalogExpertMode,
                        selection: model.catalogSelection,
                        refreshingInstanceIDs: model.catalogRefreshingInstanceIDs,
                        aliasConflicts: model.catalogAliasConflicts,
                        onQueryChange: { model.updateCatalogQuery($0) },
                        onToggleShowsHidden: { model.toggleCatalogShowsHidden() },
                        onToggleExpertMode: { model.catalogExpertMode.toggle() },
                        onToggleSelection: { model.toggleCatalogSelection(entryID: $0) },
                        onSelectAllInGroup: { model.selectAllInGroup($0) },
                        onClearSelection: { model.clearCatalogSelection() },
                        onBulkVisibility: { model.setCatalogVisibility($0, entryIDs: model.catalogSelection) },
                        onToggleVisibility: { model.toggleCatalogVisibility(entryID: $0) },
                        onRefresh: { instanceID in
                            Task { await model.refreshCatalog(instanceID: instanceID) }
                        },
                        onConfigure: { definitionID in
                            if let group = model.providerGroups.first(where: { $0.channels.contains { $0.definitionID == definitionID } }) {
                                model.beginConfiguringCredential(group)
                            }
                        }
                    )
                case .routes:
                    RoutesPolicySection(
                        traces: model.recentRouteDecisions,
                        entityNames: model.routeEntityNames,
                        fallbackPolicy: model.fallbackPolicy,
                        onFallbackPolicyChange: { model.updateFallbackPolicy($0) },
                        onRefresh: { model.reloadRouteDecisions() }
                    )
                case .usage:
                    UsageSection(
                        rateLimits: model.rateLimits,
                        accountUsage: model.accountUsage,
                        aggregates: model.usageAggregates
                    )
                }
            }
        }
        .sheet(item: $model.credentialSheet) { credentialSheet(for: $0) }
        .sheet(item: $model.consentSheet) { consentSheet(for: $0) }
        .onAppear { model.refreshSplitState() }
    }

    @ViewBuilder private func credentialSheet(for context: ProviderPageModel.CredentialSheetContext) -> some View {
        CredentialEntrySheet(
            providerDisplayName: context.group.title,
            availableModes: CredentialEntrySheet.Mode.modes(for: context.group.credentialKinds),
            credentialPrompt: context.group.credentialPrompt,
            environmentVariableCandidates: context.group.environmentVariableCandidates,
            sharedChannelNames: context.group.isSharedCredential
                ? context.group.channels.map(\.displayName)
                : [],
            onSaveAPIKey: { model.saveAPIKey(for: context.group, key: $0) },
            onBindEnvironment: { model.bindEnvironmentVariable(for: context.group, name: $0) },
            onCancel: { model.dismissCredentialSheets() }
        )
    }

    @ViewBuilder private func consentSheet(for context: ProviderPageModel.ConsentSheetContext) -> some View {
        DisclosureConsentSheet(
            title: L10n.tr("consent.external_session.title"),
            subject: context.spec.cliName,
            disclosure: context.spec.disclosure,
            bulletPoints: Self.externalSessionBullets(path: context.resolvedPath),
            confirmTitle: L10n.tr("consent.external_session.confirm"),
            onConfirm: {
                model.bindExternalSession(
                    for: context.group,
                    sessionPath: context.resolvedPath,
                    // 落审计的是用户刚看到的原文，不是文案 key——
                    // 文案日后会改，审计要回答"当时看到的是什么"。
                    disclosure: context.spec.disclosure
                )
            },
            onCancel: { model.dismissCredentialSheets() }
        )
    }

    /// 披露正文之外的逐条影响面。第一条是路径，用户有权知道到底读哪个文件。
    private static func externalSessionBullets(path: String) -> [String] {
        [
            L10n.tr("consent.external_session.bullet_path_format", path),
            L10n.tr("consent.external_session.bullet_no_copy"),
            L10n.tr("consent.external_session.bullet_read_only"),
            L10n.tr("consent.external_session.bullet_revoke")
        ]
    }
}
