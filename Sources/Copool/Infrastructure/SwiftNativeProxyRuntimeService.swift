import Foundation

actor SwiftNativeProxyRuntimeService: ProxyRuntimeService, RouterEngine {
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
    let agentRepository: AgentProfileRepository?
    let rateLimitRepository: ProviderRateLimitFileRepository?
    let usageLedger: UsageEventLedger?
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
    /// Subagent turn id -> chosen route, so a child's follow-up turns stay on
    /// the model it started with.
    var agentRouteBindings: [String: AgentRouteBinding] = [:]

    private let models = SwiftNativeProxyRuntimeService.clientVisibleModels
    let v2RouteResolver: V2RouteResolver?
    /// 把真实请求结果写回凭据健康状态（FR-IDT-07）。nil 表示没有 v2 注册表，
    /// 此时凭据状态无处可写——v1-only 的用户不受影响。
    let credentialHealthWriter: CredentialHealthWriter?

    init(
        paths: FileSystemPaths,
        storeRepository: AccountsStoreRepository,
        settingsRepository: SettingsRepository,
        authRepository: AuthRepository,
        providerRepository: ProviderStoreRepository? = nil,
        usageRepository: ThirdPartyUsageRepository? = nil,
        agentRepository: AgentProfileRepository? = nil,
        rateLimitRepository: ProviderRateLimitFileRepository? = nil,
        usageLedger: UsageEventLedger? = nil,
        v2RouteResolver: V2RouteResolver? = nil,
        credentialHealthWriter: CredentialHealthWriter? = nil,
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
        self.agentRepository = agentRepository
        self.rateLimitRepository = rateLimitRepository
        self.usageLedger = usageLedger
        self.v2RouteResolver = v2RouteResolver
        self.credentialHealthWriter = credentialHealthWriter
        self.onAccountsStoreChanged = onAccountsStoreChanged
        self.switchAccount = switchAccount
        self.dateProvider = dateProvider
    }

    /// 分流三态（A2）。托管块是唯一事实来源——内存里的 `server` 在进程被强杀
    /// 后一起消失，只看它会把"托管块还指着死端口"误报成干净的已停止。
    func providerSplitState() -> ProviderSplitState {
        let installedPort = CodexModelsCacheService(paths: paths).installedRoutingPort()
        switch (server != nil, installedPort) {
        case (true, let installed?):
            // 端口不符也算不一致：代理换端口重启后，托管块指向的旧端口没人听。
            return installed == runningPort ? .active : .inconsistent
        case (true, nil):
            // 代理在跑但托管块不在，第三方模型同样走不通，仍需重新写入。
            return .inconsistent
        case (false, .some):
            return .inconsistent
        case (false, nil):
            return .degraded
        }
    }

    /// 把不一致态收敛掉：托管块指向没人监听的端口时剥离它（A2 自愈）。
    ///
    /// 返回是否真的做了剥离，让调用方决定要不要提示用户——静默恢复不需要打扰，
    /// 但从"能用"变成"不能用"必须说明（A3）。
    @discardableResult
    func reconcileProviderSplit() -> Bool {
        guard server == nil, CodexModelsCacheService(paths: paths).installedRoutingPort() != nil else {
            return false
        }
        try? CodexModelsCacheService(paths: paths).removeProxyRouting()
        return true
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

    // MARK: - RouterEngine (vNext façade)

    func engineStatus() async -> RouterEngineStatus {
        let proxy = await status()
        return RouterEngineStatus(
            running: proxy.running,
            port: proxy.port,
            apiKey: proxy.apiKey,
            baseURL: proxy.baseURL,
            availableAccounts: proxy.availableAccounts,
            activeAccountID: proxy.activeAccountID,
            activeAccountLabel: proxy.activeAccountLabel,
            lastError: proxy.lastError
        )
    }

    nonisolated var engineCapabilities: RouterEngineCapabilities {
        RouterEngineCapabilities(
            transports: ["http"],
            supportedPaths: ["/health", "/v1/models", "/v1/responses", "/v1/chat/completions", "/v1/images/generations", "/v1/images/edits"],
            maxInboundRequestBytes: ProxyRuntimeLimits.maxInboundRequestDecodedBytes
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
        // Browser origins are never allowed (AC-009): the proxy answers only
        // loopback clients, never emits CORS headers, and rejects a browser
        // Origin outright so a malicious page cannot drive the router.
        if let origin = request.headers["origin"], !origin.isEmpty {
            return jsonError(statusCode: 403, message: "Browser origin rejected")
        }

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
            guard let body = decompressRequestBody(request) else {
                return jsonError(statusCode: 415, message: "Unsupported content encoding or malformed compressed body.")
            }
            return await handleResponsesRequest(body: body, downstreamHeaders: request.headers, path: request.path)
        }

        if request.path == "/v1/chat/completions" && request.method == "POST" {
            guard let body = decompressRequestBody(request) else {
                return jsonError(statusCode: 415, message: "Unsupported content encoding or malformed compressed body.")
            }
            return await handleChatCompletionsRequest(body: body, downstreamHeaders: request.headers)
        }

        // Image generation/editing always goes to the native OpenAI backend,
        // never to a third-party provider (mirroring codex-router).
        if (request.path == "/v1/images/generations" || request.path == "/v1/images/edits")
            && request.method == "POST" {
            guard let body = decompressRequestBody(request) else {
                return jsonError(statusCode: 415, message: "Unsupported content encoding or malformed compressed body.")
            }
            return await handleNativeImageRequest(
                endpointPath: String(request.path.dropFirst(4)),
                body: body,
                downstreamHeaders: request.headers
            )
        }

        return jsonError(
            statusCode: 404,
            message: L10n.tr("error.proxy_runtime.unsupported_route")
        )
    }

    /// Forwards an image request verbatim to the native OpenAI backend.
    ///
    /// Codex never routes these through a third-party provider, so neither do
    /// we — the request is sent over the account candidates like any native
    /// call, with only the selected account's credentials attached.
    private func handleNativeImageRequest(
        endpointPath: String,
        body: Data,
        downstreamHeaders: [String: String]
    ) async -> HTTPResponse {
        guard let object = try? parseJSONObject(from: body) else {
            return jsonError(statusCode: 400, message: "Invalid JSON body.")
        }
        do {
            let response = try await sendOverCandidates(
                payload: object,
                downstreamHeaders: downstreamHeaders,
                endpointPath: endpointPath
            )
            return HTTPResponse(
                statusCode: response.statusCode,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: response.body
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    /// Inflates a request body according to its `Content-Encoding`.
    ///
    /// Codex CLI compresses Responses bodies with zstd by default, so this is
    /// on the hot path; gzip/deflate/brotli are decoded for generic
    /// OpenAI-compatible clients. Returns nil for unknown encodings or
    /// malformed frames, which the caller maps to 415.
    ///
    /// SEC-11：解码后超出 maxInboundRequestDecodedBytes 的炸弹攻击由各解压器
    /// 内部检测并返回 nil；这里只需要在调用前检查编码前大小。
    private func decompressRequestBody(_ request: HTTPRequest) -> Data? {
        let encoding = (request.headers["content-encoding"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !encoding.isEmpty, encoding != "identity" else { return request.body }

        // 第一道限制：编码前（压缩状态）大小。
        if request.body.count > ProxyRuntimeLimits.maxInboundRequestEncodedBytes {
            return nil
        }

        switch encoding {
        case "zstd":
            return ZstdDecompression.decompress(request.body)
        case "gzip":
            return LibzDecompression.decompressGzipOrZlib(request.body)
        case "deflate":
            // RFC 7230 says deflate is a zlib wrapper; some clients send raw.
            return LibzDecompression.decompressGzipOrZlib(request.body)
                ?? LibzDecompression.decompressRawDeflate(request.body)
        case "br":
            return BrotliDecompression.decompress(request.body)
        default:
            return nil
        }
    }

    private func handleResponsesRequest(body: Data, downstreamHeaders: [String: String], path: String = "/v1/responses") async -> HTTPResponse {
        var object: [String: Any]
        do {
            object = try parseJSONObject(from: body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        // Routed compaction: Codex asks the proxy to checkpoint a long session
        // into a continuation summary instead of sending the full history.
        let compaction = Self.isCompactionRequest(path: path, object: object)
        if compaction.v1 || compaction.v2 {
            let requestedModel = (object["model"] as? String) ?? ""
            let routeContext = routeRequestContext(from: object)
            if let route = try? resolveThirdPartyRoute(for: requestedModel, context: routeContext) {
                return await handleCompactionRequest(
                    route: route,
                    object: object,
                    v1: compaction.v1,
                    v2: compaction.v2
                )
            }
            // Native models compact through ChatGPT's own backend; nothing to
            // do here — fall through to the normal path.
        }

        // A Codex subagent turn may be redirected onto a model the user picked
        // for that kind of work. The parent turn is never touched.
        var body = body
        if let route = resolveAgentRoute(headers: downstreamHeaders, object: object) {
            object = Self.applyAgentRoute(route, to: object)
            if let rerouted = try? JSONSerialization.data(withJSONObject: object) {
                body = rerouted
            }
        }

        let requestedModel = (object["model"] as? String) ?? "gpt-5"
        let routeContext = routeRequestContext(from: object)
        if let route = try? resolveThirdPartyRoute(for: requestedModel, context: routeContext) {
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
        let routeContext = routeRequestContext(from: object)
        if let route = try? resolveThirdPartyRoute(for: requestedModel, context: routeContext) {
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

        // FR-RTE-05：耗时从"准备发出"开始计，不含路由解析——用户在路由 tab 里
        // 看这一列是为了判断上游快不慢，把本地打分的耗时混进去会污染这个判断。
        let startedAt = ContinuousClock.now
        do {
            let payload = try thirdPartyUpstreamPayload(
                route: route,
                object: object,
                asResponses: asResponses
            )

            let firstResponse = try await sendThirdPartyRequestWithRetry(
                route: route,
                payload: payload,
                downstreamHeaders: downstreamHeaders,
                object: object
            )

            // FR-RTE-04：同凭据的机会用尽后才谈转移。是否值得转移由失败分类
            // 决定（请求体错误、凭据失效不转移），`sendWithFailover` 内部判断；
            // 成功时它原样返回，不产生任何额外调用。
            var failoverAttempts: [String] = []
            var failoverFailures: [String] = []
            // 实际把这次请求发出去的那条路由。转移成功时它不是 `route`，
            // 用量与限流必须记在真正被调用的那一家头上——记错了，用户看到的
            // 是一份和账单对不上的用量表。
            var servingRoute = route
            let response: UpstreamResponse
            if firstResponse.statusCode >= 200 && firstResponse.statusCode < 300 {
                response = firstResponse
            } else {
                let failover = await sendWithFailover(
                    route: route,
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    object: object,
                    primaryResponse: firstResponse,
                    primaryError: nil
                )
                failoverAttempts = failover.attempts
                failoverFailures = failover.failures
                if let servedBy = failover.servedBy { servingRoute = servedBy }
                if let failoverResponse = failover.response {
                    response = failoverResponse
                } else if let failoverError = failover.error {
                    throw failoverError
                } else {
                    response = firstResponse
                }
            }

            if response.statusCode >= 200 && response.statusCode < 300 {
                recordThirdPartyUsage(route: servingRoute, responseBody: response.body, statusCode: response.statusCode)
                captureRateLimits(from: response.headers, route: servingRoute)
                recordUsageEvent(
                    route: servingRoute,
                    status: response.statusCode,
                    durationMs: 0,
                    tokens: Self.tokenUsage(fromResponseBody: response.body)
                )
                completeRouteTrace(
                    route: route,
                    startedAt: startedAt,
                    outcome: .succeeded,
                    httpStatus: response.statusCode,
                    fallbackAttempts: failoverAttempts,
                    // 转移成功时失败链仍要留着：这条请求确实先失败过，那是用户
                    // 排查"为什么这次特别慢"时唯一的线索。
                    failureChain: failoverFailures
                )
            } else {
                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let message = "\(route.provider.name): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                lastError = message
                // 落 trace 的失败原因必须脱敏（INV-1）：上游错误体里经常带 key
                // 片段和账号邮箱，而 route-decisions.jsonl 会进支持包。
                completeRouteTrace(
                    route: route,
                    startedAt: startedAt,
                    outcome: .failed,
                    httpStatus: response.statusCode,
                    fallbackAttempts: failoverAttempts,
                    failureChain: failoverFailures.isEmpty
                        ? [SecretRedactor.redactText(message)]
                        : failoverFailures
                )
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
            completeRouteTrace(
                route: route,
                startedAt: startedAt,
                outcome: .failed,
                failureChain: [SecretRedactor.redactText(error.localizedDescription)]
            )
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
        // FR-RTE-05：流式请求的耗时必须算到**流结束**，不是算到返回
        // `HTTPResponse` 那一刻——后者只是首字节到达，一个跑了 40 秒的长回复
        // 会被记成 200ms，这一列就完全没有参考价值了。所以回填放在流的
        // 收尾处，不在这个函数里。
        let startedAt = ContinuousClock.now
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
                    if discarded > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes { break }
                }
                upstream = try await openThirdPartyStreamingRequest(
                    route: route,
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    apiKeyOverride: refreshed
                )
            }

            // 这条路由实际把流发出来的那一家。转移成功后用量、限流、以及下面
            // 各协议解码器读的 `protocolKind` 都必须跟着换。
            var servingRoute = route
            var failoverAttempts: [String] = []
            var failoverFailures: [String] = []

            if !(upstream.statusCode >= 200 && upstream.statusCode < 300) {
                var buffered = Data()
                for try await byte in upstream.bytes {
                    buffered.append(byte)
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes { break }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                // 流没开起来：状态码与错误体都齐了，这是判定凭据健康最可靠的
                // 时刻（FR-IDT-07）。开流成功不在这里记——那时还不知道流会不会
                // 中途断掉。
                recordCredentialHealth(route: route, statusCode: upstream.statusCode, responseBody: buffered)

                // 流还没开起来，一个字节都没发给客户端——此刻换一家是干净的。
                // 一旦开始推送就绝不转移（FR-RTE-04 `.streamInterrupted`）。
                let failover = await openStreamWithFailover(
                    route: route,
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    object: object,
                    primaryStatus: upstream.statusCode,
                    primaryBodyText: bodyText
                )
                failoverAttempts = failover.attempts
                failoverFailures = failover.failures

                guard let recovered = failover.upstream, let servedBy = failover.servedBy else {
                    let message = "\(route.provider.name): \(upstream.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                    lastError = message
                    completeRouteTrace(
                        route: route,
                        startedAt: startedAt,
                        outcome: .failed,
                        httpStatus: upstream.statusCode,
                        fallbackAttempts: failoverAttempts,
                        failureChain: failoverFailures.isEmpty
                            ? [SecretRedactor.redactText(message)]
                            : failoverFailures
                    )
                    return jsonError(statusCode: 502, message: message)
                }
                upstream = recovered
                servingRoute = servedBy
            }

            // Usage collected by protocol-specific streaming decoders.
            let protocolKind = servingRoute.protocolKind
            captureRateLimits(from: upstream.headers, route: servingRoute)

            // Echo back the model the client asked for, not the internal
            // provider-qualified id.
            let clientModelID = (object["model"] as? String) ?? route.clientModelID
            // 流的收尾在逃逸的 Task 里，`var` 捕不进去。在这里定格成不可变副本：
            // 用量记给真正发出请求的那一家，trace 回填仍走首选——只有首选带着
            // `traceRequestID`，那条 trace 才是这次请求在账本里的唯一一行。
            let usageRoute = servingRoute
            let traceRoute = route
            let traceFallbackAttempts = failoverAttempts
            let traceFailureChain = failoverFailures
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
                            if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes {
                                throw AppError.network(
                                    L10n.tr(
                                        "error.proxy_runtime.upstream_response_too_large_format",
                                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes)
                                    )
                                )
                            }

                            if byte == 0x0A {
                                switch protocolKind {
                                case .anthropic:
                                    for chunk in consumeAnthropicSSEChunk(
                                        buffer,
                                        isFinal: false,
                                        state: anthropicState,
                                        emitsReasoning: !clientWantsResponses
                                    ) {
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
                            for chunk in consumeAnthropicSSEChunk(
                                buffer,
                                isFinal: true,
                                state: anthropicState,
                                emitsReasoning: !clientWantsResponses
                            ) {
                                emitChatChunk(chunk)
                            }
                            emitChatStreamEnd(anthropicStreamUsage(anthropicState))
                            recordStreamingThirdPartyUsage(route: usageRoute, usage: anthropicStreamUsage(anthropicState))
                        case .google:
                            for chunk in consumeGeminiSSEChunk(buffer, isFinal: true, state: geminiState) {
                                emitChatChunk(chunk)
                            }
                            emitChatStreamEnd(geminiStreamUsage(geminiState))
                            recordStreamingThirdPartyUsage(route: usageRoute, usage: geminiStreamUsage(geminiState))
                        case .responses:
                            for eventData in consumeResponsesPassthroughSSEChunk(
                                sseDecoder,
                                data: buffer,
                                isFinal: true
                            ) {
                                continuation.yield(eventData)
                            }
                            recordStreamingThirdPartyUsage(route: usageRoute, usage: nil)
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
                            recordStreamingThirdPartyUsage(route: usageRoute, usage: nil)
                        }
                        continuation.finish()
                        // 流真正跑完才算这把凭据可用（FR-IDT-07）。记在
                        // `usageRoute` 上：转移后真正被调用的是它，把成功记给
                        // 首选会让一把刚失败的凭据显示成"刚刚验证通过"。
                        self.recordCredentialHealth(route: usageRoute, statusCode: 200, responseBody: nil)
                        self.completeRouteTrace(
                            route: traceRoute,
                            startedAt: startedAt,
                            outcome: .succeeded,
                            httpStatus: upstream.statusCode,
                            fallbackAttempts: traceFallbackAttempts,
                            // 转移成功也把失败链留着：这条请求确实先失败过，
                            // 那是"为什么这次特别慢"唯一的线索。
                            failureChain: traceFailureChain
                        )
                    } catch {
                        // FR-RTE-04 `.streamInterrupted`：SSE 已开始后断开，显式
                        // error 事件收尾，不重试。
                        //
                        // `[DONE]` 只在下游线格式确实是 Chat Completions 时才发：
                        // Responses 协议没有这个 sentinel，多发一帧会让严格的
                        // 客户端把它当成一个畸形事件。protocolKind == .responses
                        // 时事件是原样透传的，下游看到的也是 Responses 格式。
                        let needsDone = !clientWantsResponses && protocolKind != .responses
                        continuation.yield(
                            SwiftNativeProxyRuntimeService.sseStreamInterruptedFrame(error, includeDoneSentinel: needsDone)
                        )
                        continuation.finish()
                        // 上游状态码是 2xx（流开起来了），失败发生在传输途中。
                        // 记 `.failed` 而不是 `.succeeded`：客户端拿到的是一段
                        // 被截断的回答，这不是成功。
                        self.completeRouteTrace(
                            route: traceRoute,
                            startedAt: startedAt,
                            outcome: .failed,
                            httpStatus: upstream.statusCode,
                            fallbackAttempts: traceFallbackAttempts,
                            failureChain: traceFailureChain
                                + [SecretRedactor.redactText(error.localizedDescription)]
                        )
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
            completeRouteTrace(
                route: route,
                startedAt: startedAt,
                outcome: .failed,
                failureChain: [SecretRedactor.redactText(error.localizedDescription)]
            )
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    /// Feeds one SSE frame into the Anthropic translator.
    private func consumeAnthropicSSEChunk(
        _ data: Data,
        isFinal: Bool,
        state: AnthropicStreamState,
        emitsReasoning: Bool = true
    ) -> [[String: Any]] {
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: data, isFinal: isFinal)
        return events.flatMap {
            translateAnthropicSSEEvent($0, state: state, emitsReasoning: emitsReasoning)
        }
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
        usageLedger?.record(
            UsageEvent(
                model: route.backendModel,
                providerID: route.provider.id,
                providerName: route.provider.name,
                status: 200,
                durationMs: 0,
                inputTokens: prompt,
                outputTokens: completion,
                totalTokens: prompt + completion
            )
        )
    }

    /// Passively harvests `x-ratelimit-*` / `anthropic-ratelimit-*` headers
    /// into the rate-limit store (codex-router's "no extra request" design).
    private func captureRateLimits(from headers: [String: String], route: ThirdPartyRoute) {
        guard let rateLimitRepository else { return }
        if let snapshot = RateLimitHeadersParser.parse(headers: headers, providerID: route.provider.id) {
            rateLimitRepository.record(snapshot)
        }
    }

    /// Appends one model-call fact to the usage ledger (never prompts or
    /// responses; see `UsageEvent`).
    private func recordUsageEvent(
        route: ThirdPartyRoute,
        status: Int,
        durationMs: Int,
        tokens: (input: Int?, output: Int?, total: Int?)?
    ) {
        guard let usageLedger else { return }
        usageLedger.record(
            UsageEvent(
                model: route.backendModel,
                providerID: route.provider.id,
                providerName: route.provider.name,
                status: status,
                durationMs: durationMs,
                inputTokens: tokens?.input,
                outputTokens: tokens?.output,
                totalTokens: tokens?.total
            )
        )
    }

    /// Extracts `usage` token counts from a completed (non-streaming) chat
    /// completion or Responses object, when the provider included them.
    static func tokenUsage(fromResponseBody body: Data) -> (input: Int?, output: Int?, total: Int?)? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        let input = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int
        let output = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int
        let total = usage["total_tokens"] as? Int
        return (input, output, total)
    }

    private func sendOverCandidates(
        payload: [String: Any],
        downstreamHeaders: [String: String],
        endpointPath: String? = nil
    ) async throws -> UpstreamResponse {
        let candidates = try currentCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        // AC-013 / FR-RTE-04: hard cap on total upstream attempts across
        // candidates. 6 = 最坏情况下一个候选用满 3 次（networkTimeout 的
        // 1+2）后，仍留有余量转移到别的候选，而不是把预算烧在第一个上。
        let maxTotalAttempts = 6
        // 单个候选上的尝试上限。实际次数由失败分类的
        // `maxRetriesOnSameCredential` 决定，这里只是兜底。
        let maxAttemptsPerCandidate = 3
        var totalAttempts = 0
        // Deterministic (non-classified) client errors must not be replayed
        // against other candidates — that is the legacy behavior (break all).
        var stopAllCandidates = false

        for candidate in candidates {
            if stopAllCandidates { break }
            // FR-RTE-04 per candidate：重试次数由失败分类决定，不再无差别
            // "总是重试一次"。attempt 从 1 开始计数，因此"第 N 次重试"对应
            // attempt == N + 1。
            var attempt = 0
            while attempt < maxAttemptsPerCandidate && totalAttempts < maxTotalAttempts && !stopAllCandidates {
                attempt += 1
                totalAttempts += 1
                do {
                    let response = try await sendUpstream(
                        payload: payload,
                        candidate: candidate,
                        downstreamHeaders: downstreamHeaders,
                        endpointPath: endpointPath
                    )
                    if response.statusCode >= 200 && response.statusCode < 300 {
                        try await recordSuccessfulCandidate(candidate)
                        return response
                    }

                    let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                    let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                    failureDetails.append(detail)

                    guard let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) else {
                        // FR-RTE-04 `.requestError`（400/404/422）：请求本身有问题，
                        // 换任何凭据都会收到同一个错误。原样透传，不重试不转移。
                        lastError = detail
                        stopAllCandidates = true
                        break
                    }
                    retryFailures.append(retryFailure)
                    let failureClass = retryFailure.failureClass
                    let retryAfter = Self.parseRetryAfter(headers: response.headers)
                    markCooldown(
                        for: candidate.accountID,
                        category: retryFailure.category,
                        retryAfterSeconds: retryAfter
                    )

                    // FR-RTE-04：401 → 零重试，标记凭据无权限。
                    //
                    // 这里**不**终止整个请求：候选池里的下一个是另一个账号、
                    // 另一份凭据，对它发请求不是"重试"而是转移。一个账号 token
                    // 过期就让用户整条请求失败，是把单点故障放大成全局故障。
                    // 规范里的"立即返回"约束的是同一凭据，而单凭据场景下这个
                    // 循环本来就只有一轮。
                    if failureClass.shouldMarkCredentialUnauthorized {
                        await markCandidateUnauthorized(candidate, reason: retryFailure.detail)
                        break
                    }

                    // FR-RTE-04：同凭据重试预算。networkTimeout 2 次、
                    // upstreamError 1 次、其余 0 次。用次数而非布尔量判断——
                    // 布尔量说不清"5xx 要先重试一次再转移"这种两段式动作。
                    if attempt <= failureClass.maxRetriesOnSameCredential {
                        let wait = min(retryAfter ?? Self.backoffSeconds(attempt: attempt + 1), 30)
                        if wait > 0 {
                            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                        }
                        continue
                    }

                    // 预算用尽：转移到下一个候选（rateLimited / forbidden /
                    // 重试后仍失败的 upstreamError 都走这里）。
                    break
                } catch {
                    let detail = "\(candidate.label): \(error.localizedDescription)"
                    failureDetails.append(detail)

                    // FR-RTE-04：网络层异常分类。超时/连不上/DNS 失败是瞬时的，
                    // 值得在同一凭据上退避重试；TLS 失败、意外 EOF 归为上游错误，
                    // 只给 1 次。
                    let failureClass = Self.classifyNetworkFailure(error)
                    if attempt <= failureClass.maxRetriesOnSameCredential {
                        let wait = Self.backoffSeconds(attempt: attempt + 1)
                        if wait > 0 {
                            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                        }
                        continue
                    }
                }
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
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes {
                        break
                    }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    markCooldown(for: candidate.accountID, category: retryFailure.category)
                    retryFailures.append(retryFailure)
                    // FR-RTE-04：streaming 路径的特殊规则。流已经打开但错误
                    // 还未发送到下游，此时允许切到下一个候选（否则用户只能看到
                    // 一片空白后超时）。已经开始发送 data: 事件后断开的情况由
                    // SSE 消费者处理（此函数不负责那个阶段）。
                    continue
                } else {
                    // 确定性客户端错误（400/404/422）：不转移，保留原始错误。
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
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes)
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
                    // FR-RTE-04 `.streamInterrupted`：SSE 已开始后断开，显式发
                    // error 事件收尾。Responses 协议不需要 [DONE] sentinel。
                    continuation.yield(
                        SwiftNativeProxyRuntimeService.sseStreamInterruptedFrame(error, includeDoneSentinel: false)
                    )
                    continuation.finish()
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
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes)
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
                    // FR-RTE-04 `.streamInterrupted`：显式 error 事件 + [DONE]。
                    // 静默断开在客户端看来与正常结束无法区分。
                    continuation.yield(
                        SwiftNativeProxyRuntimeService.sseStreamInterruptedFrame(error, includeDoneSentinel: true)
                    )
                    continuation.finish()
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

    func markCandidateUnauthorized(_ candidate: ProxyCandidate, reason: String) async {
        // FR-RTE-04：401 时立即标记凭据无权限，用于下轮路由的门禁淘汰。
        // 这是 markCooldown 的扩展版：它不仅冷却，还改健康状态。
        //
        // 两件事都要做，缺一不可：冷却是进程内的、立刻生效但重启即失效；
        // 写回注册表是落盘的、下次启动后路由的凭据门禁仍然认得它。只冷却的话
        // 用户重启一次 App，请求就又打到那把已被吊销的 Key 上去了。
        markCooldown(for: candidate.accountID, category: .authentication)
        credentialHealthWriter?.record(
            instanceID: candidate.accountID,
            // 已经确定是 401 才会走到这里，直接给结论而不是再传一次状态码——
            // 让判定重新解析一遍字符串，只会多一处可能对不上的地方。
            outcome: .unauthorized(detail: reason)
        )
        lastError = reason
    }

    func cooldownDuration(for category: RetryFailureCategory) -> Int64 {
        switch category {
        case .rateLimited:
            return 60
        case .quotaExceeded, .modelRestricted, .authentication, .permission:
            return 300
        case .serverError:
            return 30
        }
    }

    func markCooldown(for accountID: String, category: RetryFailureCategory, retryAfterSeconds: Int64? = nil) {
        let duration = retryAfterSeconds.map { min(max($0, 1), 3600) } ?? cooldownDuration(for: category)
        cooldownUntilByAccountID[accountID] = currentUnixSeconds() + duration
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
