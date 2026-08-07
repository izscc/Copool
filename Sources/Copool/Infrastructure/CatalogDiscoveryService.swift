import Foundation

/// 实例级的实时模型发现（FR-CAT-03）。
///
/// 与 v1 的 `ModelCapabilityDiscovery` 分开而不是改造它：v1 的入口类型
/// `ProviderConfig` 内联携带 apiKey，v2 的凭据只有一个 `SecureReference`
/// 指针，两者的取密路径完全不同。硬合并会让 v1 的调用点被迫先把密钥读出来
/// 塞进结构体里——正是 v2 想消除的那种"密钥在内存里到处传"。
///
/// 三条不可协商的约束：
///   - **超时 10 秒、不重试。** 这是用户点了按钮在等的操作，让他盯着转圈
///     三轮比直接说"没连上"更糟。
///   - **失败绝不清空目录。** 把一次网络抖动解释成"上游现在有 0 个模型"，
///     代价是用户策展了半天的目录凭空消失，而他无从把这件事和刚才那次点击
///     联系起来。
///   - **失败原因写库前必须脱敏（INV-1）。** 上游 4xx 的响应体里常带 key
///     片段和账号邮箱，原样入库等于把秘密写进了明文配置。
struct CatalogDiscoveryService: Sendable {
    /// 一次发现的产出。`failureReason` 非 nil 即为失败，此时另外两项无意义。
    struct Outcome: Sendable, Equatable {
        var modelIDs: [String]
        var capabilities: [String: ModelCapabilitiesV2]
        /// **已脱敏**的失败原因。
        var failureReason: String?

        var succeeded: Bool { failureReason == nil }
    }

    enum DiscoveryError: LocalizedError, Equatable {
        case instanceNotFound
        case definitionNotFound
        case baseURLMissing
        case credentialUnavailable

        var errorDescription: String? {
            switch self {
            case .instanceNotFound:
                return L10n.tr("credentials.error.instance_not_found")
            case .definitionNotFound:
                return L10n.tr("catalog.discovery.error.definition_missing")
            case .baseURLMissing:
                return L10n.tr("catalog.discovery.error.baseurl_missing")
            case .credentialUnavailable:
                return L10n.tr("catalog.discovery.error.credential_missing")
            }
        }
    }

    /// 单次请求的超时。10 秒是"慢但还在响应"与"这条路不通"的分界；
    /// 再长下去用户已经认定它坏了。
    static let timeout: TimeInterval = 10

    var session: URLSession = .shared
    var timeout: TimeInterval = CatalogDiscoveryService.timeout

    init(session: URLSession = .shared, timeout: TimeInterval = CatalogDiscoveryService.timeout) {
        self.session = session
        self.timeout = timeout
    }

    // MARK: - 请求

    /// 向一个实例的 `/models` 发一次请求。
    ///
    /// `token` 由调用方在主 actor 上解析好传进来：取密要过 Keychain 与同意
    /// 门禁，那是 `CredentialCoordinator` 的职责，不该在这里复制一份。
    func discover(
        baseURL: String,
        dialect: APIDialect,
        token: String
    ) async -> Outcome {
        guard let url = Self.modelsURL(baseURL: baseURL, dialect: dialect) else {
            return Outcome(modelIDs: [], capabilities: [:], failureReason: L10n.tr("catalog.discovery.error.baseurl_missing"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        Self.applyAuth(to: &request, dialect: dialect, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(modelIDs: [], capabilities: [:], failureReason: L10n.tr("catalog.discovery.error.bad_response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                // 只留状态码。响应体是最容易夹带密钥的地方，而它对用户的
                // 帮助远不如一个明确的 401/403/429 分类。
                return Outcome(
                    modelIDs: [],
                    capabilities: [:],
                    failureReason: Self.describeStatus(http.statusCode)
                )
            }
            let parsed = Self.parse(data: data)
            guard !parsed.modelIDs.isEmpty else {
                return Outcome(modelIDs: [], capabilities: [:], failureReason: L10n.tr("catalog.discovery.error.empty_list"))
            }
            return Outcome(modelIDs: parsed.modelIDs, capabilities: parsed.capabilities, failureReason: nil)
        } catch {
            return Outcome(modelIDs: [], capabilities: [:], failureReason: Self.redact(error))
        }
    }

    // MARK: - URL 与鉴权

    /// `/models` 的位置。Anthropic 在 `/v1/models`，OpenAI 兼容形态相对
    /// baseURL 挂 `/models`；已经带 `/v1` 的 baseURL 不再重复追加。
    static func modelsURL(baseURL: String, dialect: APIDialect) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard var base = URL(string: normalized) else { return nil }
        if dialect == .anthropic, !normalized.hasSuffix("/v1") {
            base = base.appendingPathComponent("v1")
        }
        return base.appendingPathComponent("models")
    }

    static func applyAuth(to request: inout URLRequest, dialect: APIDialect, token: String) {
        guard !token.isEmpty else { return }
        switch dialect {
        case .anthropic:
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            // 头传而不是 `?key=`：query 里的密钥会被写进各层访问日志，
            // 而这个请求的 URL 还会出现在错误描述里。
            request.setValue(token, forHTTPHeaderField: "x-goog-api-key")
        case .chat, .responses:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - 解析

    /// 解析 `/models` 响应。接受 `{data:[…]}`、`{models:[…]}` 与裸数组三种
    /// 形态——OpenAI 兼容网关在这一点上并不统一。
    static func parse(data: Data) -> (modelIDs: [String], capabilities: [String: ModelCapabilitiesV2]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return ([], [:]) }
        let items: [[String: Any]]
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any] {
            items = (object["data"] as? [[String: Any]])
                ?? (object["models"] as? [[String: Any]])
                ?? []
        } else {
            items = []
        }

        var ids: [String] = []
        var capabilities: [String: ModelCapabilitiesV2] = [:]
        var seen: Set<String> = []
        for item in items {
            // Google 的模型名带 `models/` 前缀，去掉后才和用户配置里写的一致。
            let raw = (item["id"] as? String)
                ?? (item["name"] as? String)
                ?? (item["model"] as? String)
                ?? ""
            var id = raw.trimmingCharacters(in: .whitespaces)
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)

            // 复用 v1 的字段嗅探：各家的键名差异已经在那里积累了一整张表，
            // 再抄一份只会让两处逐渐分叉。
            let parsed = ModelCapabilityDiscovery.parse(item)
            var capability = ModelCapabilitiesV2()
            capability.contextWindow = parsed.contextWindow
            // FR-CAT-05：这里原样透传 nil / [] 的区别。`[]` 是上游明确说了
            // "没有档位"，`nil` 是没提。**绝不**从模型名里猜。
            capability.supportedReasoningEfforts = parsed.supportedReasoningEfforts
            capability.defaultReasoningEffort = parsed.defaultReasoningEffort
            if let modalities = item["input_modalities"] as? [String] {
                capability.supportsVision = modalities.contains("image")
            } else if let modalities = item["inputModalities"] as? [String] {
                capability.supportsVision = modalities.contains("image")
            }
            capabilities[id] = capability
        }
        return (ids, capabilities)
    }

    // MARK: - 脱敏

    /// HTTP 状态码转成用户能处理的一句话。分类到"该做什么"而不是转述数字：
    /// 401 要去换 key，429 要等一会儿，5xx 只能等上游。
    static func describeStatus(_ code: Int) -> String {
        switch code {
        case 401, 403:
            return L10n.tr("catalog.discovery.error.unauthorized")
        case 404:
            return L10n.tr("catalog.discovery.error.not_found")
        case 429:
            return L10n.tr("catalog.discovery.error.throttled")
        case 500...599:
            return L10n.tr("catalog.discovery.error.upstream")
        default:
            return String(format: L10n.tr("catalog.discovery.error.status_format"), code)
        }
    }

    /// 传输层错误的安全描述。
    ///
    /// 不用 `error.localizedDescription`：URLError 的描述里会带完整 URL，
    /// 而不少网关把 key 放在 query 里。映射到固定文案是唯一能保证不泄漏的
    /// 做法（INV-1）。
    static func redact(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return L10n.tr("catalog.discovery.error.unknown")
        }
        switch urlError.code {
        case .timedOut:
            return L10n.tr("catalog.discovery.error.timeout")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return L10n.tr("catalog.discovery.error.offline")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return L10n.tr("catalog.discovery.error.unreachable")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return L10n.tr("catalog.discovery.error.tls")
        case .cancelled:
            return L10n.tr("catalog.discovery.error.cancelled")
        default:
            return L10n.tr("catalog.discovery.error.unknown")
        }
    }
}
