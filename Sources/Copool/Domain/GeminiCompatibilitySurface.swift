import Foundation

/// 把公有 Gemini 路由从原生 `generateContent` 改写到 Google 自己的
/// OpenAI 兼容面（M4-8 / FR-PRO-06）。
///
/// 动机不是"少写一个适配器"，而是**别再养第二条协议分支**。走 `.chat` 之后，
/// 请求档案（FR-PRO-05）、出站头白名单（SEC-04）、七类失败重试（FR-RTE-04）、
/// SSE 中断收尾帧、usage 归集这些东西对 Gemini 自动成立；原生路径每加一项
/// 都要在 `convertChatToGemini` / `translateGeminiSSEChunk` 里再实现一遍，
/// 而两边行为一旦漂移，症状只会出现在 Gemini 用户身上、且没有任何一处会报错。
///
/// **Antigravity 不在改写范围内**：它的 OAuth token scope 只覆盖 CloudCode
/// 内网端点（`daily-cloudcode-pa.googleapis.com/v1internal`），公有
/// generativelanguage 面根本不认这个凭据。而它配置里的 baseURL 恰好也写着
/// `generativelanguage.googleapis.com/v1beta`（历史遗留，实际请求时被
/// `makeThirdPartyRequest` 换掉），所以**只看 host 会误伤**——必须同时看
/// 凭据种类和名字。
enum GeminiCompatibilitySurface {
    /// Google 公有 Gemini API 的 host。
    static let publicHost = "generativelanguage.googleapis.com"

    /// 兼容面相对 API 版本段的路径。
    static let compatibilitySegment = "openai"

    /// 兼容面所在的 API 版本段。baseURL 只写到 host 时补这一段。
    static let defaultVersionSegment = "v1beta"

    /// 走 CloudCode 内网端点、不能改写的 provider 名。
    static let cloudCodeProviderNames: Set<String> = ["antigravity", "agy"]

    /// 归一化一条第三方路由的协议与 baseURL。
    ///
    /// 不适用时**原样返回**——调用方不需要分支，也就不会漏掉某个构造点。
    static func normalize(
        protocolKind: ProviderProtocol,
        baseURL: String,
        providerName: String,
        authKind: ProviderAuthKind
    ) -> (protocolKind: ProviderProtocol, baseURL: String) {
        guard shouldRewrite(protocolKind: protocolKind, baseURL: baseURL, providerName: providerName, authKind: authKind) else {
            return (protocolKind, baseURL)
        }
        return (.chat, compatibilityBaseURL(from: baseURL))
    }

    static func shouldRewrite(
        protocolKind: ProviderProtocol,
        baseURL: String,
        providerName: String,
        authKind: ProviderAuthKind
    ) -> Bool {
        guard protocolKind == .google else { return false }
        // 订阅导入的登录态一律不动：它们的 token 是给某个特定客户端端点签的，
        // 换个 host 只会拿到 401——而 401 在多账号池里会被记成"凭据失效"，
        // 用户看到的是"我的 Antigravity 订阅坏了"，而不是"代理走错了地址"。
        guard authKind == .apiKey else { return false }
        guard !cloudCodeProviderNames.contains(providerName.lowercased()) else { return false }
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host else { return false }
        return host.lowercased() == publicHost
    }

    /// `…/v1beta` → `…/v1beta/openai`；已经指向兼容面时保持不变。
    static func compatibilityBaseURL(from baseURL: String) -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let segments = normalized.split(separator: "/").map(String.init)
        if segments.last?.lowercased() == compatibilitySegment { return normalized }
        // baseURL 只写到 host（没有版本段）时补全版本段——直接挂 `/openai`
        // 会得到 `https://…googleapis.com/openai`，一个 404。
        if let last = segments.last, last.hasPrefix("v"), last.dropFirst().first?.isNumber == true {
            return normalized + "/" + compatibilitySegment
        }
        return normalized + "/" + defaultVersionSegment + "/" + compatibilitySegment
    }
}
