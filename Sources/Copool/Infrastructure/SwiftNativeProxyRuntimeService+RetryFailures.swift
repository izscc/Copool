import Foundation

extension SwiftNativeProxyRuntimeService {
    /// 分类一次上游失败。
    ///
    /// 返回 nil 表示**确定性客户端错误**（FR-RTE-04 的 `.requestError`：
    /// 400/404/422），调用方应原样透传、不重试、不换凭据——换一个凭据重发一个
    /// 格式错误的请求，只会把同一个 400 再收一遍。
    ///
    /// 这里同时产出两样东西：
    /// - `failureClass`：FR-RTE-04 七分类，**重试决策的唯一依据**；
    /// - `category`：P1 既有的冷却/汇总词汇表，比状态码更细（它能从响应体认出
    ///   "配额耗尽"和"该账号无此模型权限"，这两种在 HTTP 层都可能是 403/404）。
    ///
    /// 之所以保留两套而不是删掉一套：状态码给不出"账号 A 没有 gpt-5-pro 权限"
    /// 这种信息，而这恰恰是多账号池最有价值的转移信号；反过来，响应体关键词
    /// 匹配又不该决定"要不要重发同一个请求"这种花钱的事。各管各的。
    func classifyRetryFailure(statusCode: Int, bodyText: String) -> RetryFailureInfo? {
        let signals = extractErrorSignals(rawText: bodyText)
        let status = statusCode

        // 响应体信号优先于状态码：上游把限流塞进 500 里返回是常态，
        // body 比 status 更接近事实。
        if status == 402 || containsQuotaSignal(signals.normalized) {
            return RetryFailureInfo(
                category: .quotaExceeded,
                failureClass: .rateLimited,
                detail: L10n.tr("error.proxy_runtime.retry.quota_exceeded_format", signals.brief)
            )
        }
        if containsModelRestrictionSignal(signals.normalized) {
            // 模型权限受限：同一凭据重发必然再失败，但**别的账号可能有权限**，
            // 所以按 forbidden 处理（零同凭据重试 + 允许转移）。
            return RetryFailureInfo(
                category: .modelRestricted,
                failureClass: .forbidden,
                detail: L10n.tr("error.proxy_runtime.retry.model_restricted_format", signals.brief)
            )
        }
        if status == 429 || containsRateLimitSignal(signals.normalized) {
            return RetryFailureInfo(
                category: .rateLimited,
                failureClass: .rateLimited,
                detail: L10n.tr("error.proxy_runtime.retry.rate_limited_format", signals.brief)
            )
        }
        if status == 401 || containsAuthSignal(signals.normalized) {
            return RetryFailureInfo(
                category: .authentication,
                failureClass: .unauthorized,
                detail: L10n.tr("error.proxy_runtime.retry.auth_failed_format", signals.brief)
            )
        }
        if status == 403 || containsPermissionSignal(signals.normalized) {
            // FR-RTE-04：403 必须区分配额型与禁止型。配额型走限流路径
            // （换凭据/退避后仍可能成功），禁止型是硬拒绝。
            return RetryFailureInfo(
                category: .permission,
                failureClass: UpstreamFailureClass.classify(statusCode: 403, responseBody: bodyText),
                detail: L10n.tr("error.proxy_runtime.retry.permission_denied_format", signals.brief)
            )
        }
        // AC-013: transient 5xx (except 501/505 — "not implemented"/"version
        // not supported" are permanent) are retriable on another candidate.
        if status >= 500 && status <= 599 && status != 501 && status != 505 {
            return RetryFailureInfo(
                category: .serverError,
                // 520+ 是 CloudFlare 边缘错误，属于网络层而非上游应用层。
                failureClass: status >= 520 ? .networkTimeout : .upstreamError,
                detail: L10n.tr("error.proxy_runtime.retry.server_error_format", signals.brief)
            )
        }
        return nil
    }

    /// 网络层异常分类（FR-RTE-04）。超时/连接失败允许在同一凭据上重试；
    /// 其余（TLS 失败、意外 EOF）按上游错误处理。
    nonisolated static func classifyNetworkFailure(_ error: Error) -> UpstreamFailureClass {
        UpstreamFailureClass.classifyNetworkError(error)
    }

    /// SSE 流中断的收尾帧（FR-RTE-04 `.streamInterrupted`）。
    ///
    /// **不重试**：客户端已经收到了部分 token，上游也已经按这些 token 计费。
    /// 重发会让用户为同一段内容付两次钱，并且下游会收到两份互相矛盾的开头。
    ///
    /// 但也不能就这么把连接掐掉——SSE 没有帧长度，静默断开在客户端看来和
    /// "正常结束"完全一样，用户会拿到一段被截断的回答却以为它是完整的。
    /// 所以显式发一个 error 事件再发 `[DONE]`。
    ///
    /// - Parameter includeDoneSentinel: Chat Completions 协议约定以
    ///   `data: [DONE]` 结束，Responses 协议不需要。
    nonisolated static func sseStreamInterruptedFrame(
        _ error: Error,
        includeDoneSentinel: Bool
    ) -> Data {
        let message = truncateForErrorStatic(error.localizedDescription, maxLength: 200)
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": UpstreamFailureClass.streamInterrupted.rawValue,
                "code": "stream_interrupted",
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"error\":{\"message\":\"stream interrupted\",\"type\":\"streamInterrupted\"}}"

        var frame = "event: error\ndata: \(json)\n\n"
        if includeDoneSentinel {
            frame += "data: [DONE]\n\n"
        }
        return Data(frame.utf8)
    }

    /// `truncateForError` 的 nonisolated 版本，供流中断收尾使用。
    nonisolated static func truncateForErrorStatic(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    /// Parses a Retry-After header: integer seconds, or an HTTP-date.
    /// Returns nil when absent or unparseable (caller falls back to backoff).
    static func parseRetryAfter(headers: [String: String], now: Date = Date()) -> Int64? {
        guard let value = headers["retry-after"] ?? headers["Retry-After"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int64(trimmed) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(Int64(date.timeIntervalSince(now)), 0)
        }
        return nil
    }

    /// Exponential backoff in seconds for in-candidate retries: 1, 2, 4, 8…
    /// capped at 8s (AC-013).
    static func backoffSeconds(attempt: Int) -> Int64 {
        guard attempt > 1 else { return 0 }
        let exponent = min(attempt - 1, 3) // 1,2,4,8 cap
        return Int64(pow(2.0, Double(exponent)))
    }

    func extractErrorSignals(rawText: String) -> ErrorSignals {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            collectErrorParts(value, into: &parts)
        }

        if parts.isEmpty, !trimmed.isEmpty {
            parts.append(trimmed)
        }

        let deduped = parts.reduce(into: [String]()) { acc, item in
            guard !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !acc.contains(item) {
                acc.append(item)
            }
        }

        let joined = deduped.joined(separator: " | ")
        let brief = joined.isEmpty ? L10n.tr("error.proxy_runtime.no_error_detail") : truncateForError(joined, maxLength: 120)

        return ErrorSignals(
            normalized: "\(joined) \(trimmed)".lowercased(),
            brief: brief
        )
    }

    func collectErrorParts(_ value: [String: Any], into parts: inout [String]) {
        if let error = value["error"] as? [String: Any] {
            if let message = error["message"] as? String { parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let code = error["code"] as? String { parts.append(code.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let type = error["type"] as? String { parts.append(type.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if let message = value["message"] as? String {
            parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func containsQuotaSignal(_ text: String) -> Bool {
        text.contains("insufficient_quota")
            || text.contains("quota exceeded")
            || text.contains("usage_limit")
            || text.contains("usage limit")
            || text.contains("credit balance")
            || text.contains("billing hard limit")
            || text.contains("exceeded your current quota")
            || text.contains("usage_limit_reached")
    }

    func containsRateLimitSignal(_ text: String) -> Bool {
        text.contains("rate limit")
            || text.contains("rate_limit")
            || text.contains("too many requests")
            || text.contains("requests per min")
            || text.contains("tokens per min")
            || text.contains("retry after")
            || text.contains("requests too quickly")
    }

    func containsModelRestrictionSignal(_ text: String) -> Bool {
        text.contains("model_not_found")
            || text.contains("does not have access to model")
            || text.contains("do not have access to model")
            || text.contains("access to model")
            || text.contains("unsupported model")
            || text.contains("model is not supported")
            || text.contains("not available on your account")
            || text.contains("model access")
    }

    func containsAuthSignal(_ text: String) -> Bool {
        text.contains("invalid_api_key")
            || text.contains("invalid api key")
            || text.contains("authentication")
            || text.contains("unauthorized")
            || text.contains("token expired")
            || text.contains("account deactivated")
            || text.contains("invalid token")
    }

    func containsPermissionSignal(_ text: String) -> Bool {
        text.contains("permission")
            || text.contains("forbidden")
            || text.contains("not allowed")
            || text.contains("organization")
            || text.contains("access denied")
    }

    func buildRetriableFailureSummary(_ failures: [RetryFailureInfo]) -> String {
        var quota = 0
        var rate = 0
        var model = 0
        var auth = 0
        var permission = 0
        var serverError = 0

        for failure in failures {
            switch failure.category {
            case .quotaExceeded:
                quota += 1
            case .rateLimited:
                rate += 1
            case .modelRestricted:
                model += 1
            case .authentication:
                auth += 1
            case .permission:
                permission += 1
            case .serverError:
                serverError += 1
            }
        }

        var parts: [String] = []
        if quota > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.quota_format", String(quota))) }
        if rate > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.rate_format", String(rate))) }
        if model > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.model_format", String(model))) }
        if auth > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.auth_format", String(auth))) }
        if permission > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.permission_format", String(permission))) }
        if serverError > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.server_error_format", String(serverError))) }

        return parts.joined(separator: "，")
    }
}

enum RetryFailureCategory {
    case quotaExceeded
    case rateLimited
    case modelRestricted
    case authentication
    case permission
    case serverError
}

struct RetryFailureInfo {
    var category: RetryFailureCategory
    var failureClass: UpstreamFailureClass
    var detail: String
}

struct ErrorSignals {
    var normalized: String
    var brief: String
}
