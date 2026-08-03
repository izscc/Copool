import Foundation

struct AccountsWidgetSnapshotBuilder {
    private let maxRowCount: Int

    init(maxRowCount: Int = 4) {
        self.maxRowCount = maxRowCount
    }

    func build(
        accounts: [AccountSummary],
        usageProgressDisplayMode: UsageProgressDisplayMode,
        locale: Locale,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: Date = .now
    ) -> AccountsWidgetSnapshot {
        let sorted = AccountRanking.sortForDisplay(accounts)
        guard let current = sorted.first else {
            return .empty
        }

        let remaining = Array(sorted.dropFirst())
        return AccountsWidgetSnapshot(
            generatedAt: Int64(now.timeIntervalSince1970),
            usageProgressDisplayMode: usageProgressDisplayMode == .remaining ? .remaining : .used,
            currentCard: cardSnapshot(for: current, locale: locale, timeZone: timeZone),
            secondaryCard: remaining.first.map { cardSnapshot(for: $0, locale: locale, timeZone: timeZone) },
            rows: Array(remaining.prefix(maxRowCount)).map {
                rowSnapshot(for: $0, locale: locale, timeZone: timeZone)
            }
        )
    }

    private func cardSnapshot(
        for account: AccountSummary,
        locale: Locale,
        timeZone: TimeZone
    ) -> AccountsWidgetCardSnapshot {
        AccountsWidgetCardSnapshot(
            id: account.id,
            planLabel: account.normalizedPlanLabel,
            workspaceLabel: account.displayTeamName,
            accountLabel: AccountDisplayNameFormatter.format(account: account, style: .localPart),
            oneWeek: windowSnapshot(
                title: "1w",
                window: account.usage?.oneWeek,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    private func rowSnapshot(
        for account: AccountSummary,
        locale: Locale,
        timeZone: TimeZone
    ) -> AccountsWidgetRowSnapshot {
        let accountLabel = AccountDisplayNameFormatter.format(account: account, style: .localPart)
        return AccountsWidgetRowSnapshot(
            id: account.id,
            planLabel: account.normalizedPlanLabel,
            workspaceLabel: account.displayTeamName,
            accountLabel: accountLabel,
            oneWeek: windowSnapshot(
                title: "1w",
                window: account.usage?.oneWeek,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    private func windowSnapshot(
        title: String,
        window: UsageWindow?,
        locale: Locale,
        timeZone: TimeZone
    ) -> AccountsWidgetWindowSnapshot {
        let usedPercent = clamped(window?.usedPercent ?? 100)
        let remaining = max(0, 100 - Int(usedPercent.rounded()))

        return AccountsWidgetWindowSnapshot(
            title: title,
            progressFraction: usedPercent / 100,
            usedText: "\(Int(usedPercent.rounded()))%",
            remainingText: "\(remaining)%",
            resetText: resetText(for: window, locale: locale, timeZone: timeZone)
        )
    }

    private func resetText(
        for window: UsageWindow?,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        guard let resetAt = window?.resetAt else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yy/M/d HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetAt)))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
