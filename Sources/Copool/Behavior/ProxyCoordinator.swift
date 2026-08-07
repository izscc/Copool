import Foundation
import Combine

final class ProxyCoordinator: @unchecked Sendable {
    private let proxyService: ProxyRuntimeService
    private let cloudflaredService: CloudflaredServiceProtocol
    private let remoteService: RemoteProxyServiceProtocol
    private let routerHost: RouterHostControlClient
    private let routerHostProcess: RouterHostProcess

    private(set) var usingRouterHost = false

    init(
        proxyService: ProxyRuntimeService,
        cloudflaredService: CloudflaredServiceProtocol,
        remoteService: RemoteProxyServiceProtocol,
        routerHost: RouterHostControlClient = RouterHostControlClient(),
        routerHostProcess: RouterHostProcess = RouterHostProcess()
    ) {
        self.proxyService = proxyService
        self.cloudflaredService = cloudflaredService
        self.remoteService = remoteService
        self.routerHost = routerHost
        self.routerHostProcess = routerHostProcess
    }

    func loadStatus() async -> (ApiProxyStatus, CloudflaredStatus) {
        async let proxy = proxyService.status()
        async let cloudflared = cloudflaredService.status()
        return await (proxy, cloudflared)
    }

    /// 启动时收敛分流状态（A2 自愈）。
    ///
    /// App 被强杀时 `stopProxy()` 没机会执行，托管块会留在 config.toml 里指向
    /// 一个没人监听的端口——ChatGPT.app 那边第三方模型全是死路，而原生 GPT 也
    /// 被一起拖下水。这里在启动路径上把它剥离掉。
    ///
    /// 返回是否真的剥离过，调用方据此决定要不要提示用户（A3）。
    @discardableResult
    func reconcileProviderSplitOnLaunch() async -> Bool {
        await proxyService.reconcileProviderSplit()
    }

    func providerSplitState() async -> ProviderSplitState {
        await proxyService.providerSplitState()
    }

    func startProxy(preferredPort: Int?) async throws -> ApiProxyStatus {
        try await proxyService.syncAccountsStore()
        let localStatus = try await proxyService.start(preferredPort: preferredPort)
        guard routerHost.isEnabled else { return localStatus }

        do {
            guard let localBaseURL = localStatus.baseURL,
                  let localAPIKey = localStatus.apiKey else {
                return localStatus
            }
            let hostStatus = try routerHostProcess.start(
                upstreamBaseURL: localBaseURL,
                authorization: localAPIKey
            )
            guard let hostPort = hostStatus.port else { return localStatus }
            usingRouterHost = true
            return ApiProxyStatus(
                running: true,
                port: hostPort,
                apiKey: localAPIKey,
                baseURL: "http://127.0.0.1:\(hostPort)/v1",
                availableAccounts: localStatus.availableAccounts,
                activeAccountID: localStatus.activeAccountID,
                activeAccountLabel: localStatus.activeAccountLabel,
                lastError: localStatus.lastError
            )
        } catch {
            usingRouterHost = false
            return localStatus
        }
    }

    func stopProxy() async -> ApiProxyStatus {
        if usingRouterHost {
            routerHostProcess.stop()
            usingRouterHost = false
        }
        return await proxyService.stop()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        try await proxyService.refreshAPIKey()
    }

    func installCloudflared() async throws -> CloudflaredStatus {
        try await cloudflaredService.install()
    }

    func startCloudflared(input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus {
        try await cloudflaredService.start(input)
    }

    func stopCloudflared() async -> CloudflaredStatus {
        await cloudflaredService.stop()
    }

    func refreshCloudflared() async -> CloudflaredStatus {
        await cloudflaredService.status()
    }

    func remoteStatus(server: RemoteServerConfig) async -> RemoteProxyStatus {
        await remoteService.status(server: server)
    }

    func discoverRemote(server: RemoteServerConfig) async throws -> [DiscoveredRemoteProxyInstance] {
        try await remoteService.discover(server: server)
    }

    func remoteStatuses(for servers: [RemoteServerConfig]) async -> [String: RemoteProxyStatus] {
        await withTaskGroup(of: (String, RemoteProxyStatus).self, returning: [String: RemoteProxyStatus].self) { group in
            for server in servers {
                group.addTask { [remoteService] in
                    (server.id, await remoteService.status(server: server))
                }
            }

            var merged: [String: RemoteProxyStatus] = [:]
            for await (serverID, status) in group {
                merged[serverID] = status
            }
            return merged
        }
    }

    func deployRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.deploy(server: server)
    }

    func syncRemoteAccounts(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.syncAccounts(server: server)
    }

    func startRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.start(server: server)
    }

    func stopRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.stop(server: server)
    }

    func readRemoteLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        try await remoteService.readLogs(server: server, lines: lines)
    }

    func uninstallRemote(
        server: RemoteServerConfig,
        removeRemoteDirectory: Bool = false
    ) async throws -> RemoteProxyStatus {
        try await remoteService.uninstall(
            server: server,
            removeRemoteDirectory: removeRemoteDirectory
        )
    }
}
