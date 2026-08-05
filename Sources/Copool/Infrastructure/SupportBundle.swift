import Foundation

/// Redacts secrets from diagnostic output. Anything that smells like a
/// credential — API keys, tokens, Authorization header values, keychain
/// payloads — is replaced with `REDACTED` before logs or bundles leave the
/// machine (PRD: "无明文 secret 进入日志或支持包"; AC-014).
enum SecretRedactor {
    static let redaction = "REDACTED"

    /// Header values that must never appear in output.
    static let sensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "api-key", "openai-api-key", "x-xai-token-auth",
    ]

    static func redactHeader(_ name: String, value: String) -> String {
        if sensitiveHeaderNames.contains(name.lowercased()) {
            return redaction
        }
        return value
    }

    /// Redacts common secret patterns inside free text: bearer tokens, sk-…
    /// keys, keychain payload lines, `key = "value"` lines where the key
    /// smells like a credential.
    static func redactText(_ text: String) -> String {
        var result = text
        // Bearer tokens.
        result = replace(pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{12,}"#, in: result) {
            "\($0)\(redaction)"
        }
        // OpenAI-style keys.
        result = replace(pattern: #"(?i)\b(sk-[A-Za-z0-9_-]{12,})"#, in: result) { _ in redaction }
        // xai / grok tokens.
        result = replace(pattern: #"(?i)\b(xai-[A-Za-z0-9_-]{12,})"#, in: result) { _ in redaction }
        // refresh tokens in JSON.
        result = replace(pattern: #"(?i)("(?:refresh_?token|access_?token|api_?key|secret)"\s*:\s*")[^"]*"#, in: result) {
            "\($0)\(redaction)\""
        }
        // Keychain payload dump lines.
        result = replace(pattern: #"(?m)^\s*("?[A-Za-z0-9._-]*(?:token|secret|key|password)["\s]*[:=]\s*).+$"#, in: result) {
            "\($0)\(redaction)"
        }
        return result
    }

    private static func replace(pattern: String, in text: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: nsRange) { match in
            guard let range = Range(match.range, in: text) else { return (text as NSString).substring(with: match.range) }
            return transform(String(text[range]))
        }
    }
}

extension NSRegularExpression {
    func stringByReplacingMatches(in string: String, range: NSRange, using transform: (NSTextCheckingResult) -> String) -> String {
        var result = ""
        var cursor = string.startIndex
        for match in matches(in: string, range: range) {
            let matchRange = Range(match.range, in: string)!
            result += string[cursor..<matchRange.lowerBound]
            result += transform(match)
            cursor = matchRange.upperBound
        }
        result += string[cursor...]
        return String(result)
    }
}

/// Collects a redacted diagnostic bundle: environment facts, config
/// fingerprints, provider metadata (references, never values) and recent
/// ledger stats. No secrets, no keychain values, no auth payloads.
struct SupportBundleBuilder: Sendable {
    var paths: FileSystemPaths
    var now: @Sendable () -> Date

    init(paths: FileSystemPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.now = now
    }

    /// Builds a redacted support bundle as a JSON document.
    func build(providers: [ProviderConfig], engineStatus: RouterEngineStatus?) async -> String {
        var bundle: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: now()),
            "appVersion": AppVersion.current.description,
        ]

        // Environment facts.
        bundle["environment"] = [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostname": Host.current().localizedName ?? "unknown",
        ]

        // Provider metadata: references only.
        bundle["providers"] = providers.map { provider in
            [
                "id": provider.id,
                "name": provider.name,
                "baseURL": provider.baseURL,
                "authKind": provider.authKind.rawValue,
                "modelCount": provider.models.count,
                "keychainAccountRef": "keychain:\(provider.id)",
            ]
        }

        // Config fingerprints (never content).
        bundle["configFingerprints"] = [
            "codexConfig": fingerprint(paths.codexConfigPath),
            "providersStore": fingerprint(paths.providerStorePath),
            "registryV2": fingerprint(paths.registryV2Path),
        ]

        // Engine status (may contain the API key — redact it).
        if let status = engineStatus {
            bundle["engine"] = [
                "running": status.running,
                "port": status.port ?? -1,
                "apiKey": status.apiKey.map { _ in SecretRedactor.redaction } ?? "none",
                "availableAccounts": status.availableAccounts,
                "lastError": status.lastError.map(SecretRedactor.redactText) ?? "none",
            ]
        }

        // Recent usage ledger stats (no prompts, only aggregates).
        let ledger = UsageEventLedger(path: paths.usageEventsPath)
        let aggregates = ledger.dailyAggregates(days: 3)
        bundle["usageLast3Days"] = aggregates.map {
            ["day": $0.day, "providerID": $0.providerID, "requests": $0.requests, "totalTokens": $0.totalTokens]
        }

        let data = (try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func fingerprint(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "absent" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
