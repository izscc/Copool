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
    func resolveThirdPartyRoute(for clientModel: String) throws -> ThirdPartyRoute? {
        guard let providerRepository else { return nil }
        let store = try providerRepository.loadProviders()
        let requested = clientModel.trimmingCharacters(in: .whitespacesAndNewlines)

        for provider in store.providers {
            for (clientID, backendID) in provider.clientModels {
                if clientID == requested {
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
    func thirdPartyClientModelIDs() -> [String] {
        guard let providerRepository else { return [] }
        guard let store = try? providerRepository.loadProviders() else { return [] }
        return store.providers.flatMap { provider in
            provider.clientModels.map(\.clientID)
        }
    }

    // MARK: - Requests

    /// Sends a non-streaming request to a third-party provider.
    func sendThirdPartyRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamResponse {
        let request = try makeThirdPartyRequest(
            route: route,
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
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

        return UpstreamResponse(statusCode: statusCode, body: responseBody)
    }

    /// Opens a streaming request to a third-party provider.
    func openThirdPartyStreamingRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamStreamingResponse {
        let request = try makeThirdPartyRequest(
            route: route,
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return UpstreamStreamingResponse(statusCode: statusCode, bytes: bytes, candidate: ProxyCandidate(
            id: route.provider.id,
            label: route.provider.name,
            accountID: route.provider.id,
            accountKey: route.provider.id,
            accessToken: route.provider.apiKey,
            authJSON: .object([:]),
            addedAt: route.provider.addedAt,
            isPreferredCurrent: false,
            oneWeekUsed: nil
        ))
    }

    /// Builds the upstream request for a third-party provider.
    func makeThirdPartyRequest(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) throws -> URLRequest {
        guard let baseURL = URL(string: route.provider.baseURL) else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_upstream_payload"))
        }

        var request: URLRequest
        switch route.protocolKind {
        case .chat:
            request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: payload, with: route.backendModel))
            request.setValue("Bearer \(route.provider.apiKey)", forHTTPHeaderField: "Authorization")
        case .responses:
            request = URLRequest(url: baseURL.appendingPathComponent("responses"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: payload, with: route.backendModel))
            request.setValue("Bearer \(route.provider.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
            let anthropicBody = convertChatToAnthropic(payload, model: route.backendModel)
            request.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody)
            // Anthropic accepts both x-api-key and Authorization: Bearer.
            request.setValue(route.provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            let model = route.backendModel
            let streaming = (payload["stream"] as? Bool) ?? true
            let method = streaming ? ":streamGenerateContent" : ":generateContent"
            let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            request = URLRequest(
                url: baseURL
                    .appendingPathComponent("models/\(escapedModel)")
                    .appendingPathComponent(method)
            )
            let geminiBody = convertChatToGemini(payload)
            request.httpBody = try JSONSerialization.data(withJSONObject: geminiBody)
            request.setValue("Bearer \(route.provider.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")

        if let userAgent = Self.normalizedForwardHeader(downstreamHeaders["user-agent"]) {
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
}
