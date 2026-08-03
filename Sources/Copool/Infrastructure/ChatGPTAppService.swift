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
        _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-9", "-x", "ChatGPT"])
        Thread.sleep(forTimeInterval: 0.22)
    }

    private func findChatGPTAppPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app")
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }

        return spotlightFindApp(named: "ChatGPT.app")
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
        let line = output.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let line else { return nil }
        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
#else
final class ChatGPTAppService: ChatGPTAppServiceProtocol, @unchecked Sendable {
    func launchApp() throws {
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }
}
#endif
