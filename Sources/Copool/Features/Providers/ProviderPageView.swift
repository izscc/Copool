import SwiftUI

/// Third-party model management page: onboarding, local subscription import,
/// provider presets, and the provider list.
struct ProviderPageView: View {
    @ObservedObject var model: ProviderPageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                if model.providers.isEmpty {
                    ProviderOnboardingSection(
                        onDetectSubscriptions: {
                            model.detectSubscriptions()
                        },
                        isDetecting: model.isDetectingSubscriptions
                    )
                } else {
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

                if model.providers.isEmpty {
                    ProviderPresetSection(
                        presets: ProviderPreset.all,
                        onApply: { model.applyPreset($0) }
                    )
                }

                if !model.providers.isEmpty {
                    ProviderListSection(
                        providers: model.providers,
                        refreshingIDs: model.refreshingProviderIDs,
                        onEdit: { model.beginEditingProvider($0) },
                        onRefreshAuth: { model.refreshProviderAuth($0) },
                        onDelete: { model.removeProvider($0) }
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
                }
            }
            .padding(.vertical, LayoutRules.pagePadding)
        }
        .task {
            model.loadProviders()
            model.detectSubscriptionsIfNeeded()
        }
    }
}

/// Onboarding hero shown when no providers are configured yet.
private struct ProviderOnboardingSection: View {
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
private struct SubscriptionImportSection: View {
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
private struct ProviderPresetSection: View {
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
private struct ProviderListSection: View {
    let providers: [ProviderConfig]
    let refreshingIDs: Set<String>
    let onEdit: (ProviderConfig) -> Void
    let onRefreshAuth: (ProviderConfig) -> Void
    let onDelete: (ProviderConfig) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(providers) { provider in
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
                        Text(provider.models.map(\.id).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

/// Add/edit provider form.
private struct ProviderFormCard: View {
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
