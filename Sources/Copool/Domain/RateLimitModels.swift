import Foundation

/// One harvested quota window (requests or tokens) for a provider.
struct RateLimitWindow: Codable, Equatable, Sendable {
    var limit: Int?
    var remaining: Int?
    /// Absolute epoch seconds at which the window resets.
    var resetAt: Int64?
}

/// Rate-limit facts passively harvested from provider response headers.
///
/// Most OpenAI-compatible providers report remaining quota on every response
/// through `x-ratelimit-*` headers; Anthropic reports the same under an
/// `anthropic-ratelimit-*` prefix. Reading them costs no extra request and
/// needs no provider-specific balance endpoint.
struct ProviderRateLimitSnapshot: Codable, Equatable, Sendable {
    var providerID: String
    var requests: RateLimitWindow?
    var tokens: RateLimitWindow?
    /// Parsed `retry-after`, absolute epoch seconds.
    var retryAt: Int64?
    var capturedAt: Int64

    /// The soonest moment this provider is worth retrying, or nil when nothing
    /// says the caller is currently limited. Mirrors codex-router's
    /// `cooldownUntil`: the latest of retry-after, a zeroed requests window,
    /// or a zeroed tokens window.
    var cooldownUntil: Int64? {
        let candidates = [
            retryAt,
            requests?.remaining == 0 ? requests?.resetAt : nil,
            tokens?.remaining == 0 ? tokens?.resetAt : nil,
        ].compactMap { $0 }
        return candidates.max()
    }
}

/// Pure parsing of rate-limit response headers (codex-router port).
enum RateLimitHeadersParser {
    /// Headers are lowercased by `SimpleHTTPServer` and the proxy's upstream
    /// plumbing, matching the keys below.
    static func parse(
        headers: [String: String],
        providerID: String,
        now: Date = Date()
    ) -> ProviderRateLimitSnapshot? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let requests = window(
            headers: headers,
            limitKeys: ["x-ratelimit-limit-requests", "anthropic-ratelimit-requests-limit", "x-ratelimit-limit"],
            remainingKeys: ["x-ratelimit-remaining-requests", "anthropic-ratelimit-requests-remaining", "x-ratelimit-remaining"],
            resetKeys: ["x-ratelimit-reset-requests", "anthropic-ratelimit-requests-reset", "x-ratelimit-reset"],
            nowMs: nowMs
        )
        let tokens = window(
            headers: headers,
            limitKeys: ["x-ratelimit-limit-tokens", "anthropic-ratelimit-tokens-limit"],
            remainingKeys: ["x-ratelimit-remaining-tokens", "anthropic-ratelimit-tokens-remaining"],
            resetKeys: ["x-ratelimit-reset-tokens", "anthropic-ratelimit-tokens-reset"],
            nowMs: nowMs
        )
        let retryAt = resetAt(headers["retry-after"], nowMs: nowMs)

        guard requests != nil || tokens != nil || retryAt != nil else { return nil }
        return ProviderRateLimitSnapshot(
            providerID: providerID,
            requests: requests,
            tokens: tokens,
            retryAt: retryAt,
            capturedAt: nowMs / 1000
        )
    }

    // MARK: - Window parsing

    private static func window(
        headers: [String: String],
        limitKeys: [String],
        remainingKeys: [String],
        resetKeys: [String],
        nowMs: Int64
    ) -> RateLimitWindow? {
        let limit = count(read(headers, limitKeys))
        let remaining = count(read(headers, remainingKeys))
        let reset = resetAt(read(headers, resetKeys), nowMs: nowMs)
        if limit == nil && remaining == nil && reset == nil { return nil }
        return RateLimitWindow(limit: limit, remaining: remaining, resetAt: reset)
    }

    private static func read(_ headers: [String: String], _ keys: [String]) -> String? {
        for key in keys {
            if let value = headers[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func count(_ value: String?) -> Int? {
        guard let value, let number = Double(value), number >= 0 else { return nil }
        return Int(number.rounded())
    }

    /// Providers express resets three ways: a Go-style duration
    /// ("2m59.56s", "7.66s"), bare seconds ("60"), or an absolute timestamp.
    /// All normalize to absolute epoch seconds.
    private static func resetAt(_ value: String?, nowMs: Int64) -> Int64? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        // A plain number is seconds-from-now when small, and an epoch when it
        // is large enough to be a real timestamp (some gateways send epoch
        // seconds or milliseconds).
        if let bare = Double(text) {
            if bare >= 1_000_000_000 {
                return Int64(bare >= 1e12 ? bare / 1000 : bare)
            }
            return bare >= 0 ? Int64((Double(nowMs) + bare * 1000) / 1000) : nil
        }

        // Go-style duration: 2m59.56s, 7.66s, 1h30m, 500ms
        let pattern = #"^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m(?!s))?(?:(\d+(?:\.\d+)?)m?s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        let hours = groupDouble(text, match, 1) ?? 0
        let minutes = groupDouble(text, match, 2) ?? 0
        let seconds = groupDouble(text, match, 3) ?? 0
        let hasSeconds = match.range(at: 3).location != NSNotFound
        let hasMillis = text.lowercased().hasSuffix("ms")
        let secondsValue = hasMillis ? seconds / 1000 : seconds
        let totalMs = hours * 3_600_000 + minutes * 60_000 + (hasSeconds || hasMillis ? secondsValue * 1000 : 0)
        guard totalMs > 0 || hours > 0 || minutes > 0 else { return nil }
        return Int64((Double(nowMs) + totalMs) / 1000)
    }

    private static func groupDouble(_ text: String, _ match: NSTextCheckingResult, _ index: Int) -> Double? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text),
              let value = Double(text[swiftRange]) else {
            return nil
        }
        return value
    }
}
