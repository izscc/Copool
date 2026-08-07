import Foundation

/// Redacts secrets from diagnostic output. Anything that smells like a
/// credential — API keys, tokens, Authorization header values, keychain
/// payloads — is replaced with `REDACTED` before logs or bundles leave the
/// machine (PRD: "无明文 secret 进入日志或支持包"; AC-014).
///
/// 放在 Domain：脱敏是纯字符串变换，没有 IO，且 `CredentialHealthEvaluator`
/// 落盘前必须调它（INV-1）。留在 Infrastructure 会让 Domain 反向依赖
/// Infrastructure——单模块下编译得过，但方向是错的，也让 Domain 的单测被迫
/// 拖进支持包那一整套文件系统代码。
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
