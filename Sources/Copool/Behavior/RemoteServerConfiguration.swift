import Foundation

enum RemoteServerConfiguration {
    static let defaultProxyPort = 8787
    static let defaultSSHPort = 22
    static let defaultLabel = "new-server"
    static let defaultSSHUser = "root"
    static let defaultAuthMode = "keyPath"
    static let defaultRemoteDir = "/opt/codex-tools"

    static func makeDraft(id: String = UUID().uuidString) -> RemoteServerConfig {
        RemoteServerConfig(
            id: id,
            label: defaultLabel,
            host: "",
            sshPort: defaultSSHPort,
            sshUser: defaultSSHUser,
            authMode: defaultAuthMode,
            identityFile: nil,
            privateKey: nil,
            password: nil,
            remoteDir: defaultRemoteDir,
            listenPort: defaultProxyPort
        )
    }

    static func normalize(
        _ server: RemoteServerConfig,
        makeID: () -> String = { UUID().uuidString }
    ) -> RemoteServerConfig {
        var value = server
        value.id = trimmed(value.id) ?? makeID()
        value.label = trimmed(value.label) ?? ""
        value.host = trimmed(value.host) ?? ""
        value.sshUser = trimmed(value.sshUser) ?? ""
        value.remoteDir = trimmed(value.remoteDir) ?? ""
        value.authMode = trimmed(value.authMode) ?? defaultAuthMode
        value.identityFile = trimmed(value.identityFile)
        value.privateKey = trimmed(value.privateKey)
        value.password = trimmed(value.password)
        return value
    }

    static func upsert(
        _ server: RemoteServerConfig,
        into servers: [RemoteServerConfig],
        makeID: () -> String = { UUID().uuidString }
    ) -> [RemoteServerConfig] {
        let normalized = normalize(server, makeID: makeID)
        var merged = servers
        if let index = merged.firstIndex(where: { $0.id == normalized.id }) {
            merged[index] = normalized
        } else {
            merged.append(normalized)
        }
        return merged
    }

    static func adoptingDiscoveredInstance(
        _ instance: DiscoveredRemoteProxyInstance,
        into server: RemoteServerConfig
    ) -> RemoteServerConfig {
        var adopted = server
        if let serverID = trimmed(instance.serverID) {
            adopted.id = serverID
        }
        if let label = trimmed(instance.label) {
            adopted.label = label
        }
        adopted.remoteDir = instance.remoteDir
        adopted.listenPort = instance.listenPort
        return adopted
    }

    static func statusLabel(_ status: RemoteProxyStatus?) -> String {
        guard let status else { return L10n.tr("common.unknown") }
        return status.running ? L10n.tr("proxy.status.running") : L10n.tr("proxy.status.stopped")
    }

    static func boolText(_ value: Bool?) -> String {
        guard let value else { return L10n.tr("common.unknown") }
        return value ? L10n.tr("common.yes") : L10n.tr("common.no")
    }

    static func isPlaceholderDraft(_ server: RemoteServerConfig) -> Bool {
        let trimmedLabel = server.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLabel.isEmpty || trimmedLabel == defaultLabel
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
