import Foundation

/// Third-party provider routing for the local proxy.
///
/// A request whose model id matches a configured provider namespace
/// (`providerName/backendModel`) is forwarded directly to that provider's
/// OpenAI-compatible endpoint with the provider's own API key. These requests
/// bypass the ChatGPT account failover chain entirely, and their token usage is
/// recorded in the separate third-party ledger (never in the account usage).
extension SwiftNativeProxyRuntimeService {
    /// Resolved third-party route for a client-visible model id.
    struct ThirdPartyRoute: Equatable, Sendable {
        let provider: ProviderConfig
        let backendModel: String
        let clientModelID: String
        let protocolKind: ProviderProtocol
    }

    /// Looks up a provider route for the requested client model id.
    ///
    /// Accepts both the namespaced id (`antigravity/gemini-3.6-flash`) and the
    /// plain backend id (`gemini-3.6-flash`) — ChatGPT.app may send either
    /// depending on how the catalog entry was written.
    func resolveThirdPartyRoute(for clientModel: String) throws -> ThirdPartyRoute? {
        guard let providerRepository else { return nil }
        let store = try providerRepository.loadProviders()
        let requested = clientModel.trimmingCharacters(in: .whitespacesAndNewlines)

        for provider in store.providers {
            for (clientID, backendID) in provider.clientModels {
                if clientID == requested || backendID == requested {
                    return ThirdPartyRoute(
                        provider: provider,
                        backendModel: backendID,
                        clientModelID: clientID,
                        protocolKind: provider.resolvedProtocol(forModel: backendID)
                    )
                }
            }
        }
        return nil
    }

    /// Model ids exposed by configured providers, appended to /v1/models.
    /// Uses the plain backend id so the proxy's model list matches what
    /// ChatGPT.app sends after the catalog slug change.
    func thirdPartyClientModelIDs() -> [String] {
        guard let providerRepository else { return [] }
        guard let store = try? providerRepository.loadProviders() else { return [] }
        return store.providers.flatMap { provider in
            provider.clientModels.map(\.backendID)
        }
    }

    // MARK: - Requests

    /// Sends a non-streaming request to a third-party provider.
    func sendThirdPartyRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        apiKeyOverride: String? = nil
    ) async throws -> UpstreamResponse {
        let request = try makeThirdPartyRequest(
            route: route,
            payload: payload,
            downstreamHeaders: downstreamHeaders,
            apiKeyOverride: apiKeyOverride
        )
        let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 500
        var responseBody = Data()
        responseBody.reserveCapacity(64 * 1024)

        for try await byte in responseBytes {
            responseBody.append(byte)
            if responseBody.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                throw AppError.network(
                    L10n.tr(
                        "error.proxy_runtime.upstream_response_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                    )
                )
            }
        }

        return UpstreamResponse(
            statusCode: statusCode,
            body: responseBody,
            headers: SwiftNativeProxyRuntimeService.normalizedHeaders(from: httpResponse?.allHeaderFields ?? [:])
        )
    }

    /// Opens a streaming request to a third-party provider.
    func openThirdPartyStreamingRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        apiKeyOverride: String? = nil
    ) async throws -> UpstreamStreamingResponse {
        let request = try makeThirdPartyRequest(
            route: route,
            payload: payload,
            downstreamHeaders: downstreamHeaders,
            apiKeyOverride: apiKeyOverride
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 500
        return UpstreamStreamingResponse(
            statusCode: statusCode,
            bytes: bytes,
            candidate: ProxyCandidate(
                id: route.provider.id,
                label: route.provider.name,
                accountID: route.provider.id,
                accountKey: route.provider.id,
                accessToken: route.provider.apiKey,
                authJSON: .object([:]),
                addedAt: route.provider.addedAt,
                isPreferredCurrent: false,
                oneWeekUsed: nil
            ),
            headers: SwiftNativeProxyRuntimeService.normalizedHeaders(from: httpResponse?.allHeaderFields ?? [:])
        )
    }

    /// Builds the upstream request for a third-party provider.
    func makeThirdPartyRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        apiKeyOverride: String? = nil
    ) throws -> URLRequest {
        guard let baseURL = URL(string: route.provider.baseURL) else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_upstream_payload"))
        }

        let apiKey = apiKeyOverride ?? route.provider.apiKey
        // Some upstreams gate on the client User-Agent; when a branch sets one
        // it must survive the generic downstream header forwarding below.
        var providerUserAgent: String?
        var request: URLRequest
        switch route.protocolKind {
        case .chat:
            request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: payload, with: route.backendModel))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if route.provider.name.lowercased() == "grok" || route.provider.baseURL.contains("x.ai") {
                providerUserAgent = "grok-cli/1.89.0"
            }
        case .responses:
            request = URLRequest(url: baseURL.appendingPathComponent("responses"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: payload, with: route.backendModel))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
            let anthropicBody = convertChatToAnthropic(payload, model: route.backendModel)
            request.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody)
            // Anthropic accepts both x-api-key and Authorization: Bearer.
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            let model = route.backendModel
            let streaming = (payload["stream"] as? Bool) ?? true
            let name = route.provider.name.lowercased()
            let isAntigravity = name == "antigravity" || name == "agy"
            let geminiBody = convertChatToGemini(payload)

            if isAntigravity {
                // Antigravity's OAuth token scopes cover the internal
                // CloudCode endpoint, not the public generativelanguage API
                // (opencodex routes Antigravity here too).
                let method = streaming ? ":streamGenerateContent" : ":generateContent"
                request = URLRequest(
                    url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal\(method)?alt=sse")!
                )
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "project": "default-cli-project",
                    "model": model,
                    "request": geminiBody,
                ])
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                // The CloudCode endpoint answers a foreign User-Agent with
                // `429 Resource has been exhausted`, which looks exactly like
                // a spent quota even when the account is untouched.
                providerUserAgent = "antigravity/hub/2.2.1 darwin/arm64"
            } else {
                let method = streaming ? ":streamGenerateContent" : ":generateContent"
                let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
                request = URLRequest(
                    url: baseURL
                        .appendingPathComponent("models/\(escapedModel)")
                        .appendingPathComponent(method)
                )
                request.httpBody = try JSONSerialization.data(withJSONObject: geminiBody)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")

        if let providerUserAgent {
            request.setValue(providerUserAgent, forHTTPHeaderField: "User-Agent")
        } else if let userAgent = Self.normalizedForwardHeader(downstreamHeaders["user-agent"]) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private func replacingModel(in payload: [String: Any], with backendModel: String) -> [String: Any] {
        var result = payload
        result["model"] = backendModel
        return result
    }

    // MARK: - Usage ledger

    /// Records a successful third-party request into the ledger.
    func recordThirdPartyUsage(
        route: ThirdPartyRoute,
        responseBody: Data,
        statusCode: Int
    ) {
        guard let usageRepository,
              statusCode >= 200 && statusCode < 300 else { return }

        let (promptTokens, completionTokens) = Self.extractTokenUsage(from: responseBody)
        guard let store = try? usageRepository.loadUsage() else { return }

        var mutated = store
        mutated.record(
            providerID: route.provider.id,
            providerName: route.provider.name,
            modelID: route.backendModel,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            at: dateProvider.unixSecondsNow()
        )
        try? usageRepository.saveUsage(mutated)
    }

    /// Extracts token usage from a provider response body (chat or responses).
    static func extractTokenUsage(from data: Data) -> (prompt: Int, completion: Int) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0)
        }

        if let usage = object["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let completion = usage["completion_tokens"] as? Int ?? 0
            if prompt > 0 || completion > 0 {
                return (prompt, completion)
            }
        }

        // Responses API may place usage under `usage.input_tokens` / `output_tokens`.
        if let usage = object["usage"] as? [String: Any] {
            let prompt = usage["input_tokens"] as? Int ?? 0
            let completion = usage["output_tokens"] as? Int ?? 0
            return (prompt, completion)
        }

        return (0, 0)
    }

    // MARK: - Auth refresh

    /// Refreshes the provider token on 401/403 for subscription-imported
    /// providers, persisting the new token. Returns nil when not applicable.
    ///
    /// Antigravity rows (even hand-added with a stale OAuth token) are always
    /// refreshed from the Keychain, which holds the authoritative refresh
    /// token.
    func refreshProviderTokenIfNeeded(route: ThirdPartyRoute) async -> String? {
        let name = route.provider.name.lowercased()
        let isAntigravity = name == "antigravity" || name == "agy"
            || route.provider.baseURL.contains("generativelanguage")
        let isGrok = name == "grok" || route.provider.baseURL.contains("x.ai")
        let eligible = route.provider.authKind == .subscriptionImport
            || route.provider.refreshToken != nil
            || isAntigravity
            || isGrok
        NSLog("[Copool:ThirdParty] refreshProviderTokenIfNeeded provider=%@ eligible=%d", route.provider.name, eligible ? 1 : 0)
        guard eligible, let providerRepository else { return nil }
        let refreshService = ProviderTokenRefreshService(providerRepository: providerRepository)
        let refreshed = await refreshService.refreshToken(for: route.provider)
        NSLog("[Copool:ThirdParty] refresh result=%@", refreshed.map { "ok:\($0.prefix(12))" } ?? "nil")
        return refreshed
    }

    /// Builds a success response from a third-party upstream response.
    func thirdPartySuccessResponse(route: ThirdPartyRoute, response: UpstreamResponse) -> HTTPResponse {
        recordThirdPartyUsage(route: route, responseBody: response.body, statusCode: response.statusCode)

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: response.body)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
        guard let decodedObject = decoded as? [String: Any] else {
            return HTTPResponse.json(statusCode: 200, object: decoded)
        }

        let responseObject: [String: Any]
        switch route.protocolKind {
        case .anthropic:
            responseObject = convertAnthropicResponseToChatCompletion(decodedObject, fallbackModel: route.clientModelID)
        case .google:
            responseObject = convertGeminiResponseToChatCompletion(decodedObject, fallbackModel: route.clientModelID)
        case .chat, .responses:
            responseObject = decodedObject
        }
        return HTTPResponse.json(statusCode: 200, object: responseObject)
    }

    /// Builds an error response from a third-party upstream response.
    func thirdPartyErrorResponse(route: ThirdPartyRoute, response: UpstreamResponse) -> HTTPResponse {
        let bodyText = String(data: response.body, encoding: .utf8) ?? ""
        let message = "\(route.provider.name): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
        lastError = message
        return jsonError(statusCode: 502, message: message)
    }
}
