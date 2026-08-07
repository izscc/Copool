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
            CapsuleSubTabBar(
                selection: $model.subTab,
                tabs: SettingsSubTab.allCases.map { ($0, $0.label) }
            )
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

                // 导出放在诊断结果之后：用户先看结果，看不懂才需要把它交给别人。
                // 这个顺序也保证了导出时 `doctorChecks` 已经有内容。
                HStack(spacing: 8) {
                    Button(L10n.tr("settings.support_bundle.export")) {
                        model.exportSupportBundle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isExportingSupportBundle)

                    #if os(macOS)
                    // 只有 macOS 有访达。iOS 上支持包同样会写到应用支持目录，
                    // 但那里没有可以"揭示"给用户的文件浏览器，按钮就不出现。
                    if let url = model.supportBundleURL {
                        Button(L10n.tr("settings.support_bundle.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    #endif
                }
                Text(L10n.tr("settings.support_bundle.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            migrationRow
        }
        .onAppear { model.reloadMigrationState() }
    }

    /// 迁移状态与回滚（AC-004）。
    ///
    /// 从没迁移过就整行不出现：v1-only 的用户看到一个"未迁移"的空状态，
    /// 只会以为自己少做了一步，而实际上什么都不需要做。
    @ViewBuilder
    private var migrationRow: some View {
        if let entry = model.lastMigration {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.tr("settings.migration.title"))
                        .font(.caption)
                    Spacer(minLength: 0)
                    Text(migrationStatusText(entry))
                        .font(.caption2)
                        .foregroundStyle(entry.rolledBack == true ? Color.secondary : (entry.verified ? Color.green : Color.orange))
                }
                Text(L10n.tr(
                    "settings.migration.versions_format",
                    String(entry.fromVersion),
                    String(entry.toVersion)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                // 已回滚的记录不再给回滚按钮：再点一次是无操作，但按钮存在本身
                // 会让用户以为还有什么没做完。
                if entry.rolledBack != true {
                    Button(L10n.tr("settings.migration.rollback")) {
                        model.rollbackMigration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRollingBackMigration)
                    Text(L10n.tr("settings.migration.rollback_help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func migrationStatusText(_ entry: MigrationEntry) -> String {
        if entry.rolledBack == true { return L10n.tr("settings.migration.status.rolled_back") }
        if entry.verified { return L10n.tr("settings.migration.status.verified") }
        return L10n.tr("settings.migration.status.unverified")
    }
}
