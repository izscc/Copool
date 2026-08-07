import Foundation

/// RequestProfile 应用层（FR-PRO-05 / DM-06）。
///
/// 把目录条目的 `requestProfile` 规则变换到出站 payload 上，让每家上游收到
/// 它能接受的字段组合——DashScope 兼容面会拒绝各厂商原生 `thinking`，xAI 的
/// OAuth 通道要求附加托管工具裸声明，Kimi K3 强制 max 档位。
///
/// 放在 Domain 而不是 Infrastructure：它是一个纯函数（profile + payload →
/// payload），没有 IO、没有 actor 状态。放这里单测可以直接断言变换结果，
/// 不必把整个代理运行时拖起来。
///
/// **保守优先**：未命中 profile（用户自建 provider）时不附加任何非标准字段。
/// 猜错方向的代价不对称——误以为上游接受某字段，请求直接 400；误以为不接受，
/// 只是少一个开关。
enum RequestProfileApplicator {
    /// 各 `ReasoningParameter` 对应的线上 JSON 字段名。
    ///
    /// 单独列出来而不是用 `rawValue`：枚举的 rawValue 是 camelCase（Swift
    /// 侧的命名），而线格式是 snake_case。靠 rawValue 会静默发出
    /// `reasoningEffort` 这种上游根本不认识的字段名——它不会报错，只会被
    /// 忽略，于是"推理档位设置无效"变成一个没人能查出原因的现象。
    static func wireFieldName(for parameter: RequestProfile.ReasoningParameter) -> String? {
        switch parameter {
        case .none: return nil
        case .reasoningEffort: return "reasoning_effort"
        case .thinking: return "thinking"
        case .enableThinking: return "enable_thinking"
        case .thinkingBudget: return "thinking_budget"
        }
    }

    /// 所有厂商原生 thinking 字段的线上名。剥离时按这张表清空。
    static let vendorNativeThinkingFields: [String] = [
        "thinking",           // DeepSeek / GLM
        "reasoning_effort",   // xAI / OpenAI 兼容
        "thinking_budget",    // Anthropic extended thinking
        "enable_thinking",    // 通义千问原生
        "reasoning",          // Responses API 风格
    ]

    /// 表示"关闭推理"的档位标记。
    static let disableEffort = "disable"

    /// 应用 profile 规则到 payload，返回新 payload（入参不变）。
    ///
    /// - Parameters:
    ///   - profile: 目标上游的请求档案。`.conservativeDefault` 表示未命中，
    ///     此时只做剥离（若要求）而不附加任何字段。
    ///   - payload: 下游发来的原始请求体。
    ///   - requestedEffort: 本次请求解析出的推理档位；nil 表示下游没表态。
    static func apply(
        profile: RequestProfile,
        to payload: [String: Any],
        requestedEffort: String? = nil
    ) -> [String: Any] {
        var output = payload

        // ① 剥离厂商原生 thinking 参数。
        //
        // 顺序很关键：必须在附加之前剥离。反过来的话，dashscope-compatible
        // 先写入 enable_thinking、再被剥离逻辑抹掉，等于什么都没做。
        if profile.stripVendorNativeThinking {
            for field in vendorNativeThinkingFields {
                output.removeValue(forKey: field)
            }
        }

        // ② 按 profile 重建推理参数。
        output = applyReasoningParameter(
            profile: profile,
            to: output,
            requestedEffort: requestedEffort
        )

        // ③ 注入托管工具裸声明。
        if !profile.injectHostedTools.isEmpty {
            output = injectHostedTools(profile.injectHostedTools, into: output)
        }

        return output
    }

    // MARK: - 推理参数

    private static func applyReasoningParameter(
        profile: RequestProfile,
        to payload: [String: Any],
        requestedEffort: String?
    ) -> [String: Any] {
        guard let field = wireFieldName(for: profile.reasoningParameter) else {
            // `.none`：该通道由上游决定推理深度（多数 OAuth 通道），或该模型
            // 不支持推理。两种情况都不该附加字段。
            return payload
        }

        // forcedEffort 覆盖用户选择——上游只接受这一档，发别的会被拒。
        let effort = profile.forcedEffort ?? requestedEffort

        // 下游没表态且上游没强制：不猜。让上游用它自己的默认值，这比我们
        // 替用户选一个（可能更贵的）档位安全。
        guard let effort, !effort.isEmpty else { return payload }

        // 用户要求关闭，但上游不支持关闭：不附加字段而不是发一个会被拒的
        // "关闭"值。少一个开关，好过整条请求 400。
        if effort == disableEffort, !profile.supportsDisable {
            return payload
        }

        guard let value = reasoningValue(
            parameter: profile.reasoningParameter,
            effort: effort
        ) else {
            return payload
        }

        var output = payload
        output[field] = value
        return output
    }

    /// 把统一的档位字符串编码成各家要求的 JSON 值形状。
    private static func reasoningValue(
        parameter: RequestProfile.ReasoningParameter,
        effort: String
    ) -> Any? {
        switch parameter {
        case .none:
            return nil
        case .reasoningEffort:
            // xAI / OpenAI 兼容：裸字符串。
            return effort
        case .thinking:
            // DeepSeek / GLM：`{"type": "enabled"}` / `{"type": "disabled"}`。
            return effort == disableEffort
                ? ["type": "disabled"]
                : ["type": "enabled"]
        case .enableThinking:
            // DashScope 兼容面：布尔量。
            return effort != disableEffort
        case .thinkingBudget:
            // Anthropic extended thinking：token 预算（整数）。
            return effort == disableEffort ? 0 : thinkingBudget(for: effort)
        }
    }

    /// 档位 → Anthropic `thinking_budget` token 数。
    ///
    /// 未知档位落到 high 而不是 max：多花一倍的钱换一个我们并不确定用户想要
    /// 的深度，是错的方向。
    static func thinkingBudget(for effort: String) -> Int {
        switch effort.lowercased() {
        case "minimal", "none": return 1024
        case "low": return 5_000
        case "medium": return 12_000
        case "high": return 20_000
        case "max", "xhigh": return 50_000
        default: return 20_000
        }
    }

    // MARK: - 托管工具

    /// 注入托管工具裸声明。
    ///
    /// 托管工具由上游决定何时调用，客户端只需声明它存在——不传
    /// `description` / `parameters`，那些由上游定义。xAI 的 OAuth 通道明确
    /// 拒绝带本地检索参数的声明（见 seed 里 xai-oauth-hosted-tools 的 notes）。
    ///
    /// 不覆盖用户自己传的 `tools`：同名跳过，其余追加到尾部。用户显式声明的
    /// 工具带着他自己的 schema，被我们的裸声明顶掉会让工具调用参数全部失效。
    private static func injectHostedTools(
        _ toolNames: [String],
        into payload: [String: Any]
    ) -> [String: Any] {
        var output = payload
        var tools = (output["tools"] as? [[String: Any]]) ?? []

        for name in toolNames {
            let alreadyDeclared = tools.contains { tool in
                if let function = tool["function"] as? [String: Any],
                   let existing = function["name"] as? String {
                    return existing == name
                }
                // Responses API 风格：`{"type": "web_search"}`。
                if let type = tool["type"] as? String {
                    return type == name
                }
                return false
            }
            guard !alreadyDeclared else { continue }
            tools.append([
                "type": "function",
                "function": ["name": name],
            ])
        }

        output["tools"] = tools
        return output
    }
}
