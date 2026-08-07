import Foundation

/// 一条"用户已被告知并明确同意"的记录（FR-IDT-06 / SEC-08）。
///
/// 复用第三方本机登录态（Claude / Grok / Cursor / Kimi / Antigravity）之前
/// 必须先落一条这个，且**记录本身不含任何凭据内容**——它记的是"同意了
/// 什么"，不是"读到了什么"。
struct ConsentRecord: Codable, Equatable, Sendable, Identifiable {
    /// 同意的动作类型。分开而不是用一个自由字符串，是为了让"撤回某一类
    /// 同意"成为可判定的操作。
    enum Action: String, Codable, Equatable, Sendable, CaseIterable {
        /// 读取第三方 CLI 的本机登录态。
        case reuseExternalSession
        /// 导入第三方订阅凭据。
        case importSubscription
        /// 对真实计费端点发起冒烟测试。
        case paidSmokeTest
        /// 写入目标应用的配置文件。
        case writeTargetConfig
    }

    var id: String
    var action: Action
    /// 同意涉及的对象：provider definition id、CLI 名、目标 id。
    var subject: String
    /// 展示给用户的披露原文。存原文而不是存 key——文案改了之后，
    /// 旧记录仍要能回答"当时用户看到的是什么"。
    var disclosure: String
    var grantedAt: Int64
    /// 撤回时间。撤回不删除记录，只加时间戳。
    var revokedAt: Int64?

    var isActive: Bool { revokedAt == nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case subject
        case disclosure
        case grantedAt
        case revokedAt
    }

    init(
        id: String,
        action: Action,
        subject: String,
        disclosure: String,
        grantedAt: Int64,
        revokedAt: Int64? = nil
    ) {
        self.id = id
        self.action = action
        self.subject = subject
        self.disclosure = disclosure
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(Action.self, forKey: .action)
        subject = try container.decode(String.self, forKey: .subject)
        disclosure = try container.decodeIfPresent(String.self, forKey: .disclosure) ?? ""
        grantedAt = try container.decodeIfPresent(Int64.self, forKey: .grantedAt) ?? 0
        revokedAt = try container.decodeIfPresent(Int64.self, forKey: .revokedAt)
    }
}
