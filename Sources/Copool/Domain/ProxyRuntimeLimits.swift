import Foundation

/// 代理运行时的硬性限制，防止无界缓冲耗尽内存、以及压缩炸弹攻击（SEC-11，FR-PRO-04）。
enum ProxyRuntimeLimits {
    /// 入站请求体编码前大小（压缩状态下的字节数）。
    ///
    /// 第一道限制：在解压之前就拒绝过大的载荷，防止攻击者用
    /// 几 MB 的 Brotli 炸弹展开成几十 GB 内存。
    static let maxInboundRequestEncodedBytes = 64 * 1024 * 1024

    /// 入站请求体解码后大小（解压后的实际内容字节数）。
    ///
    /// 第二道限制：即使编码体通过第一道，解码后的内容也不能
    /// 无限膨胀。两道限制缺一不可（SEC-11）。
    static let maxInboundRequestDecodedBytes = 256 * 1024 * 1024

    /// 上行响应体编码前大小（来自 provider 的压缩字节流）。
    static let maxUpstreamResponseEncodedBytes = 64 * 1024 * 1024

    /// 上行响应体解码后大小（SSE 事件累积后的总字节数）。
    static let maxUpstreamResponseDecodedBytes = 256 * 1024 * 1024

    static func limitDescription(for bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// 413 错误的具体原因，指明是哪一道限制触发（FR-PRO-04）。
    enum OversizeKind: Sendable {
        case requestEncoded
        case requestDecoded
        case responseEncoded
        case responseDecoded

        var localizedDescription: String {
            switch self {
            case .requestEncoded:
                return L10n.tr("error.proxy_runtime.request_encoded_too_large")
            case .requestDecoded:
                return L10n.tr("error.proxy_runtime.request_decoded_too_large")
            case .responseEncoded:
                return L10n.tr("error.proxy_runtime.response_encoded_too_large")
            case .responseDecoded:
                return L10n.tr("error.proxy_runtime.response_decoded_too_large")
            }
        }
    }
}
