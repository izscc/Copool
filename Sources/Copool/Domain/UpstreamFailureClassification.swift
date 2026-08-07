import Foundation

/// 上游失败七分类（FR-RTE-04）。
///
/// **禁止无差别重试**：不同类别的失败采取不同的动作。把一切失败都当作
/// "网络问题"重试 3 次，会让一个 400 请求错误白白烧掉 3 倍成本、让一个
/// 401 鉴权失败的账号继续被路由（直到用户发现费用异常）、让一个已经产生
/// 部分费用的 SSE 中断被原样重发。
enum UpstreamFailureClass: String, Codable, Equatable, Sendable {
    /// 网络层失败（连接失败、读超时、DNS）。重试同账号，最多 2 次，指数退避。
    case networkTimeout
    /// HTTP 429 或响应体带限流关键词。换同 provider 的其他凭据；无其他则按
    /// `FallbackPolicy` 转移。
    case rateLimited
    /// HTTP 401。**不重试**，标记凭据"无权限"，立即返回。
    case unauthorized
    /// HTTP 403。区分配额型与禁止型：配额型按限流处理，禁止型不重试。
    case forbidden
    /// HTTP 400/404/422。**不重试**，原样透传上游错误体。
    case requestError
    /// HTTP 500/502/503。重试 1 次，仍失败则按 `FallbackPolicy` 转移。
    case upstreamError
    /// SSE 已开始后断开。**不重试**（已产生费用且客户端已收到部分内容），
    /// 发送 error 事件收尾。
    case streamInterrupted
}

extension UpstreamFailureClass {
    /// 从 HTTP 状态码与响应体推断分类。
    static func classify(statusCode: Int, responseBody: String?) -> UpstreamFailureClass {
        switch statusCode {
        case 401:
            return .unauthorized
        case 403:
            return isForbiddenQuotaRelated(responseBody) ? .rateLimited : .forbidden
        case 429:
            return .rateLimited
        case 400, 404, 422:
            return .requestError
        case 500...599:
            return .upstreamError
        default:
            // 非标准状态码（例如 CloudFlare 的 520/521/522）归入网络/上游失败，
            // 因为它们通常是边缘节点或代理层的问题，而不是请求本身的错误。
            return statusCode >= 520 ? .networkTimeout : .upstreamError
        }
    }

    /// 从网络层异常推断分类。
    static func classifyNetworkError(_ error: Error) -> UpstreamFailureClass {
        let nsError = error as NSError
        // URLError domain 的连接/超时/DNS 错误
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNetworkConnectionLost:
                return .networkTimeout
            default:
                break
            }
        }
        // 其余异常归为上游失败（例如 TLS 握手错误、意外 EOF）
        return .upstreamError
    }

    /// 403 的两种含义只能从错误体区分。配额类关键词列表与
    /// `CredentialHealthEvaluator.quotaKeywords` 一致，避免两套规则。
    private static let quotaKeywords = [
        "quota", "insufficient", "balance", "credit", "exceeded",
        "rate limit", "rate_limit", "too many", "arrearage",
        "余额", "配额", "欠费", "限流",
    ]

    private static func isForbiddenQuotaRelated(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        let lowered = body.lowercased()
        return quotaKeywords.contains { lowered.contains($0) }
    }

    /// 该分类是否应当换同 provider 的其他凭据。
    var shouldSwitchCredential: Bool {
        switch self {
        case .rateLimited: return true
        case .upstreamError: return true
        default: return false
        }
    }

    /// 该分类是否应当在当前凭据上重试（而不是换凭据或转移）。
    var shouldRetryWithSameCredential: Bool {
        switch self {
        case .networkTimeout: return true
        default: return false
        }
    }

    /// 最多重试次数（针对同一凭据）。
    var maxRetriesOnSameCredential: Int {
        switch self {
        case .networkTimeout: return 2
        case .upstreamError: return 1
        default: return 0
        }
    }

    /// 该分类是否应当立即标记凭据为"无权限"。
    var shouldMarkCredentialUnauthorized: Bool {
        self == .unauthorized
    }

    /// 同一凭据上已经用尽机会后，是否值得按 `FallbackPolicy` 改投别的候选。
    ///
    /// 判断标准是"换个落点还有没有可能成功"：
    /// - `.rateLimited` / `.upstreamError`：问题出在这一家，换一家可能就好了。
    /// - `.networkTimeout`：也许是到这个 endpoint 的链路问题，值得换。
    /// - `.requestError`：请求体本身不合法，换谁都是同一个 400，换只是多烧钱。
    /// - `.unauthorized` / `.forbidden`：凭据问题，且必须立刻让用户看见——
    ///   悄悄转移会把"这个账号已经失效了"这件事一直掩盖下去。
    /// - `.streamInterrupted`：费用已产生、客户端已收到半截内容，重发会得到
    ///   两段拼不起来的回答。
    var shouldFailoverToAnotherCandidate: Bool {
        switch self {
        case .rateLimited, .upstreamError, .networkTimeout: return true
        case .unauthorized, .forbidden, .requestError, .streamInterrupted: return false
        }
    }

    /// 该分类的用户可见描述（已本地化）。
    var localizedDescription: String {
        switch self {
        case .networkTimeout:
            return L10n.tr("error.upstream_failure.network_timeout")
        case .rateLimited:
            return L10n.tr("error.upstream_failure.rate_limited")
        case .unauthorized:
            return L10n.tr("error.upstream_failure.unauthorized")
        case .forbidden:
            return L10n.tr("error.upstream_failure.forbidden")
        case .requestError:
            return L10n.tr("error.upstream_failure.request_error")
        case .upstreamError:
            return L10n.tr("error.upstream_failure.upstream_error")
        case .streamInterrupted:
            return L10n.tr("error.upstream_failure.stream_interrupted")
        }
    }
}
