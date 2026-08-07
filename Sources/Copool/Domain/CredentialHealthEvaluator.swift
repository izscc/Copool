import Foundation

/// 凭据健康五态的判定规则（FR-IDT-07）。
///
/// 纯函数，无 IO：三个驱动信号（本地存在性、令牌过期时间、最近一次真实
/// 请求的响应码）全部由调用方注入。Keychain 探测与网络请求留在
/// `CredentialCoordinator`，判定逻辑留在这里——否则这段规则只能靠集成
/// 测试覆盖，而它恰恰是最需要逐条锁定的部分。
enum CredentialHealthEvaluator {

    /// 最近一次真实请求的结果。**不是**连通性测试的结果——网络不通不该
    /// 让凭据变成"无权限"（FR-CAT-09）。
    enum ProbeOutcome: Equatable, Sendable {
        /// 请求成功，凭据确实能用。
        case succeeded
        /// 401：鉴权被拒。这是唯一能断定凭据无效的信号。
        case unauthorized(detail: String?)
        /// 403 且错误体是配额类。凭据本身有效，只是被限流。
        case quotaExhausted(detail: String?)
        /// 403 且错误体是禁止类（地域封锁、模型未开通、账号被禁）。
        case forbidden(detail: String?)
        /// 429：短时限流。
        case rateLimited(detail: String?)
        /// 网络层失败（超时、DNS、连接被拒）。**不改变**凭据健康状态。
        case networkFailure(detail: String?)
        /// 上游 5xx。同样不是凭据的问题。
        case upstreamFailure(detail: String?)
    }

    /// 判定所需的全部输入。
    struct Signals: Equatable, Sendable {
        /// 凭据的存储形态。环境变量类与外部 CLI 会话类的"存在性"判定方式
        /// 与 Keychain 类不同，所以要区分。
        var kind: CredentialKind
        /// 秘密在本地确实存在：Keychain 里读到了、环境变量已设置、
        /// CLI 会话文件可读。调用方负责探测，这里只接受结论。
        var secretPresent: Bool
        /// 令牌过期时间（Unix 秒）。nil 表示"不会过期"或"未知"——
        /// 长期 API Key 属于前者。
        var expiresAt: Int64?
        /// 判定时刻（Unix 秒）。显式传入，便于锁定边界。
        var now: Int64
        /// 最近一次真实请求的结果。nil 表示还没发过任何请求。
        var lastProbe: ProbeOutcome?
        /// 用户正在走授权/校验流程。它压过其余信号——校验中就是校验中，
        /// 此时把状态显示成"未配置"会让用户以为操作没生效。
        var verificationInFlight: Bool

        init(
            kind: CredentialKind,
            secretPresent: Bool,
            expiresAt: Int64? = nil,
            now: Int64,
            lastProbe: ProbeOutcome? = nil,
            verificationInFlight: Bool = false
        ) {
            self.kind = kind
            self.secretPresent = secretPresent
            self.expiresAt = expiresAt
            self.now = now
            self.lastProbe = lastProbe
            self.verificationInFlight = verificationInFlight
        }
    }

    /// 判定结果。限流是**正交**维度：限流中的凭据仍然是就绪的，只是权重
    /// 该降低（FR-RTE-03）。把它塞进五态会让"限流"看起来像"坏了"，
    /// 用户会去重填一把完全正常的 Key。
    struct Verdict: Equatable, Sendable {
        var state: CredentialHealthState
        var throttled: Bool
        /// 已脱敏的失败原因，可直接入库与展示。
        var failureReason: String?

        init(state: CredentialHealthState, throttled: Bool = false, failureReason: String? = nil) {
            self.state = state
            self.throttled = throttled
            self.failureReason = failureReason
        }
    }

    /// 按 FR-IDT-07 判定：
    /// 校验中 > 本地不存在 → 未配置 > 401 → 无权限 > 过期时间已过 → 已过期
    /// > 其余 → 就绪（403 配额类与 429 附带限流标记）。
    ///
    /// 顺序不是随意的：先答"能不能用"，再答"为什么不能用"。把过期检查放在
    /// 401 之前会让一个刚被吊销的令牌显示成"已过期"，引导用户去续期一个
    /// 根本续不回来的凭据。
    static func evaluate(_ signals: Signals) -> Verdict {
        if signals.verificationInFlight {
            return Verdict(state: .verifying)
        }
        guard signals.secretPresent else {
            return Verdict(state: .unconfigured)
        }

        switch signals.lastProbe {
        case .unauthorized(let detail):
            return Verdict(state: .unauthorized, failureReason: redact(detail))
        case .forbidden(let detail):
            // 禁止类 403 不是配额问题：凭据能过鉴权，但这个账号不被允许做
            // 这件事。归到"无权限"，用户要做的是去开通而不是换 Key。
            return Verdict(state: .unauthorized, failureReason: redact(detail))
        default:
            break
        }

        if let expiresAt = signals.expiresAt, expiresAt <= signals.now {
            return Verdict(state: .expired, failureReason: nil)
        }

        switch signals.lastProbe {
        case .quotaExhausted(let detail):
            return Verdict(state: .ready, throttled: true, failureReason: redact(detail))
        case .rateLimited(let detail):
            return Verdict(state: .ready, throttled: true, failureReason: redact(detail))
        case .networkFailure(let detail), .upstreamFailure(let detail):
            // 网络与上游故障保留原因供展示，但状态仍是就绪——把网络问题
            // 记成凭据失效，用户会白白重填一次 Key（FR-CAT-09）。
            return Verdict(state: .ready, failureReason: redact(detail))
        case .succeeded, .none:
            return Verdict(state: .ready)
        case .unauthorized, .forbidden:
            return Verdict(state: .unauthorized)
        }
    }

    /// 限流窗口时长（秒）。
    ///
    /// 60 秒是个折中：多数上游的 429 退避窗口在几秒到一分钟量级，取上限能
    /// 避免我们在窗口内反复撞墙；同时它足够短，一次偶发限流不会让这家
    /// provider 在用户的下一轮对话里还处于降权状态。
    static let throttleWindowSeconds: Int64 = 60

    /// 把判定结果写回凭据。`lastVerifiedAt` 只在真实请求成功时前移——
    /// 网络失败不算"验证过"，否则 UI 会显示一个从未成功的凭据"刚刚验证通过"。
    static func apply(_ verdict: Verdict, to credential: CredentialIdentity, at now: Int64) -> CredentialIdentity {
        var updated = credential
        updated.healthState = verdict.state
        updated.lastFailureReason = verdict.failureReason
        if verdict.throttled {
            // 续期而不是叠加：连续几次 429 应该把窗口推到"最后一次 + 60s"，
            // 而不是累积成十分钟。
            updated.throttledUntil = now + throttleWindowSeconds
        } else if verdict.state == .ready, verdict.failureReason == nil {
            // 一次干净的成功即刻解除限流——等窗口自然过期会白白降权一个
            // 已经证明可用的凭据。
            updated.throttledUntil = nil
        }
        if verdict.state == .ready, verdict.failureReason == nil, !verdict.throttled {
            updated.lastVerifiedAt = now
        }
        return updated
    }

    /// 从 HTTP 状态码与响应体推断结果。403 的两种含义只能从错误体区分——
    /// 状态码本身不够。
    static func outcome(statusCode: Int, responseBody: String?) -> ProbeOutcome {
        let detail = responseBody.map { String($0.prefix(400)) }
        switch statusCode {
        case 200...299:
            return .succeeded
        case 401:
            return .unauthorized(detail: detail)
        case 403:
            return isQuotaRelated(detail) ? .quotaExhausted(detail: detail) : .forbidden(detail: detail)
        case 429:
            return .rateLimited(detail: detail)
        case 500...599:
            return .upstreamFailure(detail: detail)
        default:
            return .upstreamFailure(detail: detail)
        }
    }

    /// 配额类关键词。命中即当作限流，宁可少判一次"无权限"——
    /// 误判成无权限会让一个正常的凭据显示为坏的，代价更大。
    private static let quotaKeywords = [
        "quota", "insufficient", "balance", "credit", "exceeded",
        "rate limit", "rate_limit", "too many", "arrearage",
        "余额", "配额", "欠费", "限流",
    ]

    private static func isQuotaRelated(_ detail: String?) -> Bool {
        guard let detail, !detail.isEmpty else { return false }
        let lowered = detail.lowercased()
        return quotaKeywords.contains { lowered.contains($0) }
    }

    /// 入库前脱敏。上游错误体里常回显 key 片段与账号邮箱，原样存盘等于把
    /// 秘密落盘（INV-1）。复用支持包那套规则，避免两份不一致的脱敏实现。
    static func redact(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SecretRedactor.redactText(String(trimmed.prefix(400)))
    }
}

