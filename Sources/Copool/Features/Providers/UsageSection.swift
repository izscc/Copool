import SwiftUI

/// Usage aggregate across providers (rate limits, balances, token trend).
struct UsageSection: View {
    let rateLimits: [String: ProviderRateLimitSnapshot]
    let accountUsage: [String: ProviderAccountUsage]
    let aggregates: [DailyUsageAggregate]

    private var hasAccountMetrics: Bool {
        accountUsage.values.contains { !$0.metrics.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.listRowSpacing) {
            Text(L10n.tr("models.tab.usage"))
                .font(.headline)
            if aggregates.isEmpty && rateLimits.isEmpty && !hasAccountMetrics {
                EmptyStateView(
                    title: L10n.tr("models.tab.usage"),
                    message: L10n.tr("models.usage.empty")
                )
            } else {
                ForEach(aggregates.prefix(7), id: \.id) { row in
                    HStack(spacing: LayoutRules.listRowSpacing) {
                        Text(row.day)
                            .font(.caption2)
                        Text(row.providerID.prefix(8))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(L10n.tr("providers.usage.row_format", String(row.requests), String(row.totalTokens)))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                if !accountUsage.isEmpty {
                    Text(L10n.tr("providers.usage.title"))
                        .font(.caption2.weight(.semibold))
                        .padding(.top, LayoutRules.accountCardTightSpacing)
                    ForEach(Array(accountUsage.keys.sorted()), id: \.self) { providerID in
                        if let usage = accountUsage[providerID], !usage.metrics.isEmpty {
                            VStack(alignment: .leading, spacing: LayoutRules.accountCardItemSpacing) {
                                Text(providerID)
                                    .font(.caption2.weight(.medium))
                                ForEach(usage.metrics) { metric in
                                    HStack(spacing: LayoutRules.listRowSpacing) {
                                        if let usedPercent = metric.usedPercent {
                                            QuotaBar(usedPercent: usedPercent)
                                                .frame(width: 90)
                                        }
                                        Text(metric.label)
                                            .font(.caption2)
                                        Spacer(minLength: 0)
                                        if let value = metric.value {
                                            Text(String(format: "%.2f %@", value, metric.currency ?? ""))
                                                .font(.caption2.weight(.medium))
                                                .monospacedDigit()
                                        } else if let detail = metric.detail {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if !rateLimits.isEmpty {
                    Text(L10n.tr("models.usage.ratelimits"))
                        .font(.caption2.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(Array(rateLimits.keys.sorted()), id: \.self) { providerID in
                        if let snapshot = rateLimits[providerID] {
                            HStack(spacing: 8) {
                                Text(providerID.prefix(8))
                                    .font(.caption2)
                                Spacer(minLength: 0)
                                if let remaining = snapshot.requests?.remaining {
                                    Text(L10n.tr("providers.usage.requests_format", String(remaining)))
                                        .font(.caption2)
                                        .monospacedDigit()
                                }
                                if let remaining = snapshot.tokens?.remaining {
                                    Text(L10n.tr("providers.usage.tokens_format", String(remaining)))
                                        .font(.caption2)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }
}
