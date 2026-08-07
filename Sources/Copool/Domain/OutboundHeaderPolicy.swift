import Foundation

/// 出站请求头白名单（FR-PRO-07，SEC-04）。
///
/// **白名单而非黑名单**，这是刻意的：第三方 provider 的数量在增长，客户端
/// （Codex CLI、Cursor、opencode、各种 OpenAI 兼容工具）发来的头也在增长。
/// 黑名单要求我们预先枚举出所有危险的头名——只要漏掉一个新出现的
/// `chatgpt-xxx-id`，用户的 ChatGPT 账号标识就被原样转发给了某个第三方网关，
/// 而且没有任何一处会报错。白名单的失败模式相反：漏掉一个无害的头，最多是
/// 某个 provider 少收到一点上下文，改一行就能补上。
///
/// 具体禁止转发的东西（都来自 Codex CLI 与 ChatGPT 官方链路）：
/// account id、session id、installation id、device id、attestation 头、
/// originator，以及所有 `chatgpt-*` / `openai-*` 前缀的头。这些合起来足以把
/// 一个用户的 ChatGPT 订阅身份关联到任意第三方服务。
enum OutboundHeaderPolicy: Sendable {
    /// Copool 自己的 User-Agent。
    ///
    /// 转发下行客户端的 UA 会把「这个用户在用 Codex CLI 0.101.0」告诉每一家
    /// 第三方 provider——这既是身份指纹，也没有任何功能上的必要。
    static let userAgent = "Copool/1.0 (+https://github.com/copool)"

    /// 唯一允许从下行请求原样转发到第三方上行的头（小写名）。
    ///
    /// 只有这两个：它们描述的是**本次请求的载荷格式**，与用户身份无关。
    static let forwardableDownstreamHeaders: Set<String> = [
        "content-type",
        "accept",
    ]

    /// 明令禁止出现在第三方上行请求里的头（小写名）。
    ///
    /// 白名单已经能挡住它们了；这份清单存在的意义是让测试可以正面断言
    /// 「这些名字一个都不能出现」（AC-116），而不是只断言集合包含关系。
    static let forbiddenExactNames: Set<String> = [
        // ChatGPT / Codex 身份
        "chatgpt-account-id",
        "chatgpt-account-user-id",
        "session_id",
        "session-id",
        "installation-id",
        "x-installation-id",
        "oai-device-id",
        "device-id",
        "x-device-id",
        "originator",
        "version",
        // attestation / 反滥用
        "attestation",
        "x-attestation",
        "oai-attestation",
        "x-oai-attestation",
        // 下行自己的凭据：上行用的是 Copool 选中的凭据，
        // 客户端发来的 key 绝不能顺着转发出去
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "cookie",
        "set-cookie",
    ]

    /// 禁止的头名前缀。前缀匹配是白名单之外的第二层保险：
    /// 上游哪天新加一个 `chatgpt-workspace-id`，不需要有人记得来更新清单。
    static let forbiddenPrefixes: [String] = [
        "chatgpt-",
        "openai-",
        "x-chatgpt-",
        "x-openai-",
        "oai-",
    ]

    /// 这个头能不能出现在发往第三方 provider 的请求里。
    static func isForbiddenForThirdParty(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if forbiddenExactNames.contains(lowered) { return true }
        return forbiddenPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// 从下行请求头里筛出允许转发的部分。
    ///
    /// 双重判定（先白名单、再禁止清单）不是冗余：万一以后有人往
    /// `forwardableDownstreamHeaders` 里加了一个恰好也在禁止清单里的名字，
    /// 禁止的一方赢。安全默认值应该是「拒绝」。
    static func sanitizedForwardHeaders(from downstream: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawName, rawValue) in downstream {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard forwardableDownstreamHeaders.contains(name) else { continue }
            guard !isForbiddenForThirdParty(name) else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// 组装发往第三方 provider 的完整出站头集合。
    ///
    /// - Parameters:
    ///   - downstream: 下行客户端发来的头（任意大小写）。
    ///   - authHeaders: 该 provider 所需的鉴权头，由调用方按 provider 协议构造。
    ///   - contentType: 本次上行的 Content-Type。
    ///   - accept: 本次上行的 Accept。
    ///   - providerUserAgent: 某些 provider 会按 UA 放行/限流（Grok、Antigravity），
    ///     传入即覆盖 Copool 的默认 UA；传 nil 用默认。
    /// - Returns: 小写头名 → 值。调用方直接照单设置，不再额外加头。
    static func outboundHeaders(
        downstream: [String: String],
        authHeaders: [String: String],
        contentType: String,
        accept: String,
        providerUserAgent: String? = nil
    ) -> [String: String] {
        var result = sanitizedForwardHeaders(from: downstream)

        // 本次上行自己的载荷描述覆盖下行转发来的同名值：
        // 下行可能是 zstd 压缩的 chat 请求，上行是解压后的 JSON。
        result["content-type"] = contentType
        result["accept"] = accept
        result["user-agent"] = providerUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? userAgent
        result["connection"] = "Keep-Alive"

        // 鉴权头最后写：它是这次请求存在的理由，不该被任何转发逻辑覆盖。
        for (rawName, value) in authHeaders {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
