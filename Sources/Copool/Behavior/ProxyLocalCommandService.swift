import Foundation

/// Executes proxy control commands in-process for the macOS local UI.
/// The UI previously declared this dependency but never injected an
/// implementation, making every local proxy button fail before reaching the
/// runtime service.
final class ProxyLocalCommandService: ProxyLocalCommandServiceProtocol, @unchecked Sendable {
    private let coordinator: ProxyCoordinator
    private let settingsRepository: SettingsRepository
    private let dateProvider: DateProviding

    init(
        coordinator: ProxyCoordinator,
        settingsRepository: SettingsRepository,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.coordinator = coordinator
        self.settingsRepository = settingsRepository
        self.dateProvider = dateProvider
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        var settings = try settingsRepository.loadSettings()
        var proxyStatus: ApiProxyStatus
        var cloudflaredStatus: CloudflaredStatus

        switch command.kind {
        case .refreshStatus, .refreshAccounts:
            (proxyStatus, cloudflaredStatus) = await coordinator.loadStatus()

        case .updateProxyConfiguration:
            if let configuration = command.proxyConfiguration {
                settings.proxyConfiguration = configuration.normalized()
                try settingsRepository.saveSettings(settings)
            }
            (proxyStatus, cloudflaredStatus) = await coordinator.loadStatus()

        case .startProxy:
            proxyStatus = try await coordinator.startProxy(preferredPort: command.preferredProxyPort)
            cloudflaredStatus = await coordinator.loadStatus().1

        case .stopProxy:
            proxyStatus = await coordinator.stopProxy()
            cloudflaredStatus = await coordinator.loadStatus().1

        case .refreshAPIKey:
            proxyStatus = try await coordinator.refreshAPIKey()
            cloudflaredStatus = await coordinator.loadStatus().1

        case .setAutoStartProxy:
            if let value = command.autoStartProxy {
                settings.autoStartApiProxy = value
                try settingsRepository.saveSettings(settings)
            }
            (proxyStatus, cloudflaredStatus) = await coordinator.loadStatus()

        case .installCloudflared:
            cloudflaredStatus = try await coordinator.installCloudflared()
            proxyStatus = await coordinator.loadStatus().0

        case .startCloudflared:
            guard let input = command.cloudflaredInput else {
                throw AppError.invalidData("Missing Cloudflared configuration")
            }
            cloudflaredStatus = try await coordinator.startCloudflared(input: input)
            proxyStatus = await coordinator.loadStatus().0

        case .stopCloudflared:
            cloudflaredStatus = await coordinator.stopCloudflared()
            proxyStatus = await coordinator.loadStatus().0

        case .refreshCloudflared:
            cloudflaredStatus = await coordinator.refreshCloudflared()
            proxyStatus = await coordinator.loadStatus().0

        case .addRemoteServer, .saveRemoteServer, .removeRemoteServer,
             .discoverRemote, .refreshRemote, .deployRemote,
             .syncRemoteAccounts, .startRemote, .stopRemote,
             .readRemoteLogs, .uninstallRemote:
            throw AppError.invalidData("Remote proxy commands are unavailable in the local command service")
        }

        return makeSnapshot(
            settings: settings,
            proxyStatus: proxyStatus,
            cloudflaredStatus: cloudflaredStatus,
            handledCommandID: command.id
        )
    }

    private func makeSnapshot(
        settings: AppSettings,
        proxyStatus: ApiProxyStatus,
        cloudflaredStatus: CloudflaredStatus,
        handledCommandID: String
    ) -> ProxyControlSnapshot {
        ProxyControlSnapshot(
            syncedAt: dateProvider.unixSecondsNow(),
            sourceDeviceID: "macos-local",
            proxyStatus: proxyStatus,
            preferredProxyPort: settings.proxyConfiguration.preferredPort,
            preferredProxyPortText: settings.proxyConfiguration.preferredPortText,
            autoStartProxy: settings.autoStartApiProxy,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: settings.proxyConfiguration.cloudflared.tunnelMode,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: settings.proxyConfiguration.cloudflared.namedHostname
            ),
            cloudflaredUseHTTP2: settings.proxyConfiguration.cloudflared.useHTTP2,
            publicAccessEnabled: settings.proxyConfiguration.cloudflared.enabled,
            remoteServers: settings.remoteServers,
            remoteStatusesSyncedAt: nil,
            remoteStatuses: [:],
            remoteDiscoveries: [:],
            remoteLogs: [:],
            lastHandledCommandID: handledCommandID,
            lastCommandError: nil
        )
    }
}
