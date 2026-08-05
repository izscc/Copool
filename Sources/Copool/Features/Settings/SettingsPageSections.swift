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
            Form {
                SettingsGeneralSection(model: model)
                SettingsLanguageSection(model: model)
                SettingsSwitchBehaviorSection(model: model)
                SettingsDoctorSection(model: model)
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)

            SettingsQuitFooter(onQuit: model.quitApp)
        }
        .task {
            await model.loadIfNeeded()
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
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                            .font(.caption)
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
