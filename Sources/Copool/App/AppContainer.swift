import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppContainer {
    /// Sendable weak reference used to bridge the file-watch callback into the
    /// main actor without capturing a main-actor-isolated value directly.
    private final class WeakBox: @unchecked Sendable {
        weak var value: AppContainer?
        init(_ value: AppContainer?) {
            self.value = value
        }
    }

    private final class AccountsStoreChangeHandlerBox: @unchecked Sendable {
        var handler: (@Sendable () -> Void)?
    }

    let accountsModel: AccountsPageModel
    let settingsModel: SettingsPageModel
    let trayModel: TrayMenuModel
    let providerModel: ProviderPageModel
    let agentModel: AgentPageModel

    private let settingsCoordinator: SettingsCoordinator
    private let accountsWidgetSnapshotWriter: AccountsWidgetSnapshotWriter
    private let accountsWidgetDisplayModeStore: AccountsWidgetDisplayModeStore
    private let proxyCoordinator: ProxyCoordinator
    private let localProxyCommandService: ProxyLocalCommandService
    private let providerRepository: ProviderStoreRepository
    private let chatGPTAppService: ChatGPTAppServiceProtocol
    private var accountsWidgetSnapshotCancellable: AnyCancellable?
    private var accountsPageSnapshotCancellable: AnyCancellable?
    private var widgetUsageProgressDisplayMode: UsageProgressDisplayMode

    lazy var proxyModel: ProxyPageModel = ProxyPageModel(        coordinator: proxyCoordinator,
        settingsCoordinator: settingsCoordinator,
        localProxyCommandService: localProxyCommandService,
        chooseIdentityFilePath: {
            #if canImport(AppKit)
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.title = L10n.tr("proxy.remote.auth.choose_key_file")
            guard panel.runModal() == .OK else { return nil }
            return panel.url?.path
            #else
            return nil
            #endif
        }
    )

    static func liveOrCrash() -> AppContainer {
        do {
            let paths = try FileSystemPaths.live()
            let storeRepository = StoreFileRepository(paths: paths)
            let settingsRepository = SettingsFileRepository(paths: paths)
            let authRepository = AuthFileRepository(paths: paths)
            let providerRepository = ProviderFileRepository(paths: paths)
            let usageRepository = ThirdPartyUsageFileRepository(paths: paths)
            let rateLimitRepository = ProviderRateLimitFileRepository(path: paths.providerRateLimitsPath)
            let usageLedger = UsageEventLedger(path: paths.usageEventsPath)
            let agentRepository = AgentProfileFileRepository(paths: paths)
            let initialAccounts = try initialAccountsSnapshot(using: storeRepository)
            let usageService = DefaultUsageService(configPath: paths.codexConfigPath)
            let workspaceMetadataService = DefaultWorkspaceMetadataService(configPath: paths.codexConfigPath)
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(configPath: paths.codexConfigPath)
            let chatGPTAppService = ChatGPTAppService(
                paths: paths,
                providerStoreRepository: providerRepository
            )
            let editorAppService = EditorAppService()
            let opencodeSyncService = OpencodeAuthSyncService()
            let launchAtStartupService = LaunchAtStartupService()
            let accountsStoreChangeHandlerBox = AccountsStoreChangeHandlerBox()
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                settingsRepository: settingsRepository,
                authRepository: authRepository,
                usageService: usageService,
                workspaceMetadataService: workspaceMetadataService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
                chatGPTAppService: chatGPTAppService,
                editorAppService: editorAppService,
                opencodeAuthSyncService: opencodeSyncService
            )
            let proxyCoordinator = ProxyCoordinator(
                proxyService: SwiftNativeProxyRuntimeService(
                    paths: paths,
                    storeRepository: storeRepository,
                    settingsRepository: settingsRepository,
                    authRepository: authRepository,
                    providerRepository: providerRepository,
                    usageRepository: usageRepository,
                    agentRepository: agentRepository,
                    rateLimitRepository: rateLimitRepository,
                    usageLedger: usageLedger,
                    onAccountsStoreChanged: {
                        accountsStoreChangeHandlerBox.handler?()
                    },
                    switchAccount: { cardID in
                        _ = try await accountsCoordinator.switchAccountAndApplySettings(id: cardID)
                    }
                ),
                cloudflaredService: CloudflaredService(paths: paths),
                remoteService: RemoteProxyService(
                    repoRoot: RepositoryLocator.findRepoRoot(startingAt: URL(fileURLWithPath: #filePath)),
                    sourceAccountStorePath: paths.accountStorePath
                )
            )
            let settingsCoordinator = SettingsCoordinator(
                settingsRepository: settingsRepository,
                launchAtStartupService: launchAtStartupService
            )
            let localProxyCommandService = ProxyLocalCommandService(
                coordinator: proxyCoordinator,
                settingsRepository: settingsRepository
            )
            let initialSettings = try settingsRepository.loadSettings()
            var applySettingsToContainer: ((AppSettings) -> Void)?
            try launchAtStartupService.syncWithStoreValue(initialSettings.launchAtStartup)
            let accountsWidgetDisplayModeStore = AccountsWidgetDisplayModeStore()
            let accountsWidgetSnapshotWriter = AccountsWidgetSnapshotWriter(
                localeProvider: {
                    let identifier = (try? await settingsCoordinator.currentSettings().locale)
                        ?? AppLocale.systemDefault.identifier
                    return Locale(identifier: AppLocale.resolve(identifier).identifier)
                }
            )
            let remoteAccountsMutationSyncService = RemoteAccountsMutationSyncService(
                settingsCoordinator: settingsCoordinator,
                proxyCoordinator: proxyCoordinator
            )
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                remoteAccountsMutationSyncService: remoteAccountsMutationSyncService,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
                initialAccounts: initialAccounts
            )
            accountsStoreChangeHandlerBox.handler = { [weak trayModel] in
                guard let trayModel else { return }
                Task { @MainActor in
                    let accounts = try? await trayModel.accountsCoordinator.listAccounts(
                        refreshWorkspaceMetadata: false
                    )
                    guard let accounts else { return }
                    trayModel.acceptLocalAccountsSnapshot(accounts)
                }
            }
            let accountsModel = AccountsPageModel(
                coordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                manualRefreshService: trayModel,
                localAccountsMutationSyncService: trayModel,
                chooseAuthDocumentURL: {
                    #if canImport(AppKit)
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false
                    panel.allowedContentTypes = [.json]
                    panel.title = L10n.tr("accounts.action.import_auth_file")
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK else { return nil }
                    return panel.url
                    #else
                    return nil
                    #endif
                },
                runtimePlatform: PlatformCapabilities.currentPlatform,
                usageProgressDisplayMode: initialSettings.usageProgressDisplayMode,
                onLocalAccountsChanged: { accounts in
                    trayModel.acceptLocalAccountsSnapshot(accounts)
                },
                onSettingsUpdated: { settings in
                    applySettingsToContainer?(settings)
                },
                initialAccounts: initialAccounts,
                thirdPartyUsageRepository: usageRepository
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
                editorAppService: editorAppService,
                providerStoreRepository: providerRepository,
                onSettingsUpdated: { settings in
                    applySettingsToContainer?(settings)
                },
                onQuitRequested: {
                    #if canImport(AppKit)
                    NSApp.terminate(nil)
                    #endif
                },
                onProvidersChanged: {
                    // Inject the updated catalog into ~/.codex/models_cache.json so
                    // the model menu shows third-party models after the next
                    // ChatGPT.app restart.
                    let providers = (try? providerRepository.loadProviders())?.providers ?? []
                    try? chatGPTAppService.syncThirdPartyModels(providers: providers)
                }
            )

            let agentModel = AgentPageModel(
                agentRepository: agentRepository,
                providerStoreRepository: providerRepository
            )
            let providerModel = ProviderPageModel(
                providerStoreRepository: providerRepository,
                usageRepository: usageRepository,
                paths: paths,
                rateLimitRepository: rateLimitRepository,
                usageLedger: usageLedger,
                accountUsageService: ProviderAccountUsageService(),
                onProvidersChanged: {
                    // Inject the updated catalog into ~/.codex/models_cache.json so
                    // the model menu shows third-party models after the next
                    // ChatGPT.app restart.
                    let providers = (try? providerRepository.loadProviders())?.providers ?? []
                    try? chatGPTAppService.syncThirdPartyModels(providers: providers)
                }
            )

            let container = AppContainer(
                settingsCoordinator: settingsCoordinator,
                accountsWidgetSnapshotWriter: accountsWidgetSnapshotWriter,
                accountsWidgetDisplayModeStore: accountsWidgetDisplayModeStore,
                proxyCoordinator: proxyCoordinator,
                localProxyCommandService: localProxyCommandService,
                providerRepository: providerRepository,
                chatGPTAppService: chatGPTAppService,
                widgetUsageProgressDisplayMode: initialSettings.usageProgressDisplayMode,
                accountsModel: accountsModel,
                settingsModel: settingsModel,
                trayModel: trayModel,
                providerModel: providerModel,
                agentModel: agentModel
            )
            applySettingsToContainer = { settings in
                container.applySettings(settings)
            }
            return container
        } catch {
            fatalError("Failed to bootstrap Swift migration app: \(error.localizedDescription)")
        }
    }

    private init(
        settingsCoordinator: SettingsCoordinator,
        accountsWidgetSnapshotWriter: AccountsWidgetSnapshotWriter,
        accountsWidgetDisplayModeStore: AccountsWidgetDisplayModeStore,
        proxyCoordinator: ProxyCoordinator,
        localProxyCommandService: ProxyLocalCommandService,
        providerRepository: ProviderStoreRepository,
        chatGPTAppService: ChatGPTAppServiceProtocol,
        widgetUsageProgressDisplayMode: UsageProgressDisplayMode,
        accountsModel: AccountsPageModel,
        settingsModel: SettingsPageModel,
        trayModel: TrayMenuModel,
        providerModel: ProviderPageModel,
        agentModel: AgentPageModel
    ) {
        self.settingsCoordinator = settingsCoordinator
        self.accountsWidgetSnapshotWriter = accountsWidgetSnapshotWriter
        self.accountsWidgetDisplayModeStore = accountsWidgetDisplayModeStore
        self.proxyCoordinator = proxyCoordinator
        self.localProxyCommandService = localProxyCommandService
        self.providerRepository = providerRepository
        self.chatGPTAppService = chatGPTAppService
        self.widgetUsageProgressDisplayMode = widgetUsageProgressDisplayMode
        self.accountsModel = accountsModel
        self.settingsModel = settingsModel
        self.trayModel = trayModel
        self.providerModel = providerModel
        self.agentModel = agentModel
        accountsWidgetDisplayModeStore.save(rawValue: widgetUsageProgressDisplayMode.rawValue)
        accountsWidgetSnapshotCancellable = trayModel.$accounts
            .removeDuplicates()
            .sink { [weak self] accounts in
                guard let self else { return }
                Task {
                    await self.accountsWidgetSnapshotWriter.write(
                        accounts: accounts,
                        usageProgressDisplayMode: self.widgetUsageProgressDisplayMode
                    )
                }
            }
        accountsPageSnapshotCancellable = trayModel.$accounts
            .removeDuplicates()
            .sink { [weak accountsModel] accounts in
                accountsModel?.acceptExternalAccountsSnapshot(accounts)
            }
        Task {
            await accountsWidgetSnapshotWriter.write(
                accounts: trayModel.accounts,
                usageProgressDisplayMode: widgetUsageProgressDisplayMode
            )
        }
    }

    /// Rebuilds `~/.codex/models_cache.json` with the current third-party
    /// provider catalog. Called at launch and whenever providers change so the
    /// ChatGPT.app model menu reflects imported models even when Codex has
    /// overwritten the cache with its own server-side list.
    func syncThirdPartyModelsToCodex() {
        let providers = (try? providerRepository.loadProviders())?.providers ?? []
        try? chatGPTAppService.syncThirdPartyModels(providers: providers)
    }

    /// Moves any plaintext provider secrets into the keychain, off the main
    /// thread. Every keychain call is time-boxed, so a build whose keychain
    /// access is awaiting user approval degrades instead of stalling.
    func migrateProviderSecretsIfNeeded() {
        let repository = providerRepository
        Task.detached(priority: .utility) {
            repository.migrateLegacySecretsIfNeeded()
        }
    }

    /// Watches `~/.codex/models_cache.json` and re-injects the third-party
    /// catalog whenever Codex overwrites it (e.g. on ChatGPT.app launch).
    private var modelsCacheWatchSource: DispatchSourceFileSystemObject?
    /// Debounces resyncs triggered by the cache watcher.
    private var resyncDebounceTask: Task<Void, Never>?

    func startModelsCacheWatch() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        let descriptor = open(path.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        // The handler must run on the main queue: on macOS 26+/Swift 6.2 the
        // runtime asserts when an unisolated dispatch callback creates
        // @MainActor work (or touches the MainActor-isolated self), even
        // though the compiler accepts it. MainActor.assumeIsolated then hops
        // onto the actor without going through a Task.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Debounce: Codex may write several times during a refresh.
                self.resyncDebounceTask?.cancel()
                self.resyncDebounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.syncThirdPartyModelsToCodex()
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        modelsCacheWatchSource = source
    }

    func applySettings(_ settings: AppSettings) {
        widgetUsageProgressDisplayMode = settings.usageProgressDisplayMode
        accountsWidgetDisplayModeStore.save(rawValue: settings.usageProgressDisplayMode.rawValue)
        trayModel.applySettings(settings)
        accountsModel.applySettings(settings)
        Task {
            await accountsWidgetSnapshotWriter.write(
                accounts: trayModel.accounts,
                usageProgressDisplayMode: settings.usageProgressDisplayMode
            )
        }
    }

    private static func initialAccountsSnapshot(
        using storeRepository: StoreFileRepository
    ) throws -> [AccountSummary] {
        let store = try storeRepository.loadStore()
        return store.accountSummaries()
    }
}
