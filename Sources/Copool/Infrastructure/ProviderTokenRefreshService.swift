import Foundation

/// Refreshes subscription-imported provider tokens when the proxy receives a
/// 401/403. Modeled after opencodex `subscription_auth.ts` refresh flows.
struct ProviderTokenRefreshService: Sendable {
    let providerRepository: ProviderStoreRepository

    init(providerRepository: ProviderStoreRepository) {
        self.providerRepository = providerRepository
    }

    /// Attempts to refresh the provider's token; returns the new access token
    /// on success (also persisting it), nil otherwise.
    func refreshToken(for provider: ProviderConfig) async -> String? {
        switch provider.name.lowercased() {
        case "claude":
            return await refreshClaude(refreshToken: provider.refreshToken ?? "", provider: provider)
        case "grok":
            // Grok's refresh token lives in ~/.grok/auth.json; the provider row
            // may only hold a stale access token.
            return await refreshGrok(refreshToken: nil, provider: provider)
        case "cursor":
            return await refreshCursor(refreshToken: provider.refreshToken ?? "", provider: provider)
        case "antigravity", "agy":
            // Antigravity keeps the refresh token in the Keychain; the provider
            // row may only hold a stale access token.
            return await refreshAntigravity(provider: provider)
        default:
            return nil
        }
    }

    private func persist(accessToken: String, for provider: ProviderConfig) {
        do {
            _ = try providerRepository.mutateProviders { store in
                guard let index = store.providers.firstIndex(where: { $0.id == provider.id }) else { return }
                store.providers[index].apiKey = accessToken
            }
        } catch {
            // Ignore persistence failures; the token still works for this run.
        }
    }

    private func refreshClaude(refreshToken: String, provider: ProviderConfig) async -> String? {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        ]
        guard let response = await postJSON(
            url: "https://platform.claude.com/v1/oauth/token",
            body: body,
            headers: ["anthropic-beta": "oauth-2025-04-20"]
        ), let accessToken = response["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        persist(accessToken: accessToken, for: provider)
        return accessToken
    }

    private func refreshGrok(refreshToken: String?, provider: ProviderConfig) async -> String? {
        // Read the OAuth issuer/client id and refresh token from the local
        // Grok auth file (authoritative for CLI logins).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".grok/auth.json")
        var issuer = "https://auth.x.ai"
        var clientID = ""
        var resolvedRefreshToken = refreshToken ?? ""
        if let data = try? Data(contentsOf: authURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionKey = json.keys.first(where: { ($0 as NSString).length > 0 }),
           let session = json[sessionKey] as? [String: Any] {
            issuer = (session["oidc_issuer"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? issuer
            clientID = (session["oidc_client_id"] as? String) ?? ""
            if resolvedRefreshToken.isEmpty {
                resolvedRefreshToken = (session["refresh_token"] as? String) ?? ""
            }
        }
        guard !clientID.isEmpty, !resolvedRefreshToken.isEmpty else { return nil }

        let form = "grant_type=refresh_token&client_id=\(clientID)&refresh_token=\(resolvedRefreshToken)"
        guard let response = await postForm(
            url: "\(issuer)/oauth2/token",
            form: form,
            headers: ["User-Agent": "grok-cli/1.89.0"]
        ), let accessToken = (response["access_token"] as? String) ?? (response["id_token"] as? String), !accessToken.isEmpty else {
            return nil
        }
        persist(accessToken: accessToken, for: provider)
        return accessToken
    }

    private func refreshCursor(refreshToken: String, provider: ProviderConfig) async -> String? {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": refreshToken,
        ]
        guard let response = await postJSON(
            url: "https://api2.cursor.sh/oauth/token",
            body: body,
            headers: ["x-cursor-client-type": "desktop"]
        ), let accessToken = response["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        persist(accessToken: accessToken, for: provider)
        return accessToken
    }

    /// Antigravity stores a Google OAuth token in the macOS Keychain. Reads the
    /// latest refresh token from there and exchanges it for a fresh access
    /// token, then persists it to the provider.
    private func refreshAntigravity(provider: ProviderConfig) async -> String? {
        // 1. Read the refresh token from the Keychain (source of truth).
        let keychainRefresh = readAntigravityKeychainRefreshToken()
        NSLog("[Copool:Antigravity] keychain refresh token: %@", keychainRefresh.map { "found (\($0.count) chars)" } ?? "nil")
        guard let refreshToken = keychainRefresh ?? provider.refreshToken, !refreshToken.isEmpty else {
            return nil
        }

        // 2. Discover OAuth client id/secret pairs from the Antigravity binary.
        let clientIDs = readAntigravityOAuthClientIDs()
        let secrets = readAntigravityOAuthSecrets()
        NSLog("[Copool:Antigravity] clientIDs=\(clientIDs.count) secrets=\(secrets.count)")
        guard !clientIDs.isEmpty else { return nil }

        for clientID in clientIDs {
            var candidates: [String?] = [nil]
            candidates.append(contentsOf: secrets.map { $0 as String? })
            for secret in candidates {
                var body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientID)"
                if let secret {
                    body += "&client_secret=\(secret)"
                }
                if let response = await postForm(
                    url: "https://oauth2.googleapis.com/token",
                    form: body,
                    headers: [:]
                ), let accessToken = response["access_token"] as? String, !accessToken.isEmpty {
                    NSLog("[Copool:Antigravity] refresh OK client=\(clientID.prefix(12)) secret=\(secret.map { $0.prefix(10) } ?? "nil")")
                    persist(accessToken: accessToken, for: provider)
                    return accessToken
                }
            }
        }
        NSLog("[Copool:Antigravity] all refresh attempts failed")
        return nil
    }

    private func readAntigravityKeychainRefreshToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "antigravity", "-s", "gemini", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            NSLog("[Copool:Antigravity] security exit=%d bytes=%d", process.terminationStatus, data.count)
            guard process.terminationStatus == 0,
                  let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix("go-keyring-base64:") else {
                let preview = String(data: data, encoding: .utf8)?.prefix(40) ?? "nil"
                NSLog("[Copool:Antigravity] raw prefix check failed: %@", String(preview))
                return nil
            }
            let encoded = String(raw.dropFirst("go-keyring-base64:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[Copool:Antigravity] encoded base64 length=%d", encoded.count)
            guard let data = Data(base64Encoded: encoded),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? [String: Any] else {
                NSLog("[Copool:Antigravity] base64/json parse failed")
                return nil
            }
            let refresh = token["refresh_token"] as? String
            NSLog("[Copool:Antigravity] parsed refresh token: %@", refresh.map { "found (\($0.count) chars)" } ?? "nil")
            return refresh
        } catch {
            NSLog("[Copool:Antigravity] security error: %@", error.localizedDescription)
            return nil
        }
    }

    private func readAntigravityOAuthClientIDs() -> [String] {
        readAntigravityBinaryMatches(pattern: #"[0-9][A-Za-z0-9._-]{20,80}\.apps\.googleusercontent\.com"#)
    }

    private func readAntigravityOAuthSecrets() -> [String] {
        readAntigravityBinaryMatches(pattern: #"GOCSPX-[A-Za-z0-9_-]{28}"#)
    }

    private func readAntigravityBinaryMatches(pattern: String) -> [String] {
        let candidates = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Antigravity.app/Contents/Resources/bin/language_server").path,
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            // The language server is a Mach-O binary; decode lossily so
            // embedded ASCII strings (OAuth ids/secrets) are still found.
            let text = String(decoding: data, as: UTF8.self)
            let matches = Self.matches(in: text, pattern: pattern)
            if !matches.isEmpty {
                return matches
            }
        }
        return []
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    // MARK: - HTTP helpers

    private func postJSON(url: String, body: [String: Any], headers: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func postForm(url: String, form: String, headers: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = form.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
