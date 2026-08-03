import Foundation

#if os(macOS)
final class ChatGPTAppService: ChatGPTAppServiceProtocol, @unchecked Sendable {
    func launchApp() throws {
        forceStopRunningChatGPT()

        guard let appPath = findChatGPTAppPath() else {
            throw AppError.fileNotFound(L10n.tr("error.chatgpt_app.launch_failed"))
        }

        _ = try CommandRunner.runChecked(
            "/usr/bin/open",
            arguments: ["-na", appPath.path],
            errorPrefix: L10n.tr("error.chatgpt_app.launch_failed")
        )

        guard waitForChatGPTProcess(timeoutSeconds: 2) else {
            throw AppError.io(L10n.tr("error.chatgpt_app.launch_failed"))
        }
    }

    private func forceStopRunningChatGPT() {
        _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-TERM", "-x", "ChatGPT"])

        let gracefulShutdownDeadline = Date().addingTimeInterval(1)
        while isChatGPTProcessRunning(), Date() < gracefulShutdownDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if isChatGPTProcessRunning() {
            _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-KILL", "-x", "ChatGPT"])
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

    private func waitForChatGPTProcess(timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isChatGPTProcessRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func isChatGPTProcessRunning() -> Bool {
        (try? CommandRunner.run("/usr/bin/pgrep", arguments: ["-x", "ChatGPT"]))?.status == 0
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
