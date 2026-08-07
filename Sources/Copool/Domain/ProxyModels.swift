import Foundation

struct RemoteServerConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var host: String
    var sshPort: Int
    var sshUser: String
    var authMode: String
    var identityFile: String?
    var privateKey: String?
    var password: String?
    var remoteDir: String
    var listenPort: Int
}

struct CloudflaredConfiguration: Codable, Equatable {
    var enabled: Bool
    var tunnelMode: CloudflaredTunnelMode
    var useHTTP2: Bool
    var namedHostname: String

    init(
        enabled: Bool = false,
        tunnelMode: CloudflaredTunnelMode = .quick,
        useHTTP2: Bool = false,
        namedHostname: String = ""
    ) {
        self.enabled = enabled
        self.tunnelMode = tunnelMode
        self.useHTTP2 = useHTTP2
        self.namedHostname = Self.normalizeHostnameDraft(namedHostname)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case tunnelMode
        case useHTTP2
        case namedHostname
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        tunnelMode = try container.decodeIfPresent(CloudflaredTunnelMode.self, forKey: .tunnelMode) ?? .quick
        useHTTP2 = try container.decodeIfPresent(Bool.self, forKey: .useHTTP2) ?? false
        namedHostname = Self.normalizeHostnameDraft(
            try container.decodeIfPresent(String.self, forKey: .namedHostname) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(tunnelMode, forKey: .tunnelMode)
        try container.encode(useHTTP2, forKey: .useHTTP2)
        try container.encode(namedHostname, forKey: .namedHostname)
    }

    static var defaultValue: CloudflaredConfiguration {
        CloudflaredConfiguration()
    }

    func normalized() -> CloudflaredConfiguration {
        CloudflaredConfiguration(
            enabled: enabled,
            tunnelMode: tunnelMode,
            useHTTP2: useHTTP2,
            namedHostname: namedHostname
        )
    }

    static func normalizeHostnameDraft(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

struct ProxyConfiguration: Codable, Equatable {
    var preferredPortText: String
    var cloudflared: CloudflaredConfiguration

    init(
        preferredPortText: String = String(RemoteServerConfiguration.defaultProxyPort),
        cloudflared: CloudflaredConfiguration = .defaultValue
    ) {
        self.preferredPortText = Self.normalizePreferredPortText(preferredPortText)
        self.cloudflared = cloudflared.normalized()
    }

    static var defaultValue: ProxyConfiguration {
        ProxyConfiguration()
    }

    var preferredPort: Int? {
        Int(preferredPortText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func normalized() -> ProxyConfiguration {
        ProxyConfiguration(
            preferredPortText: preferredPortText,
            cloudflared: cloudflared
        )
    }

    static func normalizePreferredPortText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(RemoteServerConfiguration.defaultProxyPort)
            : trimmed
    }
}

struct ApiProxyStatus: Codable, Equatable {
    var running: Bool
    var port: Int?
    var apiKey: String?
    var baseURL: String?
    var availableAccounts: Int
    var activeAccountID: String?
    var activeAccountLabel: String?
    var lastError: String?

    static let idle = ApiProxyStatus(
        running: false,
        port: nil,
        apiKey: nil,
        baseURL: nil,
        availableAccounts: 0,
        activeAccountID: nil,
        activeAccountLabel: nil,
        lastError: nil
    )
}

/// 第三方模型分流的三态（A2）。
///
/// 单一事实来源是 config.toml 里的托管块，而不是代理进程的内存状态：进程被
/// 强杀时 `stop()` 根本不会执行，托管块会留在文件里指向一个没人监听的端口。
/// 只看内存会得出"已停止、干净"，而 ChatGPT.app 那边第三方模型全是死路。
enum ProviderSplitState: String, Codable, Equatable, Sendable {
    /// 代理在跑，托管块已写入且端口与实际监听一致。第三方模型可用。
    case active
    /// 代理不在，托管块也已剥离。第三方模型停服，原生 GPT 直连不受影响。
    case degraded
    /// 托管块存在但代理没在跑（或端口不符）。需要自愈剥离。
    case inconsistent
}

enum CloudflaredTunnelMode: String, Codable, CaseIterable {
    case quick
    case named
}

struct StartCloudflaredTunnelInput: Codable, Equatable {
    var apiProxyPort: Int
    var useHTTP2: Bool
    var mode: CloudflaredTunnelMode
    var named: NamedCloudflaredTunnelInput?
}

struct NamedCloudflaredTunnelInput: Codable, Equatable {
    var apiToken: String
    var accountID: String
    var zoneID: String
    var hostname: String
}

struct CloudflaredStatus: Codable, Equatable {
    var installed: Bool
    var binaryPath: String?
    var running: Bool
    var tunnelMode: CloudflaredTunnelMode?
    var publicURL: String?
    var customHostname: String?
    var useHTTP2: Bool
    var lastError: String?

    static let idle = CloudflaredStatus(
        installed: false,
        binaryPath: nil,
        running: false,
        tunnelMode: nil,
        publicURL: nil,
        customHostname: nil,
        useHTTP2: false,
        lastError: nil
    )
}

struct RemoteProxyStatus: Codable, Equatable, Sendable {
    var installed: Bool
    var serviceInstalled: Bool
    var running: Bool
    var enabled: Bool
    var serviceName: String
    var pid: Int?
    var baseURL: String
    var apiKey: String?
    var lastError: String?
}

struct DiscoveredRemoteProxyInstance: Codable, Equatable, Identifiable, Sendable {
    var serviceName: String
    var serverID: String?
    var label: String?
    var remoteDir: String
    var listenPort: Int
    var installed: Bool
    var serviceInstalled: Bool
    var running: Bool
    var enabled: Bool
    var pid: Int?
    var apiKeyPresent: Bool
    var baseURL: String

    var id: String { serviceName }
}

struct ProxyControlSnapshot: Codable, Equatable {
    var syncedAt: Int64
    var sourceDeviceID: String
    var proxyStatus: ApiProxyStatus
    var preferredProxyPort: Int?
    var preferredProxyPortText: String? = nil
    var autoStartProxy: Bool
    var cloudflaredStatus: CloudflaredStatus
    var cloudflaredTunnelMode: CloudflaredTunnelMode
    var cloudflaredNamedInput: NamedCloudflaredTunnelInput
    var cloudflaredUseHTTP2: Bool
    var publicAccessEnabled: Bool
    var remoteServers: [RemoteServerConfig]
    var remoteStatusesSyncedAt: Int64?
    var remoteStatuses: [String: RemoteProxyStatus]
    var remoteDiscoveries: [String: [DiscoveredRemoteProxyInstance]] = [:]
    var remoteLogs: [String: String]
    var lastHandledCommandID: String?
    var lastCommandError: String?
}

enum ProxyControlCommandKind: String, Codable {
    case refreshStatus
    case refreshAccounts
    case updateProxyConfiguration
    case startProxy
    case stopProxy
    case refreshAPIKey
    case setAutoStartProxy
    case installCloudflared
    case startCloudflared
    case stopCloudflared
    case refreshCloudflared
    case addRemoteServer
    case saveRemoteServer
    case removeRemoteServer
    case discoverRemote
    case refreshRemote
    case deployRemote
    case syncRemoteAccounts
    case startRemote
    case stopRemote
    case readRemoteLogs
    case uninstallRemote
}

struct ProxyControlCommand: Codable, Equatable, Identifiable {
    var id: String
    var createdAt: Int64
    var sourceDeviceID: String
    var kind: ProxyControlCommandKind
    var preferredProxyPort: Int?
    var autoStartProxy: Bool?
    var cloudflaredInput: StartCloudflaredTunnelInput?
    var proxyConfiguration: ProxyConfiguration? = nil
    var remoteServer: RemoteServerConfig?
    var remoteServerID: String?
    var previousRemoteServerID: String? = nil
    var logLines: Int?
    var removeRemoteDirectory: Bool? = nil
}

struct RemoteAccountsMutationSyncReport: Equatable, Sendable {
    var synchronizedServerLabels: [String]
    var failures: [String]

    static let empty = RemoteAccountsMutationSyncReport(
        synchronizedServerLabels: [],
        failures: []
    )
}
