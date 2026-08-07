import Foundation

/// 目录变更检测（FR-CAT-11）。
///
/// 为每个绑定记录它应用的目录指纹；目录变更后指纹不匹配时显示「配置已过期」，
/// 提示用户重新同步。粒度：只取该绑定启用的 provider 实例的条目，变更其他
/// provider 不会让无关绑定显示过期——避免告警疲劳。
enum CatalogFingerprint {
    /// 为一个绑定计算目录指纹。只取该绑定 `enabledProviderInstanceIDs`
    /// 里列出的实例的条目；每个条目取决定路由身份的字段：
    /// `backendModelID`（主键）、`visibility`（决定是否出现在选择器）、
    /// `upstreamAvailable`（决定是否可用）、`aliases`（备选路由键）、
    /// `displayName`（影响别名与显示名是否冲突）。
    ///
    /// 不取能力字段（上下文窗口、推理档位）：它们的变更不影响路由正确性，
    /// 不应触发「配置已过期」——用户关心的是"这个名字还能不能用"，
    /// 而不是"这个模型窗口涨了一万"。
    static func compute(
        registry: ProviderRegistryV2,
        enabledInstanceIDs: [String]
    ) -> String {
        let set = Set(enabledInstanceIDs)
        let relevant = registry.catalog
            .filter { set.contains($0.providerInstanceID) }
            .sorted { $0.id < $1.id }

        var lines: [String] = []
        for entry in relevant {
            let aliasesLine = entry.aliases.isEmpty
                ? ""
                : " aliases=\(entry.aliases.sorted().joined(separator: ","))"
            let displayLine = entry.displayName.map { " display=\($0)" } ?? ""
            lines.append(
                "\(entry.id) vis=\(entry.visibility.rawValue) avail=\(entry.upstreamAvailable)\(aliasesLine)\(displayLine)"
            )
        }

        return Self.hash(lines.joined(separator: "\n"))
    }

    private static func hash(_ text: String) -> String {
        ContentFingerprint.of(text)
    }
}

/// FNV-1a（64 位）内容指纹。
///
/// 提到 Domain 是因为三处都要用同一个算法：目录指纹、配置指纹、
/// 以及 Infrastructure 里的 `CodexTargetAdapter.fingerprint(of:)`。
/// 各写一份迟早会漂移，而漂移的后果是"配置明明没变却报过期"。
enum ContentFingerprint {
    static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
