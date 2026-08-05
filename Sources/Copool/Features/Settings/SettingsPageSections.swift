import SwiftUI

struct SettingsPageContent: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        #if os(macOS)
        MacSettingsPageContent(model: model)
        #else
        IOSSettingsPageContent(model: model)
        #endif
    }
}

#if os(macOS)
private struct MacSettingsPageContent: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.subTab) {
                ForEach(SettingsSubTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, LayoutRules.pagePadding)
            .padding(.top, LayoutRules.pagePadding)

            Form {
                switch model.subTab {
                case .general:
                    SettingsGeneralSection(model: model)
                    SettingsLanguageSection(model: model)
                    SettingsSwitchBehaviorSection(model: model)
                case .security:
                    SettingsSecuritySection(model: model)
                case .diagnostics:
                    SettingsDoctorSection(model: model)
                case .advanced:
                    SettingsAdvancedSection(model: model)
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            SettingsQuitFooter(onQuit: model.quitApp)
        }
        .task {
            await model.loadIfNeeded()
            model.probeLoginOptionalState()
        }
    }
}

/// Security sub-tab: secret storage posture (AC-003) and file permissions.
private struct SettingsSecuritySection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section(L10n.tr("settings.section.security")) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.green)
                Text(L10n.tr("settings.security.keychain"))
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Image(systemName: model.providerStorePermissionsOK ? "checkmark.shield" : "xmark.shield")
                    .foregroundStyle(model.providerStorePermissionsOK ? .green : .red)
                Text(L10n.tr("settings.security.provider_permissions"))
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
                Text(L10n.tr("settings.security.no_secrets_in_domain"))
                    .font(.caption)
            }
        }
    }
}

/// Advanced sub-tab: AC-105 external-model mode and expert notes.
private struct SettingsAdvancedSection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section(L10n.tr("settings.section.advanced")) {
            Toggle(L10n.tr("settings.advanced.login_optional"), isOn: Binding(
                get: { model.loginOptionalEnabled },
                set: { model.setLoginOptional($0) }
            ))
            .font(.caption)
            Text(L10n.tr("settings.advanced.login_optional_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L10n.tr("settings.advanced.expert_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsGeneralSection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section("settings.section.general") {
            SettingsToggleRows(
                descriptors: model.generalSectionPresentation.toggles,
                onChange: model.updateToggle
            )

            if let usageProgressDisplayPicker = model.generalSectionPresentation.usageProgressDisplayPicker {
                SettingsPickerRow(
                    descriptor: usageProgressDisplayPicker,
                    onSelect: model.updateUsageProgressDisplayMode
                )
            }
        }
    }
}

private struct SettingsSwitchBehaviorSection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section("settings.section.switch_behavior") {
            SettingsToggleRows(
                descriptors: model.switchBehaviorSectionPresentation.toggles,
                onChange: model.updateToggle
            )

            SettingsPickerRow(
                descriptor: model.switchBehaviorSectionPresentation.restartEditorTargetPicker,
                onSelect: model.updateRestartEditorTarget
            )
        }
    }
}

private struct SettingsQuitFooter: View {
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: LayoutRules.listRowSpacing) {
            Spacer(minLength: 0)

            Button(role: .destructive) {
                onQuit()
            } label: {
                Text("common.quit")
            }
            .buttonStyle(.frostedCapsule(prominent: true, tint: .red))
        }
        .padding(.horizontal, LayoutRules.pagePadding)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}
#endif

private struct IOSSettingsPageContent: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Form {
            SettingsLanguageSection(model: model)
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
        .task {
            await model.loadIfNeeded()
        }
    }
}

private struct SettingsLanguageSection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section("settings.section.language") {
            SettingsPickerRow(
                descriptor: model.languageSectionPresentation.picker,
                onSelect: model.updateLocale
            )
        }
    }
}

/// One-shot environment diagnosis (codex-router's `doctor`, adapted).
private struct SettingsDoctorSection: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        Section("settings.section.doctor") {
            if model.doctorChecks.isEmpty {
                HStack {
                    Text(L10n.tr("settings.doctor.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.tr("settings.doctor.run")) {
                        model.runDoctor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRunningDoctor)
                }
            } else {
                ForEach(model.doctorChecks) { check in
                    HStack(spacing: 8) {
                        switch check.severity {
                        case .pass:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .warn:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        case .fail:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name)
                                .font(.caption)
                            if let message = check.message {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Button(L10n.tr("settings.doctor.rerun")) {
                    model.runDoctor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isRunningDoctor)
            }
        }
    }
}
