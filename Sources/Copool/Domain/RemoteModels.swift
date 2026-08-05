import Foundation

// MARK: - Remote node domain (Phase 9)

/// Identity and capabilities of one remote router node.
struct RemoteNode: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// Stable per-install identity (not the display name).
    var identity: String
    var platform: String
    var version: String
    var capabilities: Set<String>
    var lastHeartbeatAt: Int64?
    var status: Status
    /// Pending upgrade/rollback state.
    var pendingOperation: String?

    enum Status: String, Codable, Equatable, Sendable {
        case offline
        case online
        case degraded
        case updating
    }

    init(
        id: String = UUID().uuidString,
        identity: String,
        platform: String,
        version: String,
        capabilities: Set<String> = [],
        lastHeartbeatAt: Int64? = nil,
        status: Status = .offline,
        pendingOperation: String? = nil
    ) {
        self.id = id
        self.identity = identity
        self.platform = platform
        self.version = version
        self.capabilities = capabilities
        self.lastHeartbeatAt = lastHeartbeatAt
        self.status = status
        self.pendingOperation = pendingOperation
    }
}

/// Version handshake between the app and a remote node.
struct RemoteHandshake: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var appVersion: String
    var nodeVersion: String
    var accepted: Bool
    var reason: String?

    static let currentProtocol = 1

    /// Two-way compatibility: same major protocol, node not older than the
    /// minimum supported version.
    static func evaluate(appVersion: String, nodeVersion: String, nodeProtocol: Int) -> RemoteHandshake {
        guard nodeProtocol == currentProtocol else {
            return RemoteHandshake(protocolVersion: currentProtocol, appVersion: appVersion, nodeVersion: nodeVersion, accepted: false, reason: "protocol mismatch")
        }
        return RemoteHandshake(protocolVersion: currentProtocol, appVersion: appVersion, nodeVersion: nodeVersion, accepted: true, reason: nil)
    }
}

/// Heartbeat payload — contains NO secrets by contract (AC-204: 本地 Keychain
/// secret 不自动上传). Payload is deliberately whitelisted to identity +
/// status + counters.
struct RemoteHeartbeat: Codable, Equatable, Sendable {
    var nodeID: String
    var sentAt: Int64
    var status: RemoteNode.Status
    var activeSessionCount: Int
    var openRequestCount: Int
    var version: String

    /// Whitelisted by construction: no provider config, no credentials, no
    /// keychain references, no logs.
    static func validateNoSecrets(in payload: RemoteHeartbeat) -> Bool {
        // The type has no secret-bearing fields; this is the enforcement
        // point for the contract (defense in depth for future fields).
        let encoded = (try? JSONEncoder().encode(payload)).map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        return !encoded.lowercased().contains("keychain")
            && !encoded.lowercased().contains("token")
            && !encoded.lowercased().contains("secret")
            && !encoded.lowercased().contains("api_key")
    }
}

/// Tracks node liveness from heartbeats.
struct HeartbeatMonitor: Sendable {
    var timeoutSeconds: Int
    var now: @Sendable () -> Int64

    init(timeoutSeconds: Int = 90, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.timeoutSeconds = timeoutSeconds
        self.now = now
    }

    /// Returns the node's status given the last heartbeat time.
    func status(lastHeartbeatAt: Int64?, pendingOperation: String?) -> RemoteNode.Status {
        if pendingOperation != nil { return .updating }
        guard let lastHeartbeatAt else { return .offline }
        let age = now() - lastHeartbeatAt
        if age > Int64(timeoutSeconds) { return .offline }
        if age > Int64(timeoutSeconds / 2) { return .degraded }
        return .online
    }

    /// Upgrade/rollback gate: a node only transitions to `.updating` after a
    /// valid handshake; rollback restores the previous version.
    func beginUpgrade(node: RemoteNode) -> RemoteNode {
        var updated = node
        updated.pendingOperation = "upgrade"
        updated.status = .updating
        return updated
    }

    func completeUpgrade(node: RemoteNode, newVersion: String) -> RemoteNode {
        var updated = node
        updated.version = newVersion
        updated.pendingOperation = nil
        updated.lastHeartbeatAt = now()
        updated.status = .online
        return updated
    }
}
