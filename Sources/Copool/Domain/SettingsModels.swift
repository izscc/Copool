import Foundation

enum UsageProgressDisplayMode: String, Codable, Equatable, CaseIterable, Sendable {
    case used
    case remaining

    var localizationKey: String {
        switch self {
        case .used:
            return "settings.usage_progress_display.used"
        case .remaining:
            return "settings.usage_progress_display.remaining"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var launchAtStartup: Bool
    var launchChatGPTAfterSwitch: Bool
    var autoSmartSwitch: Bool
    var syncOpencodeOpenaiAuth: Bool
    var localProxyHostAPIOnly: Bool
    var restartEditorsOnSwitch: Bool
    var restartEditorTargets: [EditorAppID]
    var autoStartApiProxy: Bool
    var proxyConfiguration: ProxyConfiguration
    var remoteServers: [RemoteServerConfig]
    var usageProgressDisplayMode: UsageProgressDisplayMode
    var locale: String

    enum CodingKeys: String, CodingKey {
        case launchAtStartup
        case launchChatGPTAfterSwitch
        case legacyLaunchCodexAfterSwitch = "launchCodexAfterSwitch"
        case autoSmartSwitch
        case syncOpencodeOpenaiAuth
        case localProxyHostAPIOnly
        case restartEditorsOnSwitch
        case restartEditorTargets
        case autoStartApiProxy
        case proxyConfiguration
        case remoteServers
        case usageProgressDisplayMode
        case locale
    }

    init(
        launchAtStartup: Bool,
        launchChatGPTAfterSwitch: Bool,
        autoSmartSwitch: Bool,
        syncOpencodeOpenaiAuth: Bool,
        localProxyHostAPIOnly: Bool = false,
        restartEditorsOnSwitch: Bool,
        restartEditorTargets: [EditorAppID],
        autoStartApiProxy: Bool,
        proxyConfiguration: ProxyConfiguration = .defaultValue,
        remoteServers: [RemoteServerConfig],
        usageProgressDisplayMode: UsageProgressDisplayMode = .used,
        locale: String
    ) {
        self.launchAtStartup = launchAtStartup
        self.launchChatGPTAfterSwitch = launchChatGPTAfterSwitch
        self.autoSmartSwitch = autoSmartSwitch
        self.syncOpencodeOpenaiAuth = syncOpencodeOpenaiAuth
        self.localProxyHostAPIOnly = localProxyHostAPIOnly
        self.restartEditorsOnSwitch = restartEditorsOnSwitch
        self.restartEditorTargets = restartEditorTargets
        self.autoStartApiProxy = autoStartApiProxy
        self.proxyConfiguration = proxyConfiguration.normalized()
        self.remoteServers = remoteServers
        self.usageProgressDisplayMode = usageProgressDisplayMode
        self.locale = AppLocale.resolve(locale).identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtStartup = try container.decode(Bool.self, forKey: .launchAtStartup)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .launchChatGPTAfterSwitch) {
            launchChatGPTAfterSwitch = value
        } else {
            launchChatGPTAfterSwitch = try container.decode(Bool.self, forKey: .legacyLaunchCodexAfterSwitch)
        }
        autoSmartSwitch = try container.decode(Bool.self, forKey: .autoSmartSwitch)
        syncOpencodeOpenaiAuth = try container.decode(Bool.self, forKey: .syncOpencodeOpenaiAuth)
        localProxyHostAPIOnly = try container.decode(Bool.self, forKey: .localProxyHostAPIOnly)
        restartEditorsOnSwitch = try container.decode(Bool.self, forKey: .restartEditorsOnSwitch)
        restartEditorTargets = try container.decode([EditorAppID].self, forKey: .restartEditorTargets)
        autoStartApiProxy = try container.decode(Bool.self, forKey: .autoStartApiProxy)
        proxyConfiguration = try container.decode(ProxyConfiguration.self, forKey: .proxyConfiguration)
        remoteServers = try container.decode([RemoteServerConfig].self, forKey: .remoteServers)
        usageProgressDisplayMode = try container.decodeIfPresent(
            UsageProgressDisplayMode.self,
            forKey: .usageProgressDisplayMode
        ) ?? .used
        locale = AppLocale.resolve(try container.decode(String.self, forKey: .locale)).identifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtStartup, forKey: .launchAtStartup)
        try container.encode(launchChatGPTAfterSwitch, forKey: .launchChatGPTAfterSwitch)
        try container.encode(autoSmartSwitch, forKey: .autoSmartSwitch)
        try container.encode(syncOpencodeOpenaiAuth, forKey: .syncOpencodeOpenaiAuth)
        try container.encode(localProxyHostAPIOnly, forKey: .localProxyHostAPIOnly)
        try container.encode(restartEditorsOnSwitch, forKey: .restartEditorsOnSwitch)
        try container.encode(restartEditorTargets, forKey: .restartEditorTargets)
        try container.encode(autoStartApiProxy, forKey: .autoStartApiProxy)
        try container.encode(proxyConfiguration, forKey: .proxyConfiguration)
        try container.encode(remoteServers, forKey: .remoteServers)
        try container.encode(usageProgressDisplayMode, forKey: .usageProgressDisplayMode)
        try container.encode(locale, forKey: .locale)
    }

    static var defaultValue: AppSettings {
        AppSettings(
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
            locale: AppLocale.systemDefault.identifier
        )
    }
}

struct AppSettingsPatch {
    var launchAtStartup: Bool? = nil
    var launchChatGPTAfterSwitch: Bool? = nil
    var autoSmartSwitch: Bool? = nil
    var syncOpencodeOpenaiAuth: Bool? = nil
    var localProxyHostAPIOnly: Bool? = nil
    var restartEditorsOnSwitch: Bool? = nil
    var restartEditorTargets: [EditorAppID]? = nil
    var autoStartApiProxy: Bool? = nil
    var proxyConfiguration: ProxyConfiguration? = nil
    var remoteServers: [RemoteServerConfig]? = nil
    var usageProgressDisplayMode: UsageProgressDisplayMode? = nil
    var locale: String? = nil
}
