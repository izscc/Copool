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
        /// 该模型条目的请求档案（FR-PRO-05）。v1 回落路径没有 registry，
        /// 拿不到 profile，此时用 `.conservativeDefault`——不附加任何非标准
        /// 字段，与"用户自建 provider"同等对待。
        var requestProfile: RequestProfile = .conservativeDefault
        /// 该条目的默认推理档位。`requestProfile` 需要它来决定发什么档位。
        var defaultReasoningEffort: String?
        /// 这条路由对应的 trace 的 requestID（FR-RTE-05）。
        ///
        /// nil 表示走的是 v1 精确匹配回落——那条路径没有 registry、没有打分、
        /// 也没写 trace，没有可回填的行。**不要**在这种情况下凭空造一个 id：
        /// 回填会静默找不到目标，而"找不到就跳过"和"根本没有"在日志里看起来
        /// 一模一样。
        var traceRequestID: String?
        /// 这一条失败后按 `FallbackPolicy` 依次改投的备选（FR-RTE-04）。
        ///
        /// 挂在路由上而不是另开一个返回值：三处调用点都只拿一个 route，把备选
        /// 塞进参数列表会让每个调用点都得关心转移，而它们关心的其实只是
        /// "把这个请求发出去"。
        ///
        /// 备选自身的这个数组恒为空——转移是一层，不是一棵树。让备选再带备选
        /// 就没有天然的收敛点，`maxAttempts` 也不再是次数上限。
        var fallbackRoutes: [ThirdPartyRoute] = []
    }

    /// Extracts only routing facts from a client request. Payload contents and
    /// credentials never enter the planner or decision ledger.
    func routeRequestContext(from object: [String: Any], targetBindingID: String = "codex") -> RouteRequestContext {
        var capabilities: Set<String> = []
        if let tools = object["tools"] as? [Any], !tools.isEmpty { capabilities.insert("tools") }
        if let input = object["input"] {
            let inputText = String(describing: input).lowercased()
            if inputText.contains("input_image") || inputText.contains("image_url") { capabilities.insert("vision") }
            if inputText.contains("input_audio") || inputText.contains("audio_url") { capabilities.insert("audio") }
        }
        if object["response_format"] != nil || object["text"] != nil { capabilities.insert("structured_output") }
        let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectionKind: ModelSelectionKind = model.caseInsensitiveCompare("auto") == .orderedSame ? .auto : .explicit
        return RouteRequestContext(
            targetBindingID: targetBindingID,
            sessionID: (object["session_id"] as? String) ?? (object["conversation_id"] as? String),
            requestedCapabilities: capabilities,
            requestedRegion: object["region"] as? String,
            remainingBudget: object["remaining_budget"] as? Double,
            explicitEntryID: nil,
            alias: object["model_alias"] as? String,
            selectionKind: selectionKind
        )
    }

    /// Looks up a provider route for the requested client model id.
    ///
    /// AC-012: when the v2 registry is present, the `RoutePlanner` decides
    /// (hard-filter → score → trace recorded in `route-decisions.jsonl`) and
    /// the selected instance (a stable v1-inherited UUID, AC-005) is mapped
    /// back to its v1 provider config. Falls back to the legacy exact-match
    /// scan when the v2 registry is empty or the model is registry-only.
    ///
    /// Accepts both the namespaced id (`antigravity/gemini-3.6-flash`) and the
    /// plain backend id (`gemini-3.6-flash`) — ChatGPT.app may send either
    /// depending on how the catalog entry was written.
    ///
    /// 返回 nil 表示 v1 也没匹配上——调用方据此返回 404（FR-RTE-02 第④步）。
    /// v2 解析失败**不会**再退化成"全目录里随便挑一个"。
    func resolveThirdPartyRoute(
        for clientModel: String,
        requestID: String = UUID().uuidString,
        context: RouteRequestContext = .default
    ) throws -> ThirdPartyRoute? {
        guard let providerRepository else { return nil }
        let store = try providerRepository.loadProviders()
        let requested = clientModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if let outcome = v2RouteResolver?.resolve(requestID: requestID, requestedModel: requested, context: context) {
            switch outcome {
            case .success(let resolution):
                // Prefer the legacy config during migration, but build a transient
                // transport config for registry-only providers so a newly configured
                // channel is actually routable before v1 migration catches up.
                let registry = v2RouteResolver.map { $0.registryRepository.loadRegistry() }
                let provider = store.providers.first(where: { $0.id == resolution.instance.id })
                    ?? registry.flatMap {
                        Self.makeV2Provider(
                            instance: resolution.instance,
                            entry: resolution.entry,
                            registry: $0
                        )
                    }
                if let provider {
                    let backendModel = resolution.entry.backendModelID
                    let fallbackRoutes = resolution.fallbacks.compactMap { landing -> ThirdPartyRoute? in
                        let fallbackProvider = store.providers.first(where: { $0.id == landing.instance.id })
                            ?? registry.flatMap {
                                Self.makeV2Provider(
                                    instance: landing.instance,
                                    entry: landing.entry,
                                    registry: $0
                                )
                            }
                        guard let fallbackProvider else { return nil }
                        return Self.makeRoute(
                            provider: fallbackProvider,
                            backendModel: landing.entry.backendModelID,
                            clientModelID: requested,
                            requestProfile: landing.requestProfile,
                            defaultReasoningEffort: landing.entry.capabilities.defaultReasoningEffort,
                            // 备选不带 traceRequestID：结局只应回填一次，由首选
                            // 那条 trace 记录最终结果，备选另写会出现同一请求多行。
                            traceRequestID: nil
                        )
                    }
                    return Self.makeRoute(
                        provider: provider,
                        backendModel: backendModel,
                        clientModelID: requested,
                        requestProfile: resolution.requestProfile,
                        defaultReasoningEffort: resolution.entry.capabilities.defaultReasoningEffort,
                        traceRequestID: resolution.trace.requestID,
                        fallbackRoutes: fallbackRoutes
                    )
                }
                // Registry entry exists but its credential is not readable through
                // an approved storage path; do not bypass the consent boundary.
            case .failure:
                // 三种失败都回落 v1 精确匹配。v1 是逐条精确比对，不存在
                // "随便挑一个"的风险；它也不中就是真的没有这个模型，
                // 由调用方 404。
                break
            }
        }

        for provider in store.providers {
            for model in provider.models {
                guard provider.matchesClientModel(requested, backendModel: model.id) else { continue }
                return Self.makeRoute(
                    provider: provider,
                    backendModel: model.id,
                    clientModelID: provider.clientModelID(for: model.id)
                )
            }
        }
        return nil
    }

    private static func makeV2Provider(
        instance: ProviderInstance,
        entry: ModelCatalogEntry,
        registry: ProviderRegistryV2
    ) -> ProviderConfig? {
        guard let definition = registry.definition(id: instance.definitionID),
              let credential = registry.credential(id: instance.credentialID),
              let reference = credential.secureReference else {
            return nil
        }

        let secret: String?
        switch reference.storage {
        case .keychainAccount:
            secret = KeychainSecretStore().read(account: reference.name)
        case .environmentVariable:
            secret = ProcessInfo.processInfo.environment[reference.name]
        case .externalSessionFile:
            // Reading an external CLI session requires the explicit consent path.
            return nil
        }
        guard let secret, !secret.isEmpty else { return nil }

        let resolvedBaseURL = ProviderRegistryResolver.resolveBaseURL(
            definition: definition,
            instanceOverride: instance.baseURLOverride ?? (instance.endpoint.isEmpty ? nil : instance.endpoint),
            environment: ProcessInfo.processInfo.environment
        )
        guard !resolvedBaseURL.value.isEmpty else { return nil }

        let model = ProviderModel(
            id: entry.backendModelID,
            displayName: entry.displayName,
            contextWindow: entry.capabilities.contextWindow,
            supportedReasoningEfforts: entry.capabilities.supportedReasoningEfforts,
            defaultReasoningEffort: entry.capabilities.defaultReasoningEffort
        )
        return ProviderConfig(
            id: instance.id,
            name: instance.displayName.isEmpty ? definition.displayName : instance.displayName,
            baseURL: resolvedBaseURL.value,
            apiKey: secret,
            authKind: credential.source == .importedFromApp ? .subscriptionImport : .apiKey,
            models: [model],
            modelProtocols: [entry.backendModelID: instance.defaultProtocol.legacy],
            defaultProtocol: instance.defaultProtocol.legacy,
            addedAt: instance.addedAt
        )
    }

    /// 唯一的 `ThirdPartyRoute` 构造入口。
    ///
    /// 存在的理由是 M4-8 的 Gemini 改写必须**对所有构造点生效**：v2 解析成功、
    /// v1 精确匹配回落，任一条漏掉就会出现"同一个 provider 有时走兼容面有时走
    /// 原生"的分裂行为，而两条路径的响应解析方式不同，症状是随机的空回复。
    nonisolated static func makeRoute(
        provider: ProviderConfig,
        backendModel: String,
        clientModelID: String,
        requestProfile: RequestProfile = .conservativeDefault,
        defaultReasoningEffort: String? = nil,
        traceRequestID: String? = nil,
        fallbackRoutes: [ThirdPartyRoute] = []
    ) -> ThirdPartyRoute {
        let normalized = GeminiCompatibilitySurface.normalize(
            protocolKind: provider.resolvedProtocol(forModel: backendModel),
            baseURL: provider.baseURL,
            providerName: provider.name,
            authKind: provider.authKind
        )
        var routedProvider = provider
        routedProvider.baseURL = normalized.baseURL
        return ThirdPartyRoute(
            provider: routedProvider,
            backendModel: backendModel,
            clientModelID: clientModelID,
            protocolKind: normalized.protocolKind,
            requestProfile: requestProfile,
            defaultReasoningEffort: defaultReasoningEffort,
            traceRequestID: traceRequestID,
            fallbackRoutes: fallbackRoutes
        )
    }

    /// 回填这条路由对应 trace 的结局（FR-RTE-05）。
    ///
    /// 有意做成 fire-and-forget 的后台任务：回填要读改写整份 jsonl，虽然文件
    /// 封顶 500 行，但把这点 IO 摆在请求返回的路径上，就是让每个用户请求为一份
    /// 诊断记录多等一会儿。诊断数据晚几毫秒落盘没有任何代价。
    ///
    /// `traceRequestID` 为 nil（v1 回落路径）时直接返回，连任务都不建。
    nonisolated func completeRouteTrace(
        route: ThirdPartyRoute,
        startedAt: ContinuousClock.Instant,
        outcome: RouteDecisionTrace.Outcome,
        httpStatus: Int? = nil,
        fallbackAttempts: [String] = [],
        failureChain: [String] = []
    ) {
        guard let requestID = route.traceRequestID, let ledger = v2RouteResolver?.ledger else { return }
        let elapsedMS = Int((ContinuousClock.now - startedAt) / .milliseconds(1))
        Task.detached(priority: .utility) {
            ledger.complete(
                requestID: requestID,
                durationMS: elapsedMS,
                outcome: outcome,
                httpStatus: httpStatus,
                fallbackAttempts: fallbackAttempts,
                failureChain: failureChain
            )
        }
    }

    /// 把一次真实请求的结果写回凭据健康状态（FR-IDT-07 / M5）。
    ///
    /// 只在**第三方路由**上调用：原生 ChatGPT 账号走的是 `ProxyCandidate`
    /// 那套冷却机制，两者的凭据模型不是一回事。
    ///
    /// 后台任务，不挡请求返回路径：写回要读改写 registry.json，把这点 IO
    /// 摆在用户请求的关键路径上，只为了让一份诊断数据早几毫秒落盘。
    nonisolated func recordCredentialHealth(route: ThirdPartyRoute, statusCode: Int, responseBody: Data?) {
        guard let writer = credentialHealthWriter else { return }
        let instanceID = route.provider.id
        // 只截前 400 字节再解码：错误体偶尔会是一整个 HTML 页面，全量转字符串
        // 纯属浪费，而判定只看开头的关键词。
        let bodyText = responseBody.map { String(decoding: $0.prefix(400), as: UTF8.self) }
        Task.detached(priority: .utility) {
            writer.record(instanceID: instanceID, statusCode: statusCode, responseBody: bodyText)
        }
    }

    nonisolated func recordCredentialNetworkFailure(route: ThirdPartyRoute, error: Error) {
        guard let writer = credentialHealthWriter else { return }
        let instanceID = route.provider.id
        Task.detached(priority: .utility) {
            writer.recordNetworkFailure(instanceID: instanceID, error: error)
        }
    }

    /// Model ids exposed by configured providers, appended to /v1/models.
    /// Uses the plain backend id so the proxy's model list matches what
    /// ChatGPT.app sends after the catalog slug change.
    func thirdPartyClientModelIDs() -> [String] {
        var ids: [String] = []
        if let providerRepository, let store = try? providerRepository.loadProviders() {
            ids.append(contentsOf: store.providers.flatMap { provider in
                provider.clientModels.map(\.backendID)
            })
        }
        if let v2RouteResolver {
            let registry = v2RouteResolver.registryRepository.loadRegistry()
            let now = Int64(Date().timeIntervalSince1970)
            ids.append(contentsOf: registry.catalog.compactMap { entry in
                guard entry.visibility != .hidden,
                      entry.upstreamAvailable,
                      let instance = registry.instance(id: entry.providerInstanceID),
                      instance.enabled,
                      let credential = registry.credential(id: instance.credentialID),
                      credential.secureReference?.storage != .externalSessionFile,
                      credential.gateState(now: now) != .notReady else {
                    return nil
                }
                return entry.backendModelID
            })
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Requests

    /// Tool-bearing requests may have external side effects and must not be
    /// blindly replayed. An explicit idempotency key is the only override.
    nonisolated static func thirdPartyReplayIsSafe(object: [String: Any], headers: [String: String]) -> Bool {
        if let key = object["idempotency_key"] as? String, !key.isEmpty { return true }
        if let key = headers["idempotency-key"] ?? headers["Idempotency-Key"], !key.isEmpty { return true }
        if let tools = object["tools"] as? [Any], !tools.isEmpty { return false }
        if object["tool_choice"] != nil { return false }
        if let input = object["input"] as? [Any], input.contains(where: { item in
            guard let object = item as? [String: Any] else { return false }
            let type = object["type"] as? String
            return type == "function_call" || type == "function_call_output"
        }) { return false }
        return true
    }

    func thirdPartyRetryDelay(response: UpstreamResponse, attempt: Int) -> UInt64 {
        let retryAfter = Self.parseRetryAfter(headers: response.headers)
        let seconds = min(retryAfter ?? Self.backoffSeconds(attempt: attempt), 8)
        return UInt64(max(seconds, 0)) * 1_000_000_000
    }

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
            if responseBody.count > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes {
                throw AppError.network(
                    L10n.tr(
                        "error.proxy_runtime.upstream_response_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes)
                    )
                )
            }
        }

        // 所有非流式出站都收敛在这里，凭据健康写回放这一处就能全覆盖，
        // 不用在每个调用点各记一次（漏一处就是一条永远不更新的凭据）。
        recordCredentialHealth(route: route, statusCode: statusCode, responseBody: responseBody)

        return UpstreamResponse(
            statusCode: statusCode,
            body: responseBody,
            headers: SwiftNativeProxyRuntimeService.normalizedHeaders(from: httpResponse?.allHeaderFields ?? [:])
        )
    }

    /// Retries only replay-safe transient failures. Once a response stream is
    /// opened, the caller deliberately does not use this helper.
    ///
    /// FR-RTE-04：重试次数由失败分类决定，不再"凡是能分类的失败都重发 3 次"。
    /// 第三方 provider 大多按 token 计费且没有幂等语义，把一个 429 连发三次
    /// 既不会成功，还可能把限流窗口推得更长。
    func sendThirdPartyRequestWithRetry(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        object: [String: Any]
    ) async throws -> UpstreamResponse {
        let replaySafe = Self.thirdPartyReplayIsSafe(object: object, headers: downstreamHeaders)
        var refreshedToken: String?
        var attempt = 0
        var lastResponse: UpstreamResponse?
        // 兜底上限。真正的次数由分类的 maxRetriesOnSameCredential 决定。
        let maxAttempts = 3

        while attempt < maxAttempts {
            attempt += 1
            do {
                let response = try await sendThirdPartyRequest(
                    route: route,
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    apiKeyOverride: refreshedToken
                )
                lastResponse = response

                // Token 刷新不算重试：换的是凭据内容而非重发同一个失败请求。
                if (response.statusCode == 401 || response.statusCode == 403),
                   refreshedToken == nil,
                   let refreshed = await refreshProviderTokenIfNeeded(route: route) {
                    refreshedToken = refreshed
                    continue
                }

                guard replaySafe else { return response }
                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                guard let retryFailure = classifyRetryFailure(
                    statusCode: response.statusCode,
                    bodyText: bodyText
                ) else {
                    // 成功，或 .requestError（400/404/422）——原样返回。
                    return response
                }
                // FR-RTE-04：401 零重试；刷新 token 的机会上面已经给过了。
                if retryFailure.failureClass.shouldMarkCredentialUnauthorized {
                    return response
                }
                guard attempt <= retryFailure.failureClass.maxRetriesOnSameCredential else {
                    return response
                }
                try await Task.sleep(nanoseconds: thirdPartyRetryDelay(response: response, attempt: attempt))
            } catch {
                let failureClass = Self.classifyNetworkFailure(error)
                // 网络层失败也要写回，但 `recordNetworkFailure` 只会留下原因、
                // 不改状态——链路不通不是凭据的错（FR-CAT-09）。
                recordCredentialNetworkFailure(route: route, error: error)
                guard replaySafe, attempt <= failureClass.maxRetriesOnSameCredential else { throw error }
                let delay = UInt64(min(Self.backoffSeconds(attempt: attempt + 1), 8)) * 1_000_000_000
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            }
        }

        if let lastResponse { return lastResponse }
        throw AppError.network("Third-party request failed without a response")
    }

    /// 首选失败后按 `FallbackPolicy` 依次改投备选（FR-RTE-04）。
    ///
    /// 返回值里带上实际用过的落点标签与失败链，调用方拿它回填 trace——
    /// 路由 tab 的"已转移"徽标和转移链就是从这里来的。
    ///
    /// 只对 `shouldFailoverToAnotherCandidate` 为真的失败转移；请求体错误和
    /// 凭据错误换落点没有意义，还会掩盖真正的原因。
    struct FailoverOutcome: Sendable {
        var response: UpstreamResponse?
        var error: Error?
        /// 最终产生 `response` 的那条路由；nil 表示始终没换出去，仍是首选。
        /// 用量与限流要记在它头上，否则用量表与账单对不上。
        var servedBy: ThirdPartyRoute?
        /// 依次尝试过的备选标签（provider · model），供 trace 展示。
        var attempts: [String] = []
        /// 每一次失败的脱敏描述（INV-1）。
        var failures: [String] = []
    }

    func sendWithFailover(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        object: [String: Any],
        primaryResponse: UpstreamResponse?,
        primaryError: Error?
    ) async -> FailoverOutcome {
        var outcome = FailoverOutcome(response: primaryResponse, error: primaryError)

        let primaryClass: UpstreamFailureClass
        if let primaryResponse {
            let bodyText = String(data: primaryResponse.body, encoding: .utf8) ?? ""
            primaryClass = UpstreamFailureClass.classify(statusCode: primaryResponse.statusCode, responseBody: bodyText)
            outcome.failures.append(
                SecretRedactor.redactText("\(route.provider.name): \(primaryResponse.statusCode) \(primaryClass.rawValue)")
            )
        } else if let primaryError {
            primaryClass = Self.classifyNetworkFailure(primaryError)
            outcome.failures.append(
                SecretRedactor.redactText("\(route.provider.name): \(primaryError.localizedDescription)")
            )
        } else {
            return outcome
        }
        guard primaryClass.shouldFailoverToAnotherCandidate, !route.fallbackRoutes.isEmpty else { return outcome }
        // 有副作用的请求不能改投：备选是**另一次真实调用**，工具调用可能已经
        // 在上游执行过一半了。这条判断与同凭据重试用的是同一个闸门。
        guard Self.thirdPartyReplayIsSafe(object: object, headers: downstreamHeaders) else { return outcome }

        for fallback in route.fallbackRoutes {
            // 跨协议的备选在这里就跳过，不记 attempt：它一次上游调用都没发生，
            // 记进转移链会让用户在路由 tab 里看到一次并不存在的尝试。
            guard let fallbackPayload = try? rebuildPayload(payload, for: fallback, from: route) else { continue }
            let label = "\(fallback.provider.name) · \(fallback.backendModel)"
            outcome.attempts.append(label)
            do {
                let response = try await sendThirdPartyRequestWithRetry(
                    route: fallback,
                    payload: fallbackPayload,
                    downstreamHeaders: downstreamHeaders,
                    object: object
                )
                outcome.response = response
                outcome.error = nil
                outcome.servedBy = fallback
                if response.statusCode >= 200 && response.statusCode < 300 { return outcome }

                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let failureClass = UpstreamFailureClass.classify(statusCode: response.statusCode, responseBody: bodyText)
                outcome.failures.append(
                    SecretRedactor.redactText("\(label): \(response.statusCode) \(failureClass.rawValue)")
                )
                // 这一档失败也不该继续转移时就地停下，把它的响应交给客户端——
                // 它比首选的错误更新，也更接近用户最终看到的结果。
                guard failureClass.shouldFailoverToAnotherCandidate else { return outcome }
            } catch {
                outcome.error = error
                outcome.failures.append(SecretRedactor.redactText("\(label): \(error.localizedDescription)"))
                guard Self.classifyNetworkFailure(error).shouldFailoverToAnotherCandidate else { return outcome }
            }
        }
        return outcome
    }

    /// 流式请求的转移（FR-RTE-04）。
    ///
    /// 只在**流还没开起来**时可用——上游返回了非 2xx，说明一个字节都还没发给
    /// 客户端，换一家是干净的。一旦开始推送就绝不转移：那时客户端手里已经有
    /// 半截回答，第二家从头再讲一遍会拼成两段互相矛盾的内容，而第一段的费用
    /// 已经产生了。调用方必须保证这一点。
    struct StreamFailoverOutcome: Sendable {
        var upstream: UpstreamStreamingResponse?
        var servedBy: ThirdPartyRoute?
        var attempts: [String] = []
        var failures: [String] = []
    }

    func openStreamWithFailover(
        route: ThirdPartyRoute,
        payload: [String: Any],
        downstreamHeaders: [String: String],
        object: [String: Any],
        primaryStatus: Int,
        primaryBodyText: String
    ) async -> StreamFailoverOutcome {
        var outcome = StreamFailoverOutcome()
        let primaryClass = UpstreamFailureClass.classify(statusCode: primaryStatus, responseBody: primaryBodyText)
        outcome.failures.append(
            SecretRedactor.redactText("\(route.provider.name): \(primaryStatus) \(primaryClass.rawValue)")
        )
        guard primaryClass.shouldFailoverToAnotherCandidate, !route.fallbackRoutes.isEmpty else { return outcome }
        guard Self.thirdPartyReplayIsSafe(object: object, headers: downstreamHeaders) else { return outcome }

        for fallback in route.fallbackRoutes {
            guard let fallbackPayload = try? rebuildPayload(payload, for: fallback, from: route) else { continue }
            let label = "\(fallback.provider.name) · \(fallback.backendModel)"
            outcome.attempts.append(label)
            do {
                let upstream = try await openThirdPartyStreamingRequest(
                    route: fallback,
                    payload: fallbackPayload,
                    downstreamHeaders: downstreamHeaders
                )
                if upstream.statusCode >= 200 && upstream.statusCode < 300 {
                    outcome.upstream = upstream
                    outcome.servedBy = fallback
                    return outcome
                }
                // 失败的那条流必须读干净再丢：URLSession 的字节流不消费就一直
                // 占着连接，连着几次转移会把连接池耗光，症状是后续请求莫名挂起。
                var buffered = Data()
                for try await byte in upstream.bytes {
                    buffered.append(byte)
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes { break }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                let failureClass = UpstreamFailureClass.classify(statusCode: upstream.statusCode, responseBody: bodyText)
                outcome.failures.append(
                    SecretRedactor.redactText("\(label): \(upstream.statusCode) \(failureClass.rawValue)")
                )
                guard failureClass.shouldFailoverToAnotherCandidate else { return outcome }
            } catch {
                outcome.failures.append(SecretRedactor.redactText("\(label): \(error.localizedDescription)"))
                guard Self.classifyNetworkFailure(error).shouldFailoverToAnotherCandidate else { return outcome }
            }
        }
        return outcome
    }

    /// 首选的出站 payload 能否原样交给备选。
    ///
    /// 能改的地方其实不用改：`makeThirdPartyRequest` 在发出前就会按备选自己的
    /// `requestProfile` 变换字段、并把模型名替换成备选的 `backendModel`，
    /// 在这里再做一次只会让同一件事有两个实现。
    ///
    /// 唯一必须拦下的是跨协议的备选（首选 chat、备选 anthropic 之类）：重塑线
    /// 格式属于出站构造阶段的职责，在转移路径里重做等于把那套逻辑抄第二份。
    /// 打分器允许不同 dialect 的候选共存，所以这个情况是真的会发生。
    nonisolated func rebuildPayload(
        _ payload: [String: Any],
        for fallback: ThirdPartyRoute,
        from primary: ThirdPartyRoute
    ) throws -> [String: Any] {
        guard fallback.protocolKind == primary.protocolKind else {
            throw AppError.invalidData("fallback protocol mismatch")
        }
        return payload
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

        // FR-PRO-05：应用请求档案。**必须在协议转换之前**——Anthropic 与
        // Gemini 的转换器读的是 payload 里的推理字段，先转换再变换的话它们
        // 看到的是未经处理的原始字段，dashscope 的剥离也就白做了。
        let profiledPayload = RequestProfileApplicator.apply(
            profile: route.requestProfile,
            to: payload,
            requestedEffort: Self.requestedReasoningEffort(in: payload)
                ?? route.defaultReasoningEffort
        )

        let apiKey = apiKeyOverride ?? route.provider.apiKey
        // Some upstreams gate on the client User-Agent; when a branch sets one
        // it must survive the generic downstream header forwarding below.
        var providerUserAgent: String?
        var authHeaders: [String: String] = [:]
        var request: URLRequest
        switch route.protocolKind {
        case .chat:
            request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: profiledPayload, with: route.backendModel))
            authHeaders["authorization"] = "Bearer \(apiKey)"
            if route.provider.name.lowercased() == "grok" || route.provider.baseURL.contains("x.ai") {
                providerUserAgent = "grok-cli/1.89.0"
            }
        case .responses:
            request = URLRequest(url: baseURL.appendingPathComponent("responses"))
            request.httpBody = try JSONSerialization.data(withJSONObject: replacingModel(in: profiledPayload, with: route.backendModel))
            authHeaders["authorization"] = "Bearer \(apiKey)"
        case .anthropic:
            request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
            let anthropicBody = convertChatToAnthropic(profiledPayload, model: route.backendModel)
            request.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody)
            // Anthropic accepts both x-api-key and Authorization: Bearer.
            authHeaders["x-api-key"] = apiKey
            authHeaders["anthropic-version"] = "2023-06-01"
        case .google:
            // M4-8 之后，公有 Gemini（`generativelanguage.googleapis.com` +
            // apiKey）在 `makeRoute` 里已被改写成 `.chat`，走不到这里。
            // 留下的两类是：Antigravity 的 CloudCode 内网端点，以及用户自建的
            // 第三方 Gemini 兼容网关——后者的 host 我们不认识，不能替它假设
            // 存在 `/openai` 兼容面。
            let model = route.backendModel
            let streaming = (profiledPayload["stream"] as? Bool) ?? true
            let name = route.provider.name.lowercased()
            let isAntigravity = name == "antigravity" || name == "agy"
            let geminiBody = convertChatToGemini(profiledPayload)

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
                authHeaders["authorization"] = "Bearer \(apiKey)"
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
                authHeaders["authorization"] = "Bearer \(apiKey)"
            }
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 180

        // FR-PRO-07 / SEC-04：白名单出站头组装。
        let outbound = OutboundHeaderPolicy.outboundHeaders(
            downstream: downstreamHeaders,
            authHeaders: authHeaders,
            contentType: "application/json",
            accept: "text/event-stream",
            providerUserAgent: providerUserAgent
        )
        for (name, value) in outbound {
            request.setValue(value, forHTTPHeaderField: name)
        }

        return request
    }

    private func replacingModel(in payload: [String: Any], with backendModel: String) -> [String: Any] {
        var result = payload
        result["model"] = backendModel
        return result
    }

    /// 从下游 payload 里读出用户请求的推理档位（FR-PRO-05）。
    ///
    /// 下游可能用四种形状表达同一件事，取决于它以为自己在跟谁说话：
    /// - Chat Completions：`{"reasoning_effort": "high"}`
    /// - Responses API：`{"reasoning": {"effort": "high"}}`
    /// - DeepSeek/GLM 风格：`{"thinking": {"type": "enabled"}}`
    /// - Anthropic：`{"thinking": {"type": "enabled", "budget_tokens": 20000}}`
    ///
    /// 返回 nil 表示下游没表态——此时调用方回落到目录条目的默认档位，再落空
    /// 就什么都不附加，让上游用自己的默认值。
    nonisolated static func requestedReasoningEffort(in payload: [String: Any]) -> String? {
        func normalized(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }

        if let effort = normalized(payload["reasoning_effort"]) {
            return effort
        }
        if let reasoning = payload["reasoning"] as? [String: Any],
           let effort = normalized(reasoning["effort"]) {
            return effort
        }
        if let thinking = payload["thinking"] as? [String: Any] {
            // Anthropic / DeepSeek 的 `type` 只说开关，不说深度。budget_tokens
            // 能反推出深度，没有就按 high——用户明确开了推理，给个中上的档位
            // 比给最低档更贴近意图。
            if let type = thinking["type"] as? String, type == "disabled" {
                return RequestProfileApplicator.disableEffort
            }
            if let budget = thinking["budget_tokens"] as? Int {
                return effortForThinkingBudget(budget)
            }
            return "high"
        }
        if let enabled = payload["enable_thinking"] as? Bool {
            return enabled ? "high" : RequestProfileApplicator.disableEffort
        }
        return nil
    }

    /// `thinking_budget` token 数 → 档位。是
    /// `RequestProfileApplicator.thinkingBudget(for:)` 的粗粒度反函数：
    /// 取最接近的档位边界，不要求精确往返。
    nonisolated static func effortForThinkingBudget(_ budget: Int) -> String {
        switch budget {
        case ..<2_000: return "minimal"
        case ..<8_000: return "low"
        case ..<16_000: return "medium"
        case ..<32_000: return "high"
        default: return "max"
        }
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
