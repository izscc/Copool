import SwiftUI

extension ProviderPageView {

    /// 顶部摘要条的数据投影（B2）。聚合纯函数在 Domain 层，这里只取投影——
    /// 视图不直接碰 Infrastructure，只读 page model 的 @Published 属性。
    var statusSummary: ProviderStatusSummary {
        ProviderStatusSummary.build(
            splitState: model.splitState,
            groups: model.providerGroups,
            latestTrace: model.recentRouteDecisions.first
        )
    }

    var providersContent: some View {
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            // 内置注册表（M1）在最前：23 家 provider 填一把 Key 就能用，
            // 这是绝大多数用户唯一需要碰的地方。下面的自定义端点是长尾。
            ProviderRegistrySection(
                groups: model.providerGroups,
                seedError: model.registrySeedError,
                onConfigure: { model.beginConfiguringCredential($0) },
                onRevoke: { model.revokeCredential(for: $0) }
            )

            // 引导页只在**注册表和自定义端点都为空**时出现。只看 v1 列表的话，
            // 已经在注册表里配好 Key 的用户还是会被当成新用户来引导。
            if model.providers.isEmpty && !hasAnyConfiguredCredential {
                ProviderOnboardingSection(
                    onDetectSubscriptions: {
                        model.detectSubscriptions()
                    },
                    isDetecting: model.isDetectingSubscriptions
                )
            } else if !model.providers.isEmpty {
                HStack {
                    Text(L10n.tr("providers.list.title"))
                        .font(.headline)
                    Spacer(minLength: 0)
                    Button {
                        model.detectSubscriptions()
                    } label: {
                        if model.isDetectingSubscriptions {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.tr("providers.import.detect"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.frostedCapsule(prominent: false))
                    .disabled(model.isDetectingSubscriptions)
                }
                .padding(.horizontal, LayoutRules.pagePadding)
            }

            if !model.detectedSubscriptions.isEmpty {
                SubscriptionImportSection(
                    subscriptions: model.detectedSubscriptions,
                    importedNames: Set(model.providers.map { $0.name.lowercased() }),
                    onImport: { model.importSubscription($0) }
                )
            }

            if !model.providers.isEmpty {
                ProviderListSection(
                    providers: model.providers,
                    refreshingIDs: model.refreshingProviderIDs,
                    testResults: model.modelTestResults,
                    testingKeys: model.testingModelKeys,
                    rateLimits: model.rateLimits,
                    accountUsage: model.accountUsage,
                    usageAggregates: model.usageAggregates,
                    discoverableModels: model.discoverableModels,
                    discoveringModelIDs: model.discoveringModelIDs,
                    onEdit: { model.beginEditingProvider($0) },
                    onRefreshAuth: { model.refreshProviderAuth($0) },
                    onDelete: { model.removeProvider($0) },
                    onTestModel: { providerID, modelID in
                        Task { await model.testModel(providerID: providerID, modelID: modelID) }
                    },
                    onTestAll: { providerID in
                        Task { await model.testAllModels(providerID: providerID) }
                    },
                    onDiscoverModels: { providerID in
                        await model.discoverModels(providerID: providerID)
                    },
                    onAddModel: { providerID, modelID in
                        model.addDiscoveredModel(providerID: providerID, modelID: modelID)
                    }
                )
            }

            if !model.providerForm.id.isEmpty || model.providerForm.name.isEmpty {
                ProviderFormCard(
                    draft: model.providerForm,
                    isTesting: model.isTestingProviderConnection,
                    testResult: model.providerConnectionTestResult,
                    onDraftChange: { model.providerForm = $0 },
                    onSave: { model.saveProviderForm() },
                    onTest: {
                        Task { await model.testProviderConnection() }
                    },
                    onCancel: {
                        model.providerForm = .empty
                        model.providerConnectionTestResult = nil
                    }
                )
                .padding(.horizontal, LayoutRules.pagePadding)
            } else {
                // 自定义端点是长尾能力，入口收在注册表下方而不是抢在前面。
                Button(L10n.tr("providers.add_custom")) {
                    model.beginEditingProvider(ProviderConfig(name: "", baseURL: "", apiKey: ""))
                }
                .copoolActionButtonStyle(prominent: false, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
                .padding(.horizontal, LayoutRules.pagePadding)
            }
        }
        .padding(.vertical, LayoutRules.pagePadding)
        .task {
            model.loadProviders()
            model.loadProviderGroups()
            model.refreshCredentialHealth()
            model.detectSubscriptionsIfNeeded()
        }
    }

    var hasAnyConfiguredCredential: Bool {
        model.providerGroups.contains { $0.health != .unconfigured }
    }
}

/// Onboarding hero shown when no providers are configured yet.
struct ProviderOnboardingSection: View {
    let onDetectSubscriptions: () -> Void
    let isDetecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("providers.onboarding.title"))
                .font(.title2.weight(.bold))

            Text(L10n.tr("providers.onboarding.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                onboardingStep(1, L10n.tr("providers.onboarding.step1"))
                onboardingStep(2, L10n.tr("providers.onboarding.step2"))
                onboardingStep(3, L10n.tr("providers.onboarding.step3"))
            }

            Button(action: onDetectSubscriptions) {
                if isDetecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(L10n.tr("providers.import.detect"), systemImage: "macwindow.badge.plus")
                }
            }
            .copoolActionButtonStyle(prominent: true, tint: .indigo, density: .regular, iOSStyle: .liquidGlass)
            .disabled(isDetecting)
        }
        .padding(16)
        .frostedRoundedSurface(cornerRadius: 14, prominent: true, tint: .indigo.opacity(0.15))
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private func onboardingStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Color.indigo.opacity(0.2), in: Circle())
                .foregroundStyle(.indigo)
            Text(text)
                .font(.subheadline)
        }
    }
}

/// Local subscription login import cards.
struct SubscriptionImportSection: View {
    let subscriptions: [ImportedSubscription]
    let importedNames: Set<String>
    let onImport: (ImportedSubscription) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("providers.import.title"))
                .font(.headline)

            ForEach(subscriptions, id: \.providerName) { subscription in
                let isImported = importedNames.contains(subscription.providerName.lowercased())
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(subscription.baseURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(subscription.modelIDs.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(isImported
                           ? L10n.tr("providers.refresh_auth")
                           : L10n.tr("providers.import.action")) {
                        onImport(subscription)
                    }
                    .copoolActionButtonStyle(prominent: true, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
                }
                .padding(12)
                .frostedRoundedSurface(cornerRadius: 12, prominent: false)
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }
}

/// One-tap provider presets.
struct ProviderPresetSection: View {
    let presets: [ProviderPreset]
    let onApply: (ProviderPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("providers.preset.title"))
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        onApply(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(preset.protocolKind.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .frostedRoundedSurface(cornerRadius: 10, prominent: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }
}

/// Configured provider rows.
struct ProviderListSection: View {
    let providers: [ProviderConfig]
    let refreshingIDs: Set<String>
    let testResults: [String: ModelTestResult]
    let testingKeys: Set<String>
    let rateLimits: [String: ProviderRateLimitSnapshot]
    let accountUsage: [String: ProviderAccountUsage]
    let usageAggregates: [DailyUsageAggregate]
    let discoverableModels: [String: [String]]
    let discoveringModelIDs: Set<String>
    let onEdit: (ProviderConfig) -> Void
    let onRefreshAuth: (ProviderConfig) -> Void
    let onDelete: (ProviderConfig) -> Void
    let onTestModel: (String, String) -> Void
    let onTestAll: (String) -> Void
    let onDiscoverModels: (String) async -> Void
    let onAddModel: (String, String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(provider.name)
                                    .font(.subheadline.weight(.semibold))
                                AccountTagView(
                                    text: provider.defaultProtocol.displayName,
                                    backgroundColor: Color.teal.opacity(0.16),
                                    foregroundColor: .teal
                                )
                            }
                            Text(provider.baseURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if provider.supportsSubscriptionRefresh {
                            Button {
                                onRefreshAuth(provider)
                            } label: {
                                if refreshingIDs.contains(provider.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.frostedCapsule(prominent: false))
                            .disabled(refreshingIDs.contains(provider.id))
                            .accessibilityLabel(L10n.tr("providers.refresh_auth"))
                        }
                        Button(L10n.tr("common.edit")) {
                            onEdit(provider)
                        }
                        .buttonStyle(.frostedCapsule(prominent: false))
                        Button(role: .destructive) {
                            onDelete(provider)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.frostedCapsule(prominent: true, tint: .red))
                    }

                    if !provider.models.isEmpty {
                        Divider().opacity(0.4)
                        HStack {
                            Text(L10n.tr("providers.models.title"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(L10n.tr("providers.models.test_all")) {
                                onTestAll(provider.id)
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        }
                        ForEach(provider.models, id: \.id) { model in
                            ProviderModelRow(
                                model: model,
                                result: testResults[ProviderPageModel.modelKey(providerID: provider.id, modelID: model.id)],
                                isTesting: testingKeys.contains(
                                    ProviderPageModel.modelKey(providerID: provider.id, modelID: model.id)
                                ),
                                onTest: { onTestModel(provider.id, model.id) }
                            )
                        }
                    }

                    ProviderUsageBlock(
                        rateLimit: rateLimits[provider.id],
                        accountUsage: accountUsage[provider.id],
                        aggregates: usageAggregates.filter { $0.providerID == provider.id }
                    )

                    ProviderCurationSection(
                        providerID: provider.id,
                        candidates: discoverableModels[provider.id] ?? [],
                        hasDiscovered: discoverableModels.keys.contains(provider.id),
                        isDiscovering: discoveringModelIDs.contains(provider.id),
                        onDiscover: { Task { await onDiscoverModels(provider.id) } },
                        onAdd: { onAddModel(provider.id, $0) }
                    )
                }
                .padding(12)
                .frostedRoundedSurface(cornerRadius: 12, prominent: false)
            }

            Button(L10n.tr("providers.add")) {
                onEdit(ProviderConfig(name: "", baseURL: "", apiKey: ""))
            }
            .copoolActionButtonStyle(prominent: false, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
            .padding(.top, 4)
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }
}

/// One model with its capability summary and last probe result.
struct ProviderModelRow: View {
    let model: ProviderModel
    let result: ModelTestResult?
    let isTesting: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.id)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = result?.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(result?.isOK == true ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let capability = capabilitySummary {
                    Text(capability)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(L10n.tr("providers.models.test")) {
                onTest()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.tint)
            .disabled(isTesting)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isTesting {
            ProgressView().controlSize(.mini)
        } else if let result {
            Image(systemName: result.isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(result.isOK ? Color.green : Color.orange)
        } else {
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Shows discovered capabilities so the user can tell a real 1M window
    /// from the conservative default.
    private var capabilitySummary: String? {
        guard let contextWindow = model.contextWindow else { return nil }
        let thousands = contextWindow / 1000
        let window = thousands >= 1000
            ? String(format: "%.1fM", Double(contextWindow) / 1_000_000)
            : "\(thousands)K"
        let efforts = model.supportedReasoningEfforts
        guard let efforts, !efforts.isEmpty else { return window }
        return "\(window) · \(efforts.joined(separator: "/"))"
    }
}

/// Add/edit provider form.
struct ProviderFormCard: View {
    let draft: ProviderFormDraft
    let isTesting: Bool
    let testResult: String?
    let onDraftChange: (ProviderFormDraft) -> Void
    let onSave: () -> Void
    let onTest: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("settings.providers.form.title"))
                .font(.subheadline.weight(.semibold))

            TextField(L10n.tr("settings.providers.form.name"), text: binding(\.name))
                .textFieldStyle(.roundedBorder)
            TextField(L10n.tr("settings.providers.form.base_url"), text: binding(\.baseURL))
                .textFieldStyle(.roundedBorder)
            TextField(L10n.tr("settings.providers.form.api_key"), text: binding(\.apiKey))
                .textFieldStyle(.roundedBorder)
            TextField(L10n.tr("settings.providers.form.models"), text: binding(\.modelListText))
                .textFieldStyle(.roundedBorder)

            Picker(L10n.tr("settings.providers.form.protocol"), selection: binding(\.protocolMode)) {
                Text("OpenAI Chat").tag(ProviderProtocol.chat.rawValue)
                Text("Responses").tag(ProviderProtocol.responses.rawValue)
                Text("Anthropic").tag(ProviderProtocol.anthropic.rawValue)
                Text("Google Gemini").tag(ProviderProtocol.google.rawValue)
            }
            .pickerStyle(.segmented)

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? .green : .secondary)
            }

            HStack {
                Button(isTesting ? L10n.tr("common.testing") : L10n.tr("settings.providers.test")) {
                    onTest()
                }
                .disabled(isTesting)

                Button(L10n.tr("settings.providers.save")) {
                    onSave()
                }
                .buttonStyle(.frostedCapsule(prominent: true, tint: .indigo))

                Spacer(minLength: 0)

                Button(L10n.tr("common.cancel")) {
                    onCancel()
                }
            }
        }
        .padding(12)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
    }

    private func binding(_ keyPath: WritableKeyPath<ProviderFormDraft, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                var updated = draft
                updated[keyPath: keyPath] = newValue
                onDraftChange(updated)
            }
        )
    }
}

/// Rate-limit / account-usage / token-trend block inside one provider card.
///
/// Rate-limit facts are harvested passively from response headers, account
/// usage comes from the vendor APIs, and the token trend comes from the local
/// usage ledger — the three surfaces codex-router's tray shows for a provider.
struct ProviderUsageBlock: View {
    let rateLimit: ProviderRateLimitSnapshot?
    let accountUsage: ProviderAccountUsage?
    let aggregates: [DailyUsageAggregate]

    private var hasAnything: Bool {
        rateLimit != nil || accountUsage?.metrics.isEmpty == false || !aggregates.isEmpty
    }

    var body: some View {
        if hasAnything {
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("providers.usage.title"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let accountUsage, !accountUsage.metrics.isEmpty {
                    ForEach(accountUsage.metrics) { metric in
                        HStack(spacing: 8) {
                            if let usedPercent = metric.usedPercent {
                                QuotaBar(usedPercent: usedPercent)
                                    .frame(width: 90)
                                Text(metric.label)
                                    .font(.caption2)
                                Spacer(minLength: 0)
                                if let detail = metric.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let value = metric.value {
                                Text(metric.label)
                                    .font(.caption2)
                                Spacer(minLength: 0)
                                Text(String(format: "%.2f %@", value, metric.currency ?? ""))
                                    .font(.caption2.weight(.medium))
                            }
                        }
                    }
                }

                if let rateLimit {
                    RateLimitLine(label: "Requests", window: rateLimit.requests)
                    RateLimitLine(label: "Tokens", window: rateLimit.tokens)
                }

                if !aggregates.isEmpty {
                    let today = aggregates.first
                    HStack(spacing: 8) {
                        Text(L10n.tr("providers.usage.tokens_today"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("\(today?.totalTokens ?? 0)")
                            .font(.caption2.weight(.medium))
                    }
                }
            }
        }
    }
}

struct RateLimitLine: View {
    let label: String
    let window: RateLimitWindow?

    var body: some View {
        if let window, window.limit != nil || window.remaining != nil {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let remaining = window.remaining, let limit = window.limit, limit > 0 {
                    Text("\(remaining)/\(limit)")
                        .font(.caption2.weight(.medium))
                    if remaining == 0, let resetAt = window.resetAt {
                        Text(L10n.tr("providers.usage.reset_at_format", Self.relativeTime(resetAt)))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                } else if let remaining = window.remaining {
                    Text(L10n.tr("providers.usage.remaining_left_format", String(remaining)))
                        .font(.caption2)
                } else if let resetAt = window.resetAt {
                    Text(L10n.tr("providers.usage.reset_at_format", Self.relativeTime(resetAt)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func relativeTime(_ epochSeconds: Int64) -> String {
        let interval = epochSeconds - Int64(Date().timeIntervalSince1970)
        if interval <= 0 { return "now" }
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h"
    }
}

/// Thin horizontal quota bar (used portion filled).
struct QuotaBar: View {
    let usedPercent: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(usedPercent > 85 ? Color.red : (usedPercent > 60 ? Color.orange : Color.teal))
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, usedPercent / 100))))
            }
        }
        .frame(height: 6)
    }
}

/// "Discover models this provider advertises but you haven't added" —
/// the curation affordance ported from codex-router's `curate-models`.
struct ProviderCurationSection: View {
    let providerID: String
    let candidates: [String]
    let hasDiscovered: Bool
    let isDiscovering: Bool
    let onDiscover: () -> Void
    let onAdd: (String) -> Void

    var body: some View {
        if isDiscovering {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.tr("providers.curate.discovering"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("providers.curate.title"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(candidates.prefix(8), id: \.self) { modelID in
                    HStack(spacing: 8) {
                        Text(modelID)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(L10n.tr("providers.curate.add")) {
                            onAdd(modelID)
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    }
                }
                if candidates.count > 8 {
                    Text(L10n.tr("providers.curate.more_format", String(candidates.count - 8)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if hasDiscovered {
            Text(L10n.tr("providers.curate.none_found"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Button(L10n.tr("providers.curate.discover")) {
                onDiscover()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.tint)
        }
    }
}
