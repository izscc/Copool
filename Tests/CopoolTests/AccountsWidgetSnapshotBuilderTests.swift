import Foundation
import Testing
@testable import Copool

struct AccountsWidgetSnapshotBuilderTests {
    @Test
    func currentAccountBecomesPrimaryCardAndSecondaryUsesNextDisplayAccount() {
        let builder = AccountsWidgetSnapshotBuilder()
        let snapshot = builder.build(
            accounts: [
                account(id: "b", isCurrent: false, email: "second@example.com", fiveHourUsed: 35, oneWeekUsed: 45),
                account(id: "a", isCurrent: true, email: "current@example.com", fiveHourUsed: 15, oneWeekUsed: 25)
            ],
            usageProgressDisplayMode: .used,
            locale: Locale(identifier: "zh-Hans"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.currentCard?.id == "a")
        #expect(snapshot.currentCard?.accountLabel == "current")
        #expect(snapshot.secondaryCard?.id == "b")
        #expect(snapshot.secondaryCard?.accountLabel == "second")
    }

    @Test
    func rowsKeepWorkspaceAndAccountLabelsAndExposeWindowSnapshots() {
        let builder = AccountsWidgetSnapshotBuilder()
        let snapshot = builder.build(
            accounts: [
                account(id: "current", isCurrent: true, email: "current@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
                account(
                    id: "team",
                    isCurrent: false,
                    email: "member@example.com",
                    teamName: "workspace",
                    fiveHourUsed: 45,
                    oneWeekUsed: 55
                )
            ],
            usageProgressDisplayMode: .used,
            locale: Locale(identifier: "zh-Hans"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].workspaceLabel == "workspace")
        #expect(snapshot.rows[0].accountLabel == "member")
        #expect(snapshot.rows[0].oneWeek.remainingText == "45%")
    }

    @Test
    func resetTimeUsesStableWidgetFormat() {
        let builder = AccountsWidgetSnapshotBuilder()
        let snapshot = builder.build(
            accounts: [
                account(
                    id: "current",
                    isCurrent: true,
                    email: "current@example.com",
                    fiveHourUsed: 12,
                    oneWeekUsed: 34,
                    fiveHourResetAt: 1_774_020_225,
                    oneWeekResetAt: 1_774_106_625
                )
            ],
            usageProgressDisplayMode: .used,
            locale: Locale(identifier: "zh-Hans"),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.currentCard?.oneWeek.resetText == "26/3/21 23:23:45")
    }

    @Test
    func defaultBuilderLimitsLargeRowsToFourAccounts() {
        let builder = AccountsWidgetSnapshotBuilder()
        let snapshot = builder.build(
            accounts: [
                account(id: "current", isCurrent: true, email: "current@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
                account(id: "a", isCurrent: false, email: "a@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
                account(id: "b", isCurrent: false, email: "b@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
                account(id: "c", isCurrent: false, email: "c@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
                account(id: "d", isCurrent: false, email: "d@example.com", fiveHourUsed: 10, oneWeekUsed: 20),
            ],
            usageProgressDisplayMode: .used,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.rows.count == 4)
    }

    @Test
    func snapshotCarriesUsageProgressDisplayMode() {
        let builder = AccountsWidgetSnapshotBuilder()
        let snapshot = builder.build(
            accounts: [
                account(id: "current", isCurrent: true, email: "current@example.com", fiveHourUsed: 12, oneWeekUsed: 34)
            ],
            usageProgressDisplayMode: .remaining,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.usageProgressDisplayMode == .remaining)
        #expect(snapshot.currentCard?.oneWeek.usedText == "34%")
        #expect(snapshot.currentCard?.oneWeek.remainingText == "66%")
    }

    private func account(
        id: String,
        isCurrent: Bool,
        email: String,
        teamName: String? = nil,
        fiveHourUsed: Double,
        oneWeekUsed: Double,
        fiveHourResetAt: Int64 = 1_774_020_225,
        oneWeekResetAt: Int64 = 1_774_106_625
    ) -> AccountSummary {
        AccountSummary(
            id: id,
            label: id,
            email: email,
            accountID: id,
            planType: "team",
            teamName: teamName,
            teamAlias: nil,
            addedAt: 0,
            updatedAt: 0,
            usage: UsageSnapshot(
                fetchedAt: 0,
                planType: "team",
                fiveHour: UsageWindow(usedPercent: fiveHourUsed, windowSeconds: 18_000, resetAt: fiveHourResetAt),
                oneWeek: UsageWindow(usedPercent: oneWeekUsed, windowSeconds: 604_800, resetAt: oneWeekResetAt),
                credits: nil
            ),
            usageError: nil,
            isCurrent: isCurrent
        )
    }
}
