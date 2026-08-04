import SwiftUI

struct AccountsPageContentSection: View {
    let presentation: AccountsPageContentPresentation
    let cards: [AccountCardViewState]
    let availableViewportSize: CGSize
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void
    let onDeleteAccount: (String) -> Void

    var body: some View {
        switch presentation.state {
        case .loading:
            ProgressView(L10n.tr("accounts.loading.message"))
                .frame(maxWidth: .infinity, minHeight: 180)
        case .empty(let message):
            EmptyStateView(title: L10n.tr("accounts.empty.title"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .error(let message):
            EmptyStateView(title: L10n.tr("accounts.error.load_failed"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .content:
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                if presentation.shouldShowPendingWorkspaceSection {
                    PendingWorkspaceAuthorizationSection(
                        cards: presentation.pendingWorkspaceCards,
                        errorMessage: presentation.pendingWorkspaceError,
                        areCardsPresented: areCardsPresented,
                        onAuthorizeWorkspace: onAuthorizeWorkspace,
                        onCancelAuthorizeWorkspace: onCancelAuthorizeWorkspace,
                        onDeletePendingWorkspace: onDeletePendingWorkspace
                    )
                }

                AccountsGridSection(
                    cards: self.cards,
                    isOverviewMode: presentation.isOverviewMode,
                    availableViewportSize: availableViewportSize,
                    areCardsPresented: areCardsPresented,
                    onSwitchAccount: onSwitchAccount,
                    onRefreshAccountUsage: onRefreshAccountUsage,
                    onReauthenticateAccount: onReauthenticateAccount,
                    onDeleteAccount: onDeleteAccount
                )

                // Kept below the accounts: it is a summary of side traffic,
                // not something to scroll past to reach the account cards.
                if presentation.shouldShowThirdPartyUsageSection {
                    ThirdPartyUsageStatisticsSection(rows: presentation.thirdPartyUsageRows)
                }
            }
        }
    }
}

private struct AccountsGridSection: View {
    let cards: [AccountCardViewState]
    let isOverviewMode: Bool
    let availableViewportSize: CGSize
    let areCardsPresented: Bool
    let onSwitchAccount: (String) -> Void
    let onRefreshAccountUsage: (String) -> Void
    let onReauthenticateAccount: (String) -> Void
    let onDeleteAccount: (String) -> Void

    private var gridContext: LayoutRules.AccountsGridContext {
        #if os(iOS)
        LayoutRules.accountsGridContext(
            isOverviewMode: isOverviewMode,
            viewportSize: availableViewportSize
        )
        #else
        LayoutRules.AccountsGridContext(
            platform: .macOS,
            isOverviewMode: isOverviewMode,
            viewportSize: availableViewportSize
        )
        #endif
    }

    private var columns: [GridItem] {
        LayoutRules.accountsGridColumns(context: gridContext)
    }

    private var cardFrameWidth: CGFloat? {
        LayoutRules.accountsCardFrameWidth(context: gridContext)
    }

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: LayoutRules.accountsRowSpacing
        ) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                AccountCardGridItem(
                    card: card,
                    areCardsPresented: areCardsPresented,
                    frameWidth: cardFrameWidth,
                    index: index,
                    onSwitch: { onSwitchAccount(card.id) },
                    onRefresh: { onRefreshAccountUsage(card.id) },
                    onReauthenticate: { onReauthenticateAccount(card.id) },
                    onDelete: { onDeleteAccount(card.id) }
                )
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountCardGridItem: View {
    let card: AccountCardViewState
    let areCardsPresented: Bool
    let frameWidth: CGFloat?
    let index: Int
    let onSwitch: () -> Void
    let onRefresh: () -> Void
    let onReauthenticate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        AccountCardView(
            card: card,
            onSwitch: onSwitch,
            onRefresh: onRefresh,
            onReauthenticate: onReauthenticate,
            onDelete: onDelete
        )
        .frame(width: frameWidth)
        .copoolCardEntrance(index: index, isPresented: areCardsPresented)
        .modifier(AccountCardFrameModifier())
    }
}

private struct CardEntranceModifier: ViewModifier {
    let index: Int
    let isPresented: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented ? 0 : 22)
            .animation(
                AccountsAnimationRules.cardEntrance(index: index),
                value: isPresented
            )
    }
}

private extension View {
    func copoolCardEntrance(index: Int, isPresented: Bool) -> some View {
        modifier(CardEntranceModifier(index: index, isPresented: isPresented))
    }
}

private struct AccountCardFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PendingWorkspaceAuthorizationSection: View {
    let cards: [PendingWorkspaceAuthorizationCardViewState]
    let errorMessage: String?
    let areCardsPresented: Bool
    let onAuthorizeWorkspace: (String) -> Void
    let onCancelAuthorizeWorkspace: () -> Void
    let onDeletePendingWorkspace: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("accounts.pending.title"))
                    .font(.headline)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.tr("accounts.pending.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, LayoutRules.pagePadding)

            if let errorMessage, cards.isEmpty {
                PendingWorkspaceAuthorizationFailureCard(message: errorMessage)
                    .copoolCardEntrance(index: 0, isPresented: areCardsPresented)
                    .modifier(AccountCardFrameModifier())
                    .padding(.horizontal, LayoutRules.pagePadding)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: LayoutRules.accountsRowSpacing, alignment: .top)],
                    alignment: .leading,
                    spacing: LayoutRules.accountsRowSpacing
                ) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        PendingWorkspaceAuthorizationCard(
                            card: card,
                            onAuthorize: { onAuthorizeWorkspace(card.id) },
                            onCancelAuthorize: onCancelAuthorizeWorkspace,
                            onDelete: { onDeletePendingWorkspace(card.id) }
                        )
                        .copoolCardEntrance(index: index, isPresented: areCardsPresented)
                        .modifier(AccountCardFrameModifier())
                    }
                }
                .animation(
                    AccountsAnimationRules.contentReorder,
                    value: cards.map(\.id)
                )
                .padding(.horizontal, LayoutRules.pagePadding)
            }
        }
    }
}

private struct PendingWorkspaceAuthorizationCard: View {
    let card: PendingWorkspaceAuthorizationCardViewState
    let onAuthorize: () -> Void
    let onCancelAuthorize: () -> Void
    let onDelete: () -> Void

    private var isDeactivated: Bool {
        card.status == .deactivated
    }

    private var planLabel: String {
        AccountPlanLabel.normalized(from: card.planType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AccountTagView(
                            text: planLabel,
                            backgroundColor: Color.indigo.opacity(0.18),
                            foregroundColor: .indigo
                        )
                        AccountTagView(
                            text: card.workspaceName,
                            backgroundColor: Color.indigo.opacity(0.18),
                            foregroundColor: .indigo,
                            allowsCompression: true
                        )
                    }

                    if let email = card.email, !email.isEmpty {
                        Text(email)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                AccountTagView(
                    text: isDeactivated ? L10n.tr("accounts.card.status.deactivated") : L10n.tr("accounts.pending.tag"),
                    backgroundColor: isDeactivated ? Color.red.opacity(0.18) : Color.orange.opacity(0.18),
                    foregroundColor: isDeactivated ? .red : .orange
                )
            }

            Text(isDeactivated ? L10n.tr("error.accounts.workspace_deactivated") : L10n.tr("accounts.pending.hint"))
                .font(.caption)
                .foregroundStyle(isDeactivated ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                if !isDeactivated {
                    Button(action: card.authorizing ? onCancelAuthorize : onAuthorize) {
                        Label(
                            card.authorizing ? L10n.tr("common.cancel") : L10n.tr("accounts.pending.action.authorize"),
                            systemImage: card.authorizing ? "xmark.circle" : "checkmark.shield"
                        )
                        .lineLimit(1)
                    }
                    .copoolActionButtonStyle(
                        prominent: !card.authorizing,
                        tint: card.authorizing ? .secondary : .indigo,
                        density: .compact,
                        iOSStyle: .liquidGlass
                    )
                }

                Spacer(minLength: 0)

                AccountDeleteButton(action: onDelete, isDisabled: card.authorizing)
                    .accessibilityLabel(L10n.tr("accounts.pending.action.delete"))
            }
        }
        .padding(12)
        .frostedRoundedSurface(
            cornerRadius: 12,
            prominent: true,
            tint: isDeactivated ? .red.opacity(0.18) : .indigo.opacity(0.2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDeactivated ? Color.red.opacity(0.18) : Color.indigo.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct PendingWorkspaceAuthorizationFailureCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AccountTagView(
                    text: L10n.tr("accounts.pending.error.tag"),
                    backgroundColor: Color.red.opacity(0.18),
                    foregroundColor: .red
                )
                Spacer(minLength: 0)
            }

            Text(L10n.tr("accounts.pending.error.title"))
                .font(.headline)
                .foregroundStyle(.primary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.tr("accounts.pending.error.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frostedRoundedSurface(cornerRadius: 12, prominent: true, tint: .red.opacity(0.18))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
    }
}

/// Third-party provider usage statistics block shown in the accounts page.
///
/// The share chart is the resting state; the per-model breakdown sits behind a
/// disclosure so the block stays compact under the account cards.
struct ThirdPartyUsageStatisticsSection: View {
    let rows: [ThirdPartyUsageRowPresentation]

    @State private var isExpanded = false

    private var hasTokenData: Bool {
        rows.contains { $0.shareFraction > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, LayoutRules.pagePadding)

            if hasTokenData {
                ThirdPartyUsageShareChart(rows: rows)
                    .padding(.horizontal, LayoutRules.pagePadding)
            }

            if isExpanded || !hasTokenData {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        ThirdPartyUsageRowView(row: row)
                    }
                }
                .padding(.horizontal, LayoutRules.pagePadding)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("accounts.stats.third_party.title"))
                    .font(.headline)
                Text(L10n.tr("accounts.stats.third_party.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if hasTokenData {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        L10n.tr(isExpanded
                            ? "accounts.stats.third_party.collapse"
                            : "accounts.stats.third_party.expand"),
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Donut of each model's share of the section's total tokens, with a legend.
private struct ThirdPartyUsageShareChart: View {
    let rows: [ThirdPartyUsageRowPresentation]

    private static let palette: [Color] = [
        .indigo, .teal, .orange, .pink, .green, .purple, .blue, .brown,
    ]

    static func color(at index: Int) -> Color {
        palette[index % palette.count]
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                ForEach(Array(segments.enumerated()), id: \.element.id) { _, segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(
                            Self.color(at: segment.colorIndex),
                            style: StrokeStyle(lineWidth: 22, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 116, height: 116)
            // The stroke straddles the circle path, so half its width sits
            // outside the frame.
            .padding(11)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Self.color(at: row.colorIndex))
                            .frame(width: 8, height: 8)
                        Text(row.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.sharePercentText)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
    }

    private struct Segment: Identifiable {
        let id: String
        let colorIndex: Int
        let start: CGFloat
        let end: CGFloat
    }

    /// Trim ranges are cumulative, so each slice starts where the previous
    /// one ended.
    private var segments: [Segment] {
        var offset: CGFloat = 0
        return rows.compactMap { row in
            guard row.shareFraction > 0 else { return nil }
            let start = offset
            offset += CGFloat(row.shareFraction)
            return Segment(
                id: row.id,
                colorIndex: row.colorIndex,
                start: start,
                end: min(offset, 1)
            )
        }
    }
}

private struct ThirdPartyUsageRowView: View {
    let row: ThirdPartyUsageRowPresentation

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ThirdPartyUsageShareChart.color(at: row.colorIndex))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.lastUsedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(row.requestsText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(row.tokensText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frostedRoundedSurface(cornerRadius: 10, prominent: false)
    }
}
