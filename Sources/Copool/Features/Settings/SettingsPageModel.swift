import Foundation
import Combine

@MainActor
final class SettingsPageModel: ObservableObject {
    let settingsCoordinator: SettingsCoordinator
    let editorAppService: EditorAppServiceProtocol
    let onSettingsUpdated: @MainActor (AppSettings) -> Void
    let onQuitRequested: @MainActor () -> Void
    let providerStoreRepository: ProviderStoreRepository?
    let onProvidersChanged: @MainActor () -> Void
    let paths: FileSystemPaths?

    private let noticeScheduler = NoticeAutoDismissScheduler()

    @Published var settings: AppSettings = .defaultValue
    @Published var installedEditorApps: [InstalledEditorApp] = []
    @Published var providers: [ProviderConfig] = []
    @Published var providerForm: ProviderFormDraft = .empty
    @Published var isTestingProviderConnection = false
    @Published var providerConnectionTestResult: String?
    /// Latest diagnostic run, empty until the user runs it.
    @Published var doctorChecks: [DoctorCheck] = []
    @Published var isRunningDoctor = false
    /// 最近一次导出的支持包路径，用于在界面上给出"在访达中显示"的落点。
    @Published var supportBundleURL: URL?
    @Published var isExportingSupportBundle = false
    /// 最近一条迁移记录（AC-004）。nil 表示从未迁移过——v1-only 的用户就是
    /// 这个状态，不是错误。
    @Published var lastMigration: MigrationEntry?
    @Published var isRollingBackMigration = false
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    var hasLoaded = false

    /// Whether providers.json is 0600 (Security sub-tab).
    var providerStorePermissionsOK: Bool {
        guard let paths else { return true }
        return (try? FileManager.default.attributesOfItem(atPath: paths.providerStorePath.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { $0.intValue & 0o777 == 0o600 } == true
    }

    /// Secondary tab (General/Security/Diagnostics/Advanced).
    @Published var subTab: SettingsSubTab = .general
    /// AC-105: external-model (login-optional) mode — Codex routes through
    /// the local proxy without depending on a ChatGPT login.
    @Published var loginOptionalEnabled = false

    func probeLoginOptionalState() {
        guard let paths else { return }
        let text = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        loginOptionalEnabled = text?.contains(">>> copool managed") == true
    }

    /// AC-105: toggles the managed `model_provider=opencodex` block. The
    /// underlying apply/remove is the same path the proxy lifecycle uses, so
    /// the switch always reflects (and restores) exactly the managed config.
    func setLoginOptional(_ enabled: Bool) {
        guard let paths else { return }
        let service = CodexModelsCacheService(paths: paths)
        do {
            if enabled {
                try service.applyProxyRouting(port: 8787)
            } else {
                try service.removeProxyRouting()
            }
            loginOptionalEnabled = enabled
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.advanced.login_optional_applied"))
        } catch {
            notice = NoticeMessage(style: .error, text: L10n.tr("settings.advanced.login_optional_failed_format", error.localizedDescription))
        }
    }

    init(
        settingsCoordinator: SettingsCoordinator,
        editorAppService: EditorAppServiceProtocol,
        providerStoreRepository: ProviderStoreRepository? = nil,
        paths: FileSystemPaths? = nil,
        onSettingsUpdated: @escaping @MainActor (AppSettings) -> Void = { _ in },
        onQuitRequested: @escaping @MainActor () -> Void = {},
        onProvidersChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.settingsCoordinator = settingsCoordinator
        self.editorAppService = editorAppService
        self.providerStoreRepository = providerStoreRepository
        self.paths = paths
        self.onSettingsUpdated = onSettingsUpdated
        self.onQuitRequested = onQuitRequested
        self.onProvidersChanged = onProvidersChanged
    }

    /// Runs the one-shot environment diagnosis.
    func runDoctor() {
        guard let paths, !isRunningDoctor else { return }
        isRunningDoctor = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRunningDoctor = false }
            self.doctorChecks = await ProxyDoctor().run(paths: paths)
        }
    }

    /// 导出脱敏支持包（M5）。
    ///
    /// 复用刚跑过的 `doctorChecks`，而不是在这里再跑一次诊断：诊断会发一次
    /// 健康探测请求，用户点"导出"时不该再等一轮网络往返。没跑过就是空的，
    /// 支持包里那一项直接缺席——这比塞一份现编的结果诚实。
    func exportSupportBundle() {
        guard let paths, !isExportingSupportBundle else { return }
        isExportingSupportBundle = true
        let providersSnapshot = providers
        let checks = doctorChecks
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isExportingSupportBundle = false }
            let text = await SupportBundleBuilder(paths: paths).build(
                providers: providersSnapshot,
                engineStatus: nil,
                doctorChecks: checks
            )
            let url = paths.applicationSupportDirectory.appendingPathComponent(
                "copool-support-bundle.json",
                isDirectory: false
            )
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self.supportBundleURL = url
                self.notice = NoticeMessage(style: .success, text: L10n.tr("settings.support_bundle.saved"))
            } catch {
                self.notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }
    }

    /// 读取最近一条迁移记录（AC-004）。
    func reloadMigrationState() {
        guard let paths else { return }
        let repository = ProviderRegistryV2Repository(
            registryPath: paths.registryV2Path,
            journalPath: paths.migrationJournalPath
        )
        lastMigration = repository.loadJournal().entries.last
    }

    /// 回滚最近一次迁移（AC-004）。
    ///
    /// 只删 v2 注册表，v1 存储原封不动——那才是回滚安全且可重复的原因。
    /// 下次启动 `migrateIfNeeded` 会从 v1 重新生成，所以这个操作没有"回不去"
    /// 的风险，不需要二次确认吓唬用户。
    func rollbackMigration() {
        guard let paths, let entry = lastMigration, !isRollingBackMigration else { return }
        isRollingBackMigration = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRollingBackMigration = false }
            let repository = ProviderRegistryV2Repository(
                registryPath: paths.registryV2Path,
                journalPath: paths.migrationJournalPath
            )
            let service = RegistryMigrationService(repository: repository)
            let succeeded = service.rollbackMigration(sourceHash: entry.sourceHash)
            self.reloadMigrationState()
            self.notice = NoticeMessage(
                style: succeeded ? .success : .error,
                text: L10n.tr(succeeded ? "settings.migration.rolled_back" : "settings.migration.rollback_failed")
            )
        }
    }

    func reloadProviders() {
        guard let providerStoreRepository else { return }
        providers = (try? providerStoreRepository.loadProviders())?.providers ?? []
    }

    func beginAddingProvider() {
        providerForm = .empty
        providerConnectionTestResult = nil
    }

    func beginEditingProvider(_ provider: ProviderConfig) {
        providerForm = ProviderFormDraft(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            modelListText: provider.models.map(\.id).joined(separator: ","),
            protocolMode: provider.models.first.map {
                provider.resolvedProtocol(forModel: $0.id).rawValue
            } ?? ProviderProtocol.chat.rawValue
        )
        providerConnectionTestResult = nil
    }

    func saveProviderForm() {
        guard let providerStoreRepository else { return }
        let draft = providerForm
        let modelIDs = draft.modelListText
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !modelIDs.isEmpty else {
            notice = NoticeMessage(style: .error, text: L10n.tr("settings.providers.invalid_form"))
            return
        }

        let protocolKind = ProviderProtocol(rawValue: draft.protocolMode) ?? .chat
        let existingProvider = providers.first(where: { $0.id == draft.id })
        let provider = ProviderConfig(
            id: draft.id.isEmpty ? UUID().uuidString : draft.id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespaces),
            apiKey: draft.apiKey.trimmingCharacters(in: .whitespaces),
            // Saving an imported provider must not drop its refresh token or
            // auth kind: without them the token expires and every later
            // request (capability discovery, test connection) fails with 401.
            refreshToken: existingProvider?.refreshToken,
            authKind: existingProvider?.authKind ?? .apiKey,
            models: modelIDs.map { modelID in
                // Keep capabilities discovery already confirmed for ids that
                // survive the edit; only brand-new ids start blank and get
                // probed again after save.
                if let old = existingProvider?.models.first(where: { $0.id == modelID }) {
                    return old
                }
                return ProviderModel(id: modelID)
            },
            modelProtocols: existingProvider?.modelProtocols
                ?? Dictionary(uniqueKeysWithValues: modelIDs.map { ($0, protocolKind) }),
            defaultProtocol: protocolKind,
            addedAt: draft.id.isEmpty ? Int64(Date().timeIntervalSince1970) : 0
        )

        do {
            _ = try providerStoreRepository.mutateProviders { store in
                if let index = store.providers.firstIndex(where: { $0.id == provider.id }) {
                    store.providers[index] = provider
                } else {
                    store.providers.append(provider)
                }
            }
            reloadProviders()
            providerForm = .empty
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.providers.saved"))
            onProvidersChanged()
            // Ask the provider what these models can actually do, then rewrite
            // the Codex catalog with the real numbers (same as the Providers page).
            Task { await discoverCapabilities(providerID: provider.id) }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    /// Refreshes one provider's model metadata in the background.
    ///
    /// Best-effort: a provider that will not answer keeps whatever is stored,
    /// and the catalog keeps working on the conservative defaults.
    func discoverCapabilities(providerID: String) async {
        guard let providerStoreRepository else { return }
        guard let provider = (try? providerStoreRepository.loadProviders())?
            .providers.first(where: { $0.id == providerID }) else { return }

        let refreshed = await ModelCapabilityDiscovery().refresh(provider: provider)
        guard refreshed != provider.models else { return }

        do {
            _ = try providerStoreRepository.mutateProviders { store in
                guard let index = store.providers.firstIndex(where: { $0.id == providerID }) else { return }
                store.providers[index].models = refreshed
            }
            reloadProviders()
            onProvidersChanged()
        } catch {
            // Discovery is an enhancement; failing to persist it must not
            // surface as an error over a save that already succeeded.
        }
    }

    func removeProvider(_ provider: ProviderConfig) {
        guard let providerStoreRepository else { return }
        do {
            _ = try providerStoreRepository.mutateProviders { store in
                store.providers.removeAll { $0.id == provider.id }
            }
            reloadProviders()
            onProvidersChanged()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func testProviderConnection() async {
        let draft = providerForm
        guard !draft.baseURL.isEmpty else {
            providerConnectionTestResult = L10n.tr("settings.providers.test_missing_url")
            return
        }
        isTestingProviderConnection = true
        providerConnectionTestResult = nil
        defer { isTestingProviderConnection = false }

        let base = draft.baseURL.trimmingCharacters(in: .whitespaces)
        let url = base.hasSuffix("/models") ? URL(string: base) : URL(string: "\(base)/models")
        guard let url else {
            providerConnectionTestResult = L10n.tr("settings.providers.test_invalid_url")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !draft.apiKey.isEmpty {
            request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            providerConnectionTestResult = (200..<300).contains(statusCode)
                ? L10n.tr("settings.providers.test_success")
                : L10n.tr("settings.providers.test_failed_format", String(statusCode))
        } catch {
            providerConnectionTestResult = L10n.tr("settings.providers.test_error_format", error.localizedDescription)
        }
    }
}
