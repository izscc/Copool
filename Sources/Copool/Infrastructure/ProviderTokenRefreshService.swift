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
        guard let refreshToken = provider.refreshToken, !refreshToken.isEmpty else { return nil }

        switch provider.name.lowercased() {
        case "claude":
            return await refreshClaude(refreshToken: refreshToken, provider: provider)
        case "grok":
            return await refreshGrok(refreshToken: refreshToken, provider: provider)
        case "cursor":
            return await refreshCursor(refreshToken: refreshToken, provider: provider)
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

    private func refreshGrok(refreshToken: String, provider: ProviderConfig) async -> String? {
        // Read the OAuth issuer/client id from the local Grok auth file.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".grok/auth.json")
        var issuer = "https://auth.x.ai"
        var clientID = ""
        if let data = try? Data(contentsOf: authURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionKey = json.keys.first(where: { ($0 as NSString).length > 0 }),
           let session = json[sessionKey] as? [String: Any] {
            issuer = (session["oidc_issuer"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? issuer
            clientID = (session["oidc_client_id"] as? String) ?? ""
        }
        guard !clientID.isEmpty else { return nil }

        let form = "grant_type=refresh_token&client_id=\(clientID)&refresh_token=\(refreshToken)"
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
