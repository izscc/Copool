import XCTest
@testable import Copool

final class AppSettingsCodableTests: XCTestCase {
    func testEncodingUsesChatGPTLaunchKeyAndReadsLegacyCodexKey() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaultValue)
        let encodedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(encodedObject["launchChatGPTAfterSwitch"] as? Bool, true)
        XCTAssertNil(encodedObject["launchCodexAfterSwitch"])

        let legacyJSON = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "launchChatGPTAfterSwitch",
                with: "launchCodexAfterSwitch"
            ).data(using: .utf8)
        )
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)

        XCTAssertTrue(decodedLegacy.launchChatGPTAfterSwitch)

        var disabledSettings = AppSettings.defaultValue
        disabledSettings.launchChatGPTAfterSwitch = false
        let disabledEncoded = try JSONEncoder().encode(disabledSettings)
        let disabledLegacyJSON = try XCTUnwrap(
            String(data: disabledEncoded, encoding: .utf8)?.replacingOccurrences(
                of: "launchChatGPTAfterSwitch",
                with: "launchCodexAfterSwitch"
            ).data(using: .utf8)
        )
        let decodedDisabledLegacy = try JSONDecoder().decode(AppSettings.self, from: disabledLegacyJSON)

        XCTAssertFalse(decodedDisabledLegacy.launchChatGPTAfterSwitch)
    }

    func testDecodeSettingsRequiresFullCurrentShape() throws {
        let json = """
        {
          "launchAtStartup": true,
          "launchCodexAfterSwitch": true,
          "autoSmartSwitch": false,
          "syncOpencodeOpenaiAuth": false
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)))
    }

    func testDecodeSettingsWithoutUsageProgressDisplayModeDefaultsToUsed() throws {
        let json = """
        {
          "launchAtStartup": true,
          "launchCodexAfterSwitch": true,
          "autoSmartSwitch": false,
          "syncOpencodeOpenaiAuth": false,
          "localProxyHostAPIOnly": false,
          "restartEditorsOnSwitch": false,
          "restartEditorTargets": [],
          "autoStartApiProxy": false,
          "proxyConfiguration": {
            "preferredPortText": "4141",
            "cloudflared": {
              "enabled": false,
              "tunnelMode": "quick",
              "useHTTP2": false,
              "namedHostname": ""
            }
          },
          "remoteServers": [],
          "locale": "en"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.usageProgressDisplayMode, .used)
    }
}
