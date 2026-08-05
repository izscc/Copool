import Foundation

extension SwiftNativeProxyRuntimeService {
    func classifyRetryFailure(statusCode: Int, bodyText: String) -> RetryFailureInfo? {
        let signals = extractErrorSignals(rawText: bodyText)
        let status = statusCode

        if status == 402 || containsQuotaSignal(signals.normalized) {
            return RetryFailureInfo(category: .quotaExceeded, detail: L10n.tr("error.proxy_runtime.retry.quota_exceeded_format", signals.brief))
        }
        if containsModelRestrictionSignal(signals.normalized) {
            return RetryFailureInfo(category: .modelRestricted, detail: L10n.tr("error.proxy_runtime.retry.model_restricted_format", signals.brief))
        }
        if status == 429 || containsRateLimitSignal(signals.normalized) {
            return RetryFailureInfo(category: .rateLimited, detail: L10n.tr("error.proxy_runtime.retry.rate_limited_format", signals.brief))
        }
        if status == 401 || containsAuthSignal(signals.normalized) {
            return RetryFailureInfo(category: .authentication, detail: L10n.tr("error.proxy_runtime.retry.auth_failed_format", signals.brief))
        }
        if status == 403 || containsPermissionSignal(signals.normalized) {
            return RetryFailureInfo(category: .permission, detail: L10n.tr("error.proxy_runtime.retry.permission_denied_format", signals.brief))
        }
        // AC-013: transient 5xx (except 501/505 — "not implemented"/"version
        // not supported" are permanent) are retriable on another candidate.
        if status >= 500 && status <= 599 && status != 501 && status != 505 {
            return RetryFailureInfo(category: .serverError, detail: L10n.tr("error.proxy_runtime.retry.server_error_format", signals.brief))
        }
        return nil
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
    var detail: String
}

struct ErrorSignals {
    var normalized: String
    var brief: String
}
