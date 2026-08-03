import XCTest
@testable import Copool

final class SettingsControlPresentationTests: XCTestCase {
    func testSwitchBehaviorSectionDisablesRestartTargetPickerWhenSwitchingIsOff() {
        let presentation = SettingsControlPresentation.switchBehaviorSection(
            settings: AppSettings.defaultValue,
            installedEditorApps: [
                InstalledEditorApp(id: .cursor, label: "Cursor")
            ]
        )

        XCTAssertEqual(
            presentation.toggles.map(\.intent),
            [.autoSmartSwitch, .syncOpencodeOpenaiAuth, .restartEditorsOnSwitch]
        )
        XCTAssertFalse(presentation.restartEditorTargetPicker.isEnabled)
        XCTAssertEqual(
            presentation.restartEditorTargetPicker.options.map(\.title),
            [L10n.tr("common.none"), "Cursor"]
        )
    }

    func testGeneralSectionIncludesUsageProgressDisplayPicker() {
        let presentation = SettingsControlPresentation.generalSection(
            settings: AppSettings.defaultValue
        )

        XCTAssertEqual(
            presentation.usageProgressDisplayPicker?.selectedValue,
            .used
        )
        XCTAssertEqual(
            presentation.usageProgressDisplayPicker?.options.map(\.value),
            [.used, .remaining]
        )
    }

    func testSwitchBehaviorSectionEnablesRestartTargetPickerWhenConfigured() {
        let settings = AppSettings(
            launchAtStartup: false,
            launchChatGPTAfterSwitch: true,
            autoSmartSwitch: true,
            syncOpencodeOpenaiAuth: true,
            localProxyHostAPIOnly: true,
            restartEditorsOnSwitch: true,
            restartEditorTargets: [.vscode],
            autoStartApiProxy: false,
            proxyConfiguration: .defaultValue,
            remoteServers: [],
            usageProgressDisplayMode: .used,
            locale: AppLocale.english.identifier
        )

        let presentation = SettingsControlPresentation.switchBehaviorSection(
            settings: settings,
            installedEditorApps: [
                InstalledEditorApp(id: .vscode, label: "VS Code")
            ]
        )

        XCTAssertTrue(presentation.restartEditorTargetPicker.isEnabled)
        XCTAssertEqual(
            presentation.restartEditorTargetPicker.selectedValue,
            EditorAppID?.some(.vscode)
        )
    }

    func testLanguageSectionNormalizesSelectedLocale() {
        let settings = AppSettings(
            launchAtStartup: false,
            launchChatGPTAfterSwitch: true,
            autoSmartSwitch: false,
            syncOpencodeOpenaiAuth: false,
            localProxyHostAPIOnly: false,
            restartEditorsOnSwitch: false,
            restartEditorTargets: [],
            autoStartApiProxy: false,
            proxyConfiguration: .defaultValue,
            remoteServers: [],
            usageProgressDisplayMode: .used,
            locale: "zh_CN"
        )

        let presentation = SettingsControlPresentation.languageSection(settings: settings)

        XCTAssertEqual(presentation.picker.selectedValue, .simplifiedChinese)
        XCTAssertEqual(presentation.picker.options.count, AppLocale.allCases.count)
    }

}
