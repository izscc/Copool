import Foundation

struct AccountsPageContentPresentation: Equatable {
    let state: ViewState<[String]>
    let pendingWorkspaceCards: [PendingWorkspaceAuthorizationCardViewState]
    let pendingWorkspaceError: String?
    let isOverviewMode: Bool
    let thirdPartyUsageRows: [ThirdPartyUsageRowPresentation]

    var shouldShowPendingWorkspaceSection: Bool {
        !isOverviewMode && (!pendingWorkspaceCards.isEmpty || pendingWorkspaceError != nil)
    }

    var shouldShowThirdPartyUsageSection: Bool {
        !thirdPartyUsageRows.isEmpty
    }
}

/// One row in the third-party usage statistics section.
struct ThirdPartyUsageRowPresentation: Equatable, Identifiable {
    let id: String
    let title: String          // providerName / modelID
    let requestsText: String
    let tokensText: String
    let lastUsedText: String
    /// Slice of the section's total tokens, 0...1.
    let shareFraction: Double
    let sharePercentText: String
    /// Position in the token ranking, used to pick a stable slice colour.
    let colorIndex: Int
}

struct AccountsActionBarPresentation: Equatable {
    let descriptors: [AccountsActionButtonDescriptor<AccountsPageActionIntent>]
    let collapse: AccountsCollapsePresentation
}

struct AccountCardViewState: Equatable, Identifiable {
    let account: AccountSummary
    let presentation: AccountCardPresentation
    let isCollapsed: Bool
    let switching: Bool
    let refreshing: Bool
    let showsRefreshButton: Bool
    let showsReauthenticateButton: Bool
    let isRefreshEnabled: Bool
    let isUsageRefreshActive: Bool
    let usageProgressDisplayMode: UsageProgressDisplayMode

    var id: String {
        account.id
    }

    static func == (lhs: AccountCardViewState, rhs: AccountCardViewState) -> Bool {
        lhs.isCollapsed == rhs.isCollapsed
            && lhs.switching == rhs.switching
            && lhs.refreshing == rhs.refreshing
            && lhs.showsRefreshButton == rhs.showsRefreshButton
            && lhs.showsReauthenticateButton == rhs.showsReauthenticateButton
            && lhs.isRefreshEnabled == rhs.isRefreshEnabled
            && lhs.isUsageRefreshActive == rhs.isUsageRefreshActive
            && lhs.usageProgressDisplayMode == rhs.usageProgressDisplayMode
            && lhs.account.id == rhs.account.id
            && lhs.account.label == rhs.account.label
            && lhs.account.email == rhs.account.email
            && lhs.account.accountID == rhs.account.accountID
            && lhs.account.planType == rhs.account.planType
            && lhs.account.teamName == rhs.account.teamName
            && lhs.account.teamAlias == rhs.account.teamAlias
            && lhs.account.usage == rhs.account.usage
            && lhs.account.usageError == rhs.account.usageError
            && lhs.account.workspaceStatus == rhs.account.workspaceStatus
            && lhs.account.displayStatus == rhs.account.displayStatus
            && lhs.account.isCurrent == rhs.account.isCurrent
    }
}

struct PendingWorkspaceAuthorizationCardViewState: Equatable, Identifiable {
    let id: String
    let workspaceID: String
    let workspaceName: String
    let email: String?
    let planType: String?
    let status: WorkspaceAuthorizationCandidateStatus
    let authorizing: Bool
}

enum PendingWorkspaceCardRules {
    static func sortedForDisplay(
        _ cards: [PendingWorkspaceAuthorizationCardViewState]
    ) -> [PendingWorkspaceAuthorizationCardViewState] {
        cards.sorted {
            sortsBefore(
                lhsStatus: $0.status,
                lhsName: $0.workspaceName,
                rhsStatus: $1.status,
                rhsName: $1.workspaceName
            )
        }
    }

    static func sortedCandidates(
        _ candidates: [WorkspaceAuthorizationCandidate]
    ) -> [WorkspaceAuthorizationCandidate] {
        candidates.sorted {
            sortsBefore(
                lhsStatus: $0.status,
                lhsName: $0.workspaceName,
                rhsStatus: $1.status,
                rhsName: $1.workspaceName
            )
        }
    }

    static func sortsBefore(
        lhsStatus: WorkspaceAuthorizationCandidateStatus,
        lhsName: String,
        rhsStatus: WorkspaceAuthorizationCandidateStatus,
        rhsName: String
    ) -> Bool {
        if lhsStatus != rhsStatus {
            return lhsStatus == .deactivated
        }
        return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
    }
}

extension AccountsPageModel {
    func makeAccountCardViewState(
        for account: AccountSummary,
        locale: Locale = .autoupdatingCurrent
    ) -> AccountCardViewState {
        let isCollapsed = isAccountCollapsed(account.id)
        return AccountCardViewState(
            account: account,
            presentation: AccountCardPresentation(
                account: account,
                isCollapsed: isCollapsed,
                locale: locale,
                usageProgressDisplayMode: usageProgressDisplayMode
            ),
            isCollapsed: isCollapsed,
            switching: switchingAccountID == account.id,
            refreshing: isAccountRefreshing(account.id),
            showsRefreshButton: runtimePlatform == .macOS,
            showsReauthenticateButton: account.usageError == L10n.tr("error.accounts.sign_in_expired"),
            isRefreshEnabled: canRefreshAccount(account.id),
            isUsageRefreshActive: isUsageRefreshActive(forAccountID: account.id),
            usageProgressDisplayMode: usageProgressDisplayMode
        )
    }

    func makeAccountCardViewState(
        forAccountID accountID: String,
        locale: Locale = .autoupdatingCurrent
    ) -> AccountCardViewState? {
        guard case .content(let accounts) = state else { return nil }
        guard let account = accounts.first(where: { $0.id == accountID && $0.isVisibleInMainList }) else {
            return nil
        }
        return makeAccountCardViewState(for: account, locale: locale)
    }

    func makeAccountCardViewStates(locale: Locale = .autoupdatingCurrent) -> [AccountCardViewState] {
        guard case .content(let accounts) = state else { return [] }
        return accounts
            .filter(\.isVisibleInMainList)
            .map { makeAccountCardViewState(for: $0, locale: locale) }
    }

    func makeContentPresentation() -> AccountsPageContentPresentation {
        let contentState = state.mapContent { accounts in
            accounts
                .filter(\.isVisibleInMainList)
                .map(\.id)
        }
        let accountPendingCards = currentPendingCards()
        let pendingAuthorizationCards = pendingWorkspaceAuthorizations.map { candidate in
            PendingWorkspaceAuthorizationCardViewState(
                id: candidate.id,
                workspaceID: candidate.workspaceID,
                workspaceName: candidate.workspaceName,
                email: candidate.email,
                planType: candidate.planType,
                status: candidate.status,
                authorizing: authorizingWorkspaceID == candidate.id
            )
        }
        let pendingCards = PendingWorkspaceCardRules.sortedForDisplay(
            accountPendingCards + pendingAuthorizationCards
        )
        let pendingError = pendingCards.isEmpty ? nil : pendingWorkspaceAuthorizationError
        return AccountsPageContentPresentation(
            state: contentState,
            pendingWorkspaceCards: pendingCards,
            pendingWorkspaceError: pendingError,
            isOverviewMode: areAllAccountsCollapsed,
            thirdPartyUsageRows: thirdPartyUsageRows()
        )
    }

    /// Builds the third-party usage rows from the persisted ledger.
    ///
    /// Ordered by token spend rather than recency so the share chart, its
    /// legend and the detail list all read in the same order.
    func thirdPartyUsageRows(locale: Locale = .autoupdatingCurrent) -> [ThirdPartyUsageRowPresentation] {
        guard let thirdPartyUsageRepository,
              let store = try? thirdPartyUsageRepository.loadUsage() else {
            return []
        }

        let entries = store.entries.sorted {
            $0.totalTokens == $1.totalTokens
                ? $0.lastUsedAt > $1.lastUsedAt
                : $0.totalTokens > $1.totalTokens
        }
        let totalTokens = entries.reduce(0) { $0 + $1.totalTokens }

        return entries.enumerated().map { index, entry in
            let share = totalTokens > 0 ? Double(entry.totalTokens) / Double(totalTokens) : 0
            return ThirdPartyUsageRowPresentation(
                id: entry.id,
                title: "\(entry.providerName) / \(entry.modelID)",
                requestsText: L10n.tr("accounts.stats.third_party.requests_format", String(entry.requests)),
                tokensText: L10n.tr(
                    "accounts.stats.third_party.tokens_format",
                    Self.formatTokenCount(entry.totalTokens)
                ),
                lastUsedText: Self.formatLastUsed(entry.lastUsedAt, locale: locale),
                shareFraction: share,
                sharePercentText: Self.formatShare(share),
                colorIndex: index
            )
        }
    }

    /// Tokens are always shown in millions so figures stay comparable across
    /// models; anything that would round away to zero is marked as such
    /// instead of reading like no usage at all.
    static func formatTokenCount(_ count: Int) -> String {
        let millions = Double(count) / 1_000_000
        if count > 0 && millions < 0.005 {
            return L10n.tr("accounts.stats.third_party.tokens_under_format", "0.01M")
        }
        return String(format: "%.2fM", millions)
    }

    static func formatShare(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0 && percent < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percent)
    }

    private static func formatLastUsed(_ unixSeconds: Int64, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func makeMacActionBarPresentation() -> AccountsActionBarPresentation {
        AccountsActionBarPresentation(
            descriptors: desktopActionButtons,
            collapse: collapsePresentation
        )
    }

    private func currentPendingCards() -> [PendingWorkspaceAuthorizationCardViewState] {
        guard case .content(let accounts) = state else { return [] }
        return accounts.compactMap { account in
            guard account.isPendingDisplay || account.isWorkspaceDeactivated else { return nil }
            return PendingWorkspaceAuthorizationCardViewState(
                id: account.id,
                workspaceID: account.accountID,
                workspaceName: account.displayTeamName ?? account.teamName ?? account.label,
                email: account.email,
                planType: account.planType ?? account.usage?.planType,
                status: account.isWorkspaceDeactivated ? .deactivated : .pending,
                authorizing: false
            )
        }
    }
}

private extension ViewState {
    func mapContent<NewValue>(_ transform: (Value) -> NewValue) -> ViewState<NewValue> {
        switch self {
        case .loading:
            return .loading
        case .empty(let message):
            return .empty(message: message)
        case .content(let value):
            return .content(transform(value))
        case .error(let message):
            return .error(message: message)
        }
    }
}
