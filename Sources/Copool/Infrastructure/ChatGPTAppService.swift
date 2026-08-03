import Foundation

#if os(macOS)
final class ChatGPTAppService: ChatGPTAppServiceProtocol, @unchecked Sendable {
    private let modelsCacheService: CodexModelsCacheService
    private let providerStoreRepository: ProviderStoreRepository?

    init(
        paths: FileSystemPaths? = nil,
        providerStoreRepository: ProviderStoreRepository? = nil,
        fileManager: FileManager = .default
    ) {
        self.providerStoreRepository = providerStoreRepository
        if let paths {
            modelsCacheService = CodexModelsCacheService(paths: paths, fileManager: fileManager)
        } else {
            // Fallback used by tests and callers without paths; sync is a no-op.
            modelsCacheService = CodexModelsCacheService(
                paths: FileSystemPaths(
                    applicationSupportDirectory: fileManager.temporaryDirectory,
                    accountStorePath: fileManager.temporaryDirectory.appendingPathComponent("accounts.json"),
                    settingsStorePath: fileManager.temporaryDirectory.appendingPathComponent("settings.json"),
                    providerStorePath: fileManager.temporaryDirectory.appendingPathComponent("providers.json"),
                    thirdPartyUsagePath: fileManager.temporaryDirectory.appendingPathComponent("usage.json"),
                    codexAuthPath: fileManager.temporaryDirectory.appendingPathComponent("auth.json"),
                    codexConfigPath: fileManager.temporaryDirectory.appendingPathComponent("config.toml"),
                    codexModelsCachePath: fileManager.temporaryDirectory.appendingPathComponent("models_cache.json"),
                    proxyDaemonDataDirectory: fileManager.temporaryDirectory.appendingPathComponent(".proxyd"),
                    proxyDaemonKeyPath: fileManager.temporaryDirectory.appendingPathComponent("api-proxy.key"),
                    cloudflaredLogDirectory: fileManager.temporaryDirectory.appendingPathComponent("logs")
                ),
                fileManager: fileManager
            )
        }
    }

    func launchApp() throws {
        guard let appPath = findChatGPTAppPath() else {
            throw AppError.fileNotFound(L10n.tr("error.chatgpt_app.launch_failed"))
        }

        // Inject third-party models into the cache before the app restarts so
        // the model menu is refreshed in the new process.
        try? syncThirdPartyModels(providers: currentProviders())

        forceStopRunningChatGPT(at: appPath)

        _ = try CommandRunner.runChecked(
            "/usr/bin/open",
            arguments: ["-na", appPath.path],
            errorPrefix: L10n.tr("error.chatgpt_app.launch_failed")
        )

        guard waitForChatGPTProcess(at: appPath, timeoutSeconds: 2) else {
            throw AppError.io(L10n.tr("error.chatgpt_app.launch_failed"))
        }
    }

    func syncThirdPartyModels(providers: [ProviderConfig]) throws {
        try modelsCacheService.sync(providers: providers)
    }

    private func currentProviders() -> [ProviderConfig] {
        guard let providerStoreRepository else { return [] }
        return (try? providerStoreRepository.loadProviders())?.providers ?? []
    }

    private func forceStopRunningChatGPT(at appPath: URL) {
        for processID in chatGPTProcessIDs(at: appPath) {
            _ = try? CommandRunner.run("/bin/kill", arguments: ["-TERM", processID])
        }

        let gracefulShutdownDeadline = Date().addingTimeInterval(1)
        while !chatGPTProcessIDs(at: appPath).isEmpty, Date() < gracefulShutdownDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        let remainingProcessIDs = chatGPTProcessIDs(at: appPath)
        if !remainingProcessIDs.isEmpty {
            for processID in remainingProcessIDs {
                _ = try? CommandRunner.run("/bin/kill", arguments: ["-KILL", processID])
            }
            Thread.sleep(forTimeInterval: 0.22)
        }
    }

    private func findChatGPTAppPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app")
        ]
        if let found = candidates.first(where: isChatGPTApp) {
            return found
        }

        return spotlightFindApp(named: "ChatGPT.app")
    }

    private func isChatGPTApp(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "com.openai.codex",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "ChatGPT" else {
            return false
        }
        return true
    }

    private func waitForChatGPTProcess(at appPath: URL, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !chatGPTProcessIDs(at: appPath).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func chatGPTProcessIDs(at appPath: URL) -> [String] {
        let executablePath = appPath.appendingPathComponent("Contents/MacOS/ChatGPT").path
        let command = "/bin/ps -axo pid=,comm= | /usr/bin/grep -F -- \(shellQuote(executablePath))"
        guard let output = try? CommandRunner.run("/bin/sh", arguments: ["-c", command]) else {
            return []
        }

        return output.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      String(fields[1]) == executablePath else {
                    return nil
                }
                return String(fields[0])
            }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func spotlightFindApp(named appName: String) -> URL? {
        let query = "kMDItemFSName == '\(appName)'"
        guard let output = try? CommandRunner.run("/usr/bin/mdfind", arguments: [query]),
              output.status == 0 else {
            return nil
        }
        let paths = output.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(URL.init(fileURLWithPath:))
        return paths.first(where: isChatGPTApp)
    }
}
#else
final class ChatGPTAppService: ChatGPTAppServiceProtocol, @unchecked Sendable {
    func launchApp() throws {
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }
}
#endif
