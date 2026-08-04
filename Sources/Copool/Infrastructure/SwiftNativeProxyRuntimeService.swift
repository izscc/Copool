import Foundation

actor SwiftNativeProxyRuntimeService: ProxyRuntimeService {
    enum UpstreamRouteFamily: Equatable {
        case codex
        case general
    }

    static let defaultCodexClientVersion = "0.101.0"
    static let defaultCodexUserAgent = "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464"

    let paths: FileSystemPaths
    let storeRepository: AccountsStoreRepository
    let settingsRepository: SettingsRepository
    let authRepository: AuthRepository
    let providerRepository: ProviderStoreRepository?
    let usageRepository: ThirdPartyUsageRepository?
    let onAccountsStoreChanged: (@Sendable () -> Void)?
    let switchAccount: (@Sendable (String) async throws -> Void)?
    let dateProvider: DateProviding

    private var server: SimpleHTTPServer?
    private var runningPort: Int?
    private var activeAccountID: String?
    private var activeAccountLabel: String?
    var lastError: String?
    var cachedCandidates: [ProxyCandidate]?
    var cachedCandidatesStoreModificationDate: Date?
    var stickyAccountID: String?
    /// `thoughtSignature` per Gemini tool call id. Gemini 3.x refuses a turn
    /// that replays a function call without the signature it issued, and the
    /// signature does not survive Codex's Responses item round trip.
    var geminiThoughtSignatures: [String: String] = [:]
    var cooldownUntilByAccountID: [String: Int64] = [:]

    private let models = SwiftNativeProxyRuntimeService.clientVisibleModels

    init(
        paths: FileSystemPaths,
        storeRepository: AccountsStoreRepository,
        settingsRepository: SettingsRepository,
        authRepository: AuthRepository,
        providerRepository: ProviderStoreRepository? = nil,
        usageRepository: ThirdPartyUsageRepository? = nil,
        onAccountsStoreChanged: (@Sendable () -> Void)? = nil,
        switchAccount: (@Sendable (String) async throws -> Void)? = nil,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.paths = paths
        self.storeRepository = storeRepository
        self.settingsRepository = settingsRepository
        self.authRepository = authRepository
        self.providerRepository = providerRepository
        self.usageRepository = usageRepository
        self.onAccountsStoreChanged = onAccountsStoreChanged
        self.switchAccount = switchAccount
        self.dateProvider = dateProvider
    }

    func status() async -> ApiProxyStatus {
        let running = server != nil
        let apiKey = try? ensurePersistedAPIKey()
        let availableAccounts = (try? currentCandidates().count) ?? -1

        return ApiProxyStatus(
            running: running,
            port: running ? runningPort : nil,
            apiKey: apiKey,
            baseURL: runningPort.map { "http://127.0.0.1:\($0)/v1" },
            availableAccounts: availableAccounts,
            activeAccountID: activeAccountID,
            activeAccountLabel: activeAccountLabel,
            lastError: lastError
        )
    }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        if server != nil {
            return await status()
        }

        let requestedPort = preferredPort ?? 8787
        guard requestedPort > 0 && requestedPort < 65536 else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_port_format", String(requestedPort)))
        }

        _ = try ensurePersistedAPIKey()

        var boundServer: SimpleHTTPServer?
        var selectedPort: Int?
        var lastStartError: Error?

        // A stale local development service or another app may already own
        // 8787. Try a small deterministic range instead of making the proxy
        // unusable; the actual selected port is returned in ApiProxyStatus.
        for port in Self.proxyPortCandidates(preferredPort: requestedPort) {
            var candidate: SimpleHTTPServer?
            do {
                candidate = try SimpleHTTPServer(port: UInt16(port)) { [weak self] request in
                    guard let self else {
                        return HTTPResponse.json(statusCode: 500, object: ["error": ["message": "Proxy runtime unavailable"]])
                    }
                    return await self.handle(request: request)
                }
                try await candidate?.start()
                boundServer = candidate
                selectedPort = port
                break
            } catch {
                candidate?.stop()
                lastStartError = error
            }
        }

        guard let boundServer, let selectedPort else {
            let detail = lastStartError?.localizedDescription ?? L10n.tr("error.proxy_runtime.start_failed")
            lastError = L10n.tr("error.proxy_runtime.start_swift_proxy_failed_format", detail)
            // Never leave Codex pointing at a port nothing is listening on.
            try? CodexModelsCacheService(paths: paths).removeProxyRouting()
            throw AppError.io(lastError ?? detail)
        }

        server = boundServer
        runningPort = selectedPort
        lastError = nil

        let healthy = await waitForHealth(port: selectedPort)
        if !healthy {
            _ = await stop()
            lastError = L10n.tr("error.proxy_runtime.health_check_failed")
            throw AppError.io(lastError ?? L10n.tr("error.proxy_runtime.start_failed"))
        }

        // Only route Codex here once the port is confirmed serving.
        applyCodexProxyRouting(port: selectedPort)

        return await status()
    }

    static func proxyPortCandidates(preferredPort: Int, fallbackCount: Int = 10) -> [Int] {
        guard preferredPort > 0 && preferredPort < 65536 else { return [] }
        let upperBound = min(65535, preferredPort + max(0, fallbackCount))
        return Array(preferredPort...upperBound)
    }

    /// Points Codex at this proxy so third-party models resolve to a provider
    /// instead of chatgpt.com. Applied unconditionally while the proxy runs:
    /// gating it on "has third-party providers" would leave routing stale when
    /// providers are added later, and native models are already meant to flow
    /// through the proxy for account failover.
    private func applyCodexProxyRouting(port: Int) {
        try? CodexModelsCacheService(paths: paths).applyProxyRouting(port: port)
    }

    func stop() async -> ApiProxyStatus {
        server?.stop()
        server = nil
        runningPort = nil
        try? CodexModelsCacheService(paths: paths).removeProxyRouting()
        activeAccountID = nil
        activeAccountLabel = nil
        stickyAccountID = nil
        cooldownUntilByAccountID = [:]
        return await status()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        let key = randomAPIKey()
        try persistAPIKey(key)
        return await status()
    }

    func syncAccountsStore() async throws {
        // Swift native runtime reads the same app store source directly.
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" && request.method == "GET" {
            return HTTPResponse.json(statusCode: 200, object: ["ok": true])
        }

        // Codex attempts a WebSocket transport for /v1/responses when the base
        // URL points at a local gateway. We only speak HTTP, so answer 426
        // (Upgrade Required) — opencodex does the same — which makes Codex
        // fall back to plain HTTP responses. Connection: close is required for
        // the fallback to trigger.
        if isWebSocketUpgrade(request) {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "error": [
                    "message": "Responses WebSocket transport is disabled; use HTTP",
                    "type": "upgrade_required",
                ],
            ])) ?? Data("{}".utf8)
            return HTTPResponse(
                statusCode: 426,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Sec-WebSocket-Version": "13",
                ],
                body: body
            )
        }

        guard isAuthorized(request.headers) else {
            return jsonError(statusCode: 401, message: "Invalid proxy api key.")
        }

        if request.path == "/v1/models" && request.method == "GET" {
            var list = models.map { model in
                [
                    "id": model,
                    "object": "model",
                    "created": 0,
                    "owned_by": "openai"
                ] as [String: Any]
            }
            for clientModelID in thirdPartyClientModelIDs() {
                list.append([
                    "id": clientModelID,
                    "object": "model",
                    "created": 0,
                    "owned_by": "third-party"
                ])
            }
            return HTTPResponse.json(statusCode: 200, object: ["object": "list", "data": list])
        }

        if request.path == "/v1/responses" && request.method == "POST" {
            return await handleResponsesRequest(body: request.body, downstreamHeaders: request.headers)
        }

        if request.path == "/v1/chat/completions" && request.method == "POST" {
            return await handleChatCompletionsRequest(body: request.body, downstreamHeaders: request.headers)
        }

        return jsonError(
            statusCode: 404,
            message: L10n.tr("error.proxy_runtime.unsupported_route")
        )
    }

    private func handleResponsesRequest(body: Data, downstreamHeaders: [String: String]) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let requestedModel = (object["model"] as? String) ?? "gpt-5"
        if let route = try? resolveThirdPartyRoute(for: requestedModel) {
            return await handleThirdPartyRequest(
                route: route,
                body: body,
                object: object,
                downstreamHeaders: downstreamHeaders,
                asResponses: route.protocolKind == .responses,
                clientWantsResponses: true
            )
        }

        let payload: [String: Any]
        let downstreamStream: Bool
        do {
            let normalized = try normalizeResponsesRequest(object)
            payload = normalized.payload
            downstreamStream = normalized.downstreamStream
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        if downstreamStream {
            do {
                return try await makeResponsesStreamingHTTPResponse(
                    payload: payload,
                    downstreamHeaders: downstreamHeaders
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        do {
            let completed = try extractCompletedResponse(fromSSE: upstream.body)
            let rewritten = rewriteResponseModelFields(completed)
            return HTTPResponse.json(statusCode: 200, object: rewritten)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func handleChatCompletionsRequest(body: Data, downstreamHeaders: [String: String]) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let requestedModel = (object["model"] as? String) ?? "gpt-5"
        if let route = try? resolveThirdPartyRoute(for: requestedModel) {
            return await handleThirdPartyRequest(
                route: route,
                body: body,
                object: object,
                downstreamHeaders: downstreamHeaders,
                asResponses: route.protocolKind == .responses,
                clientWantsResponses: false
            )
        }

        let payload: [String: Any]
        let downstreamStream: Bool
        do {
            let normalized = try convertChatRequestToResponses(object)
            payload = normalized.payload
            downstreamStream = normalized.downstreamStream
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        if downstreamStream {
            do {
                return try await makeChatCompletionsStreamingHTTPResponse(
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    requestedModel: requestedModel
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        do {
            let completed = try extractCompletedResponse(fromSSE: upstream.body)
            let completion = convertCompletedResponseToChatCompletion(completed, fallbackModel: requestedModel)
            return HTTPResponse.json(statusCode: 200, object: completion)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    /// Forwards a request to a third-party provider without account failover.
    private func handleThirdPartyRequest(
        route: ThirdPartyRoute,
        body: Data,
        object: [String: Any],
        downstreamHeaders: [String: String],
        asResponses: Bool,
        clientWantsResponses: Bool
    ) async -> HTTPResponse {
        // Preserve the client's streaming preference; normalizeResponsesRequest
        // forces stream=true for the responses path, chat path honors it.
        // Responses clients always get SSE — the non-streaming branch answers
        // with a chat.completion object they cannot read.
        let wantsStream: Bool
        if clientWantsResponses {
            wantsStream = true
        } else {
            switch route.protocolKind {
            case .anthropic, .google:
                wantsStream = (object["stream"] as? Bool) ?? true
            case .responses:
                wantsStream = true
            case .chat:
                wantsStream = (object["stream"] as? Bool) ?? false
            }
        }

        if wantsStream {
            return await handleThirdPartyStreamingRequest(
                route: route,
                object: object,
                downstreamHeaders: downstreamHeaders,
                asResponses: asResponses,
                clientWantsResponses: clientWantsResponses
            )
        }

        do {
            let payload = try thirdPartyUpstreamPayload(
                route: route,
                object: object,
                asResponses: asResponses
            )

            let response = try await sendThirdPartyRequest(
                route: route,
                payload: payload,
                downstreamHeaders: downstreamHeaders
            )

            // Retry once with a refreshed token on auth failures for
            // subscription-imported providers (401/403).
            if response.statusCode == 401 || response.statusCode == 403 {
                if let refreshed = await refreshProviderTokenIfNeeded(route: route) {
                    let retried = try await sendThirdPartyRequest(
                        route: route,
                        payload: payload,
                        downstreamHeaders: downstreamHeaders,
                        apiKeyOverride: refreshed
                    )
                    if retried.statusCode >= 200 && retried.statusCode < 300 {
                        return self.thirdPartySuccessResponse(
                            route: route,
                            response: retried
                        )
                    }
                    return self.thirdPartyErrorResponse(route: route, response: retried)
                }
            }

            if response.statusCode >= 200 && response.statusCode < 300 {
                recordThirdPartyUsage(route: route, responseBody: response.body, statusCode: response.statusCode)
            } else {
                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let message = "\(route.provider.name): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                lastError = message
                return jsonError(statusCode: 502, message: message)
            }

            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: response.body)
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
            guard let decodedObject = decoded as? [String: Any] else {
                return HTTPResponse.json(statusCode: 200, object: decoded)
            }

            // Translate non-OpenAI responses into the chat.completion shape
            // the ChatGPT client expects.
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
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    /// Shapes the client request for the provider's wire protocol.
    ///
    /// Codex only speaks the Responses API, so chat / Anthropic / Gemini
    /// providers need the request converted back to the chat shape their
    /// adapters read.
    private func thirdPartyUpstreamPayload(
        route: ThirdPartyRoute,
        object: [String: Any],
        asResponses: Bool
    ) throws -> [String: Any] {
        if asResponses {
            return try normalizeResponsesRequest(object).payload
        }
        guard object["messages"] == nil, object["input"] != nil else { return object }
        return convertResponsesRequestToChat(object)
    }

    /// Streams a third-party response back to the client.
    private func handleThirdPartyStreamingRequest(
        route: ThirdPartyRoute,
        object: [String: Any],
        downstreamHeaders: [String: String],
        asResponses: Bool,
        clientWantsResponses: Bool
    ) async -> HTTPResponse {
        do {
            var payload = try thirdPartyUpstreamPayload(
                route: route,
                object: object,
                asResponses: asResponses
            )
            // This path only streams, so the upstream request must too.
            payload["stream"] = true

            var upstream = try await openThirdPartyStreamingRequest(
                route: route,
                payload: payload,
                downstreamHeaders: downstreamHeaders
            )

            // Retry once with a refreshed token on auth failures. ChatGPT.app
            // and Codex always stream, so without this the refresh path in
            // handleThirdPartyRequest never runs for real traffic.
            if upstream.statusCode == 401 || upstream.statusCode == 403,
               let refreshed = await refreshProviderTokenIfNeeded(route: route) {
                var discarded = 0
                for try await _ in upstream.bytes {
                    discarded += 1
                    if discarded > ProxyRuntimeLimits.maxUpstreamResponseBytes { break }
                }
                upstream = try await openThirdPartyStreamingRequest(
                    route: route,
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    apiKeyOverride: refreshed
                )
            }

            if !(upstream.statusCode >= 200 && upstream.statusCode < 300) {
                var buffered = Data()
                for try await byte in upstream.bytes {
                    buffered.append(byte)
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseBytes { break }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                let message = "\(route.provider.name): \(upstream.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                lastError = message
                return jsonError(statusCode: 502, message: message)
            }

            // Usage collected by protocol-specific streaming decoders.
            let protocolKind = route.protocolKind

            // Echo back the model the client asked for, not the internal
            // provider-qualified id.
            let clientModelID = (object["model"] as? String) ?? route.clientModelID
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                Task {
                    // Local mutable state, serial access within this task only.
                    let anthropicState = AnthropicStreamState()
                    let geminiState = GeminiStreamState()
                    // Codex speaks the Responses API, so chat-shaped chunks
                    // produced by the provider adapters get replayed as
                    // Responses events before they reach the client.
                    let responsesState = clientWantsResponses ? ChatToResponsesStreamState() : nil
                    // One decoder for the whole stream: SSE events span several
                    // lines, so rebuilding it per line would drop every event.
                    let sseDecoder = SSEStreamDecoder()
                    let emitChatChunk: ([String: Any]) -> Void = { chunk in
                        guard let responsesState else {
                            continuation.yield(Data("data: \(self.jsonString(chunk))\n\n".utf8))
                            return
                        }
                        for event in self.responsesEvents(
                            forChatChunk: chunk,
                            state: responsesState,
                            fallbackModel: clientModelID
                        ) {
                            continuation.yield(event)
                        }
                    }
                    let emitChatStreamEnd: ([String: Any]?) -> Void = { usage in
                        guard let responsesState else {
                            continuation.yield(Data("data: [DONE]\n\n".utf8))
                            return
                        }
                        if let usage { responsesState.usage = usage }
                        for event in self.responsesFinalEvents(
                            state: responsesState,
                            fallbackModel: clientModelID
                        ) {
                            continuation.yield(event)
                        }
                    }
                    do {
                        var iterator = upstream.bytes.makeAsyncIterator()
                        var buffer = Data()
                        var totalBytes = 0
                        while let byte = try await iterator.next() {
                            buffer.append(byte)
                            totalBytes += 1
                            if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                                throw AppError.network(
                                    L10n.tr(
                                        "error.proxy_runtime.upstream_response_too_large_format",
                                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                    )
                                )
                            }

                            if byte == 0x0A {
                                switch protocolKind {
                                case .anthropic:
                                    for chunk in consumeAnthropicSSEChunk(buffer, isFinal: false, state: anthropicState) {
                                        emitChatChunk(chunk)
                                    }
                                case .google:
                                    for chunk in consumeGeminiSSEChunk(buffer, isFinal: false, state: geminiState) {
                                        emitChatChunk(chunk)
                                    }
                                case .responses:
                                    for eventData in consumeResponsesPassthroughSSEChunk(
                                        sseDecoder,
                                        data: buffer,
                                        isFinal: false
                                    ) {
                                        continuation.yield(eventData)
                                    }
                                case .chat:
                                    for chunk in consumeUpstreamChatSSEChunk(
                                        sseDecoder,
                                        data: buffer,
                                        isFinal: false,
                                        clientModel: clientModelID
                                    ) {
                                        emitChatChunk(chunk)
                                    }
                                }
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }

                        switch protocolKind {
                        case .anthropic:
                            for chunk in consumeAnthropicSSEChunk(buffer, isFinal: true, state: anthropicState) {
                                emitChatChunk(chunk)
                            }
                            emitChatStreamEnd(anthropicStreamUsage(anthropicState))
                            recordStreamingThirdPartyUsage(route: route, usage: anthropicStreamUsage(anthropicState))
                        case .google:
                            for chunk in consumeGeminiSSEChunk(buffer, isFinal: true, state: geminiState) {
                                emitChatChunk(chunk)
                            }
                            emitChatStreamEnd(geminiStreamUsage(geminiState))
                            recordStreamingThirdPartyUsage(route: route, usage: geminiStreamUsage(geminiState))
                        case .responses:
                            for eventData in consumeResponsesPassthroughSSEChunk(
                                sseDecoder,
                                data: buffer,
                                isFinal: true
                            ) {
                                continuation.yield(eventData)
                            }
                            recordStreamingThirdPartyUsage(route: route, usage: nil)
                        case .chat:
                            for chunk in consumeUpstreamChatSSEChunk(
                                sseDecoder,
                                data: buffer,
                                isFinal: true,
                                clientModel: clientModelID
                            ) {
                                emitChatChunk(chunk)
                            }
                            emitChatStreamEnd(nil)
                            recordStreamingThirdPartyUsage(route: route, usage: nil)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }

            return HTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Cache-Control": "no-cache"
                ],
                body: stream
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    /// Feeds one SSE frame into the Anthropic translator.
    private func consumeAnthropicSSEChunk(
        _ data: Data,
        isFinal: Bool,
        state: AnthropicStreamState
    ) -> [[String: Any]] {
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: data, isFinal: isFinal)
        return events.flatMap { translateAnthropicSSEEvent($0, state: state) }
    }

    /// Feeds one SSE frame into the Gemini translator.
    private func consumeGeminiSSEChunk(
        _ data: Data,
        isFinal: Bool,
        state: GeminiStreamState
    ) -> [[String: Any]] {
        // Gemini sends `data: {json}` lines; split frames and translate each.
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        var chunks: [[String: Any]] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            chunks.append(contentsOf: translateGeminiSSEChunk(payload, state: state))
        }
        return chunks
    }

    /// Best-effort usage record for streaming third-party requests, using the
    /// token counts captured by the protocol decoder when available.
    private func recordStreamingThirdPartyUsage(route: ThirdPartyRoute, usage: [String: Any]?) {
        guard let usageRepository else { return }
        guard let store = try? usageRepository.loadUsage() else { return }
        var mutated = store
        let prompt = (usage?["prompt_tokens"] as? Int) ?? 0
        let completion = (usage?["completion_tokens"] as? Int) ?? 0
        mutated.record(
            providerID: route.provider.id,
            providerName: route.provider.name,
            modelID: route.backendModel,
            promptTokens: prompt,
            completionTokens: completion,
            at: dateProvider.unixSecondsNow()
        )
        try? usageRepository.saveUsage(mutated)
    }

    private func sendOverCandidates(payload: [String: Any], downstreamHeaders: [String: String]) async throws -> UpstreamResponse {
        let candidates = try currentCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        for candidate in candidates {
            do {
                let response = try await sendUpstream(payload: payload, candidate: candidate, downstreamHeaders: downstreamHeaders)
                if response.statusCode >= 200 && response.statusCode < 300 {
                    try await recordSuccessfulCandidate(candidate)
                    return response
                }

                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    markCooldown(for: candidate.accountID, category: retryFailure.category)
                    retryFailures.append(retryFailure)
                    continue
                } else {
                    lastError = detail
                    break
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
            }
        }

        if !retryFailures.isEmpty && retryFailures.count == candidates.count {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            throw AppError.network(message)
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        throw AppError.network(message)
    }

    private func sendStreamingOverCandidates(
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamStreamingResponse {
        let candidates = try currentCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        for candidate in candidates {
            do {
                let response = try await openStreamingUpstreamRequest(
                    payload: payload,
                    candidate: candidate,
                    downstreamHeaders: downstreamHeaders
                )

                if response.statusCode >= 200 && response.statusCode < 300 {
                    try await recordSuccessfulCandidate(candidate)
                    return response
                }

                var buffered = Data()
                for try await byte in response.bytes {
                    buffered.append(byte)
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                        break
                    }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    markCooldown(for: candidate.accountID, category: retryFailure.category)
                    retryFailures.append(retryFailure)
                    continue
                } else {
                    lastError = detail
                    break
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
            }
        }

        if !retryFailures.isEmpty && retryFailures.count == candidates.count {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            throw AppError.network(message)
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        throw AppError.network(message)
    }

    private func makeResponsesStreamingHTTPResponse(
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> HTTPResponse {
        let upstream = try await sendStreamingOverCandidates(
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let decoder = makeResponsesPassthroughSSEStreamDecoder()

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var iterator = upstream.bytes.makeAsyncIterator()
                    var buffer = Data()
                    var totalBytes = 0

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        totalBytes += 1
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                )
                            )
                        }

                        if byte == 0x0A {
                            for eventData in consumeResponsesPassthroughSSEChunk(decoder, data: buffer, isFinal: false) {
                                continuation.yield(eventData)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    for eventData in consumeResponsesPassthroughSSEChunk(decoder, data: buffer, isFinal: true) {
                        continuation.yield(eventData)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: stream
        )
    }

    private func makeChatCompletionsStreamingHTTPResponse(
        payload: [String: Any],
        downstreamHeaders: [String: String],
        requestedModel: String
    ) async throws -> HTTPResponse {
        let upstream = try await sendStreamingOverCandidates(
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let decoder = makeChatCompletionsSSEStreamDecoder(fallbackModel: requestedModel)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var iterator = upstream.bytes.makeAsyncIterator()
                    var buffer = Data()
                    var totalBytes = 0

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        totalBytes += 1
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                )
                            )
                        }

                        if byte == 0x0A {
                            let chunks = try consumeChatCompletionsSSEStreamChunk(
                                decoder,
                                data: buffer,
                                isFinal: false
                            )
                            for chunk in chunks {
                                continuation.yield(Data("data: \(jsonString(chunk))\n\n".utf8))
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    let finalChunks = try consumeChatCompletionsSSEStreamChunk(
                        decoder,
                        data: buffer,
                        isFinal: true
                    )
                    for chunk in finalChunks {
                        continuation.yield(Data("data: \(jsonString(chunk))\n\n".utf8))
                    }
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: stream
        )
    }

    private func parseJSONObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.request_body_must_be_object"))
        }
        return dict
    }

    func rewriteResponseModelFields(_ value: [String: Any]) -> [String: Any] {
        var output: Any = value
        recurseNormalizeModels(&output)
        return output as? [String: Any] ?? value
    }

    private func recurseNormalizeModels(_ any: inout Any) {
        if var dict = any as? [String: Any] {
            for key in dict.keys {
                if key == "model", let model = dict[key] as? String {
                    dict[key] = normalizeModelForClient(model)
                } else if var child = dict[key] {
                    recurseNormalizeModels(&child)
                    dict[key] = child
                }
            }
            any = dict
            return
        }

        if var array = any as? [Any] {
            for index in array.indices {
                var child = array[index]
                recurseNormalizeModels(&child)
                array[index] = child
            }
            any = array
        }
    }

    func truncateForError(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return "\(value[..<index])..."
    }

    /// True when the request is a WebSocket upgrade (Codex's responses
    /// transport). Answered with 426 so Codex falls back to HTTP.
    func isWebSocketUpgrade(_ request: HTTPRequest) -> Bool {
        let connection = request.headers["connection"]?.lowercased() ?? ""
        let upgrade = request.headers["upgrade"]?.lowercased() ?? ""
        return connection.contains("upgrade") || upgrade == "websocket"
    }

    func jsonString(_ object: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    func jsonError(statusCode: Int, message: String) -> HTTPResponse {
        HTTPResponse.json(statusCode: statusCode, object: [
            "error": [
                "message": message,
                "type": statusCode == 400 ? "invalid_request_error" : "server_error"
            ]
        ])
    }

    func normalizedClientModelToken(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func normalizedNumericModelRevisionIfNeeded(_ normalizedModel: String) -> String {
        guard normalizedModel.hasPrefix("gpt-5-") else {
            return normalizedModel
        }

        let suffix = String(normalizedModel.dropFirst("gpt-5-".count))
        guard let firstSegment = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              !firstSegment.isEmpty,
              firstSegment.allSatisfy(\.isNumber) else {
            return normalizedModel
        }

        let afterRevision = String(suffix.dropFirst(firstSegment.count))
        return "gpt-5.\(firstSegment)\(afterRevision)"
    }

    func currentUnixSeconds() -> Int64 {
        dateProvider.unixSecondsNow()
    }

    func currentUnixMilliseconds() -> Int64 {
        dateProvider.unixMillisecondsNow()
    }

    func cooldownDuration(for category: RetryFailureCategory) -> Int64 {
        switch category {
        case .rateLimited:
            return 60
        case .quotaExceeded, .modelRestricted, .authentication, .permission:
            return 300
        }
    }

    func markCooldown(for accountID: String, category: RetryFailureCategory) {
        cooldownUntilByAccountID[accountID] = currentUnixSeconds() + cooldownDuration(for: category)
        if stickyAccountID == accountID {
            stickyAccountID = nil
        }
    }

    func recordSuccessfulCandidate(_ candidate: ProxyCandidate) async throws {
        let storeBefore = try storeRepository.loadStore()
        AccountSwitchDebugLog.write(
            "proxy.recordSuccessfulCandidate.begin",
            "candidateCardID=\(candidate.id) accountID=\(candidate.accountID) accountKey=\(candidate.accountKey) before=\(AccountSwitchDebugLog.describe(store: storeBefore, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        activeAccountID = candidate.accountID
        activeAccountLabel = candidate.label
        stickyAccountID = candidate.accountID
        cooldownUntilByAccountID.removeValue(forKey: candidate.accountID)
        guard storeBefore.accounts.contains(where: { $0.id == candidate.id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }
        if storeBefore.currentAccountID != candidate.id {
            guard let switchAccount else {
                throw AppError.invalidData("Proxy runtime is missing the account switch handler.")
            }
            try await switchAccount(candidate.id)
        }
        let storeAfter = try storeRepository.loadStore()
        cachedCandidatesStoreModificationDate = nil
        onAccountsStoreChanged?()
        lastError = nil
        AccountSwitchDebugLog.write(
            "proxy.recordSuccessfulCandidate.end",
            "candidateCardID=\(candidate.id) after=\(AccountSwitchDebugLog.describe(store: storeAfter, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

}
