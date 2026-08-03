import Foundation

/// A local subscription login detected on this machine, importable as a
/// third-party provider. Modeled after opencodex `subscription_auth.ts`.
struct ImportedSubscription: Equatable, Sendable {
    var providerName: String      // e.g. "claude"
    var displayName: String       // e.g. "Claude (Claude Code login)"
    var baseURL: String
    var protocolKind: ProviderProtocol
    var accessToken: String
    var refreshToken: String?
    var modelIDs: [String]
    var authKind: ProviderAuthKind
}

/// Detects local subscription logins (Claude Code, Grok, Cursor, Antigravity)
/// so users can import them as third-party providers without API keys.
struct LocalSubscriptionImporter {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(fileManager: FileManager = .default, homeDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    // MARK: - Detection

    /// Returns all detectable local subscriptions.
    func detectAll() -> [ImportedSubscription] {
        var results: [ImportedSubscription] = []
        if let claude = detectClaudeCode() { results.append(claude) }
        if let grok = detectGrok() { results.append(grok) }
        if let cursor = detectCursor() { results.append(cursor) }
        if let antigravity = detectAntigravity() { results.append(antigravity) }
        return results
    }

    /// Claude Code stores OAuth credentials at `~/.claude/.credentials.json`;
    /// Claude Desktop keeps a plaintext token cache in `config.json`.
    func detectClaudeCode() -> ImportedSubscription? {
        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        let desktopConfigURL = homeDirectory.appendingPathComponent("Library/Application Support/Claude/config.json")

        var accessToken: String?
        var refreshToken: String?

        // 1. Claude Code OAuth credentials.
        if fileManager.fileExists(atPath: credentialsURL.path),
           let data = try? Data(contentsOf: credentialsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
            accessToken = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
            refreshToken = (oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String)
        }

        // 2. ~/.claude.json primary API key.
        if accessToken == nil, fileManager.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accessToken = json["primaryApiKey"] as? String
        }

        // 3. Claude Desktop config.json plaintext tokenCache (encrypted caches unsupported).
        if accessToken == nil, fileManager.fileExists(atPath: desktopConfigURL.path),
           let data = try? Data(contentsOf: desktopConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let cache = json["oauth:tokenCache"] as? [String: Any] {
                accessToken = cache["accessToken"] as? String
                refreshToken = (cache["refreshToken"] as? String) ?? refreshToken
            }
        }

        guard let accessToken, !accessToken.isEmpty else { return nil }
        return ImportedSubscription(
            providerName: "claude",
            displayName: "Claude (Claude Code login)",
            baseURL: "https://api.anthropic.com",
            protocolKind: .anthropic,
            accessToken: accessToken,
            refreshToken: refreshToken,
            modelIDs: ["claude-sonnet-4-6", "claude-opus-4-7", "claude-haiku-4-5"],
            authKind: .subscriptionImport
        )
    }

    /// Grok CLI stores session auth at `~/.grok/auth.json`.
    func detectGrok() -> ImportedSubscription? {
        let authURL = homeDirectory.appendingPathComponent(".grok/auth.json")
        guard fileManager.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let sessionKey = json.keys.first(where: { key in
            guard let session = json[key] as? [String: Any] else { return false }
            return session["key"] != nil || session["token"] != nil || session["access_token"] != nil
        }), let session = json[sessionKey] as? [String: Any] else {
            return nil
        }

        let accessToken = (session["key"] as? String)
            ?? (session["token"] as? String)
            ?? (session["access_token"] as? String)
        guard let accessToken, !accessToken.isEmpty else { return nil }

        return ImportedSubscription(
            providerName: "grok",
            displayName: "Grok (Grok CLI login)",
            baseURL: "https://api.x.ai/v1",
            protocolKind: .chat,
            accessToken: accessToken,
            refreshToken: session["refresh_token"] as? String,
            modelIDs: ["grok-4", "grok-4-fast"],
            authKind: .subscriptionImport
        )
    }

    /// Cursor stores auth tokens in `state.vscdb` (SQLite) under globalStorage.
    func detectCursor() -> ImportedSubscription? {
        let dbURL = homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard fileManager.fileExists(atPath: dbURL.path) else { return nil }

        let query = "SELECT key, CAST(value AS TEXT) AS value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/refreshToken');"
        let output = runCommand("/usr/bin/sqlite3", arguments: ["-json", dbURL.path, query])
        guard let output, !output.isEmpty,
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var values: [String: String] = [:]
        for row in rows {
            if let key = row["key"] as? String, let value = row["value"] as? String {
                values[key] = value
            }
        }
        guard let accessToken = values["cursorAuth/accessToken"], !accessToken.isEmpty else {
            return nil
        }

        return ImportedSubscription(
            providerName: "cursor",
            displayName: "Cursor (Cursor login)",
            baseURL: "https://api2.cursor.sh/v1",
            protocolKind: .chat,
            accessToken: accessToken,
            refreshToken: values["cursorAuth/refreshToken"],
            modelIDs: ["cursor-fast", "cursor-turbo"],
            authKind: .subscriptionImport
        )
    }

    /// Antigravity stores Google OAuth in the macOS Keychain
    /// (`security find-generic-password -a antigravity -s gemini`).
    func detectAntigravity() -> ImportedSubscription? {
        let output = runCommand(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-a", "antigravity", "-s", "gemini", "-w"]
        )
        guard let output, output.hasPrefix("go-keyring-base64:") else { return nil }

        let encoded = String(output.dropFirst("go-keyring-base64:".count))
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? [String: Any] else {
            return nil
        }

        let accessToken = (token["access_token"] as? String) ?? ""
        guard !accessToken.isEmpty else { return nil }

        return ImportedSubscription(
            providerName: "antigravity",
            displayName: "Antigravity (Gemini login)",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            protocolKind: .google,
            accessToken: accessToken,
            refreshToken: token["refresh_token"] as? String,
            modelIDs: ["gemini-3-pro", "gemini-3-flash"],
            authKind: .subscriptionImport
        )
    }

    // MARK: - Helpers

    private func runCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
