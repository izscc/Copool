import Foundation

/// 目录策展的纯函数集合（FR-CAT-07 / FR-CAT-08 / FR-CAT-09）。
///
/// 全部是值进值出，不碰仓储：策展要在写盘之前先能被校验和撤销。别名冲突
/// 尤其如此——冲突必须在用户点保存**之前**就能报出来，落盘之后再发现，
/// 用户已经不记得刚才改了哪一条了。
enum CatalogCuration {

    // MARK: - 别名冲突（FR-CAT-07）

    /// 一次别名冲突。`alias` 是规范化后的形式，`entryIDs` 是所有争用它的条目。
    struct AliasConflict: Equatable, Sendable, Identifiable {
        var alias: String
        var entryIDs: [String]

        var id: String { alias }
    }

    /// 别名校验结果。分成三种而不是一个布尔，是因为三种情况给用户的提示
    /// 完全不同：空的要说"不能为空"，撞后端 id 的要说"这会遮住一个真实
    /// 模型"，撞别名的要说"已被谁占用"。
    enum AliasValidation: Equatable, Sendable {
        case ok
        case empty
        /// 与某个真实后端模型 id 相同。放行的话，路由到这个名字时到底该去
        /// 哪个模型就没有答案了。
        case shadowsBackendModel(String)
        /// 已被另一个条目用作别名。
        case duplicate(entryID: String)
    }

    /// 别名的规范化形式。大小写与首尾空白不该构成两个不同的别名——用户以为
    /// 自己在改一个，实际上留下了两个。
    static func normalizeAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 找出整份目录里被多个条目争用的别名。
    ///
    /// 跨实例检查而不是只在实例内：别名是路由可以直接命中的名字，两家
    /// provider 用同一个别名，请求该去哪家就成了掷骰子。
    static func aliasConflicts(in catalog: [ModelCatalogEntry]) -> [AliasConflict] {
        var owners: [String: [String]] = [:]
        for entry in catalog {
            for alias in entry.aliases {
                let key = normalizeAlias(alias)
                guard !key.isEmpty else { continue }
                if owners[key]?.contains(entry.id) == true { continue }
                owners[key, default: []].append(entry.id)
            }
        }
        return owners
            .filter { $0.value.count > 1 }
            .map { AliasConflict(alias: $0.key, entryIDs: $0.value.sorted()) }
            .sorted { $0.alias < $1.alias }
    }

    /// 校验一个待写入的别名。`entryID` 是正在编辑的条目，它自己的别名不算冲突。
    static func validateAlias(
        _ alias: String,
        for entryID: String,
        in catalog: [ModelCatalogEntry]
    ) -> AliasValidation {
        let key = normalizeAlias(alias)
        guard !key.isEmpty else { return .empty }

        for entry in catalog {
            if entry.id != entryID, normalizeAlias(entry.backendModelID) == key {
                return .shadowsBackendModel(entry.backendModelID)
            }
            guard entry.id != entryID else { continue }
            if entry.aliases.contains(where: { normalizeAlias($0) == key }) {
                return .duplicate(entryID: entry.id)
            }
        }
        return .ok
    }

    // MARK: - 可见性（FR-CAT-09）

    /// 改一条的可见性。找不到条目时原样返回——策展面板和仓储之间总有时间差，
    /// 为一次过期的点击抛错只会变成一个用户无法处理的弹窗。
    static func setVisibility(
        _ visibility: ModelVisibility,
        entryID: String,
        in catalog: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry] {
        bulkSetVisibility(visibility, entryIDs: [entryID], in: catalog)
    }

    /// 批量改可见性。批量存在的理由很实际：一个 OpenAI 兼容网关能列出两百个
    /// 模型，逐条点击去隐藏是不可接受的（SCR-PRV-02）。
    static func bulkSetVisibility(
        _ visibility: ModelVisibility,
        entryIDs: Set<String>,
        in catalog: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry] {
        guard !entryIDs.isEmpty else { return catalog }
        var result = catalog
        for index in result.indices where entryIDs.contains(result[index].id) {
            result[index].visibility = visibility
        }
        return result
    }

    /// 反转可见性：可见 → 隐藏，隐藏 → 可见。`.curated` 视作可见。
    static func toggleVisibility(
        entryID: String,
        in catalog: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry] {
        guard let entry = catalog.first(where: { $0.id == entryID }) else { return catalog }
        return setVisibility(entry.visibility == .hidden ? .visible : .hidden, entryID: entryID, in: catalog)
    }

    // MARK: - 重命名与别名

    /// 改显示名。显示名**不是**路由身份，改它不影响任何已有路由（FR-CAT-07）。
    /// 传空字符串等于清除自定义名，回到后端 id。
    static func rename(
        entryID: String,
        to displayName: String,
        in catalog: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry] {
        var result = catalog
        guard let index = result.firstIndex(where: { $0.id == entryID }) else { return catalog }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        result[index].displayName = trimmed.isEmpty ? nil : trimmed
        return result
    }

    /// 覆盖某条目的别名列表。去重与规范化在这里做，调用方不必先洗一遍。
    ///
    /// 返回 nil 表示存在冲突，一条都不写。部分成功是最糟的结果：用户看到
    /// 一个"保存成功"，实际上有一半别名被悄悄丢掉了。
    static func setAliases(
        _ aliases: [String],
        entryID: String,
        in catalog: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry]? {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for alias in aliases {
            let key = normalizeAlias(alias)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            guard validateAlias(alias, for: entryID, in: catalog) == .ok else { return nil }
            seen.insert(key)
            cleaned.append(key)
        }
        var result = catalog
        guard let index = result.firstIndex(where: { $0.id == entryID }) else { return catalog }
        result[index].aliases = cleaned
        return result
    }

    // MARK: - 搜索（FR-CAT-08）

    /// 同时匹配显示名与后端 ID，两者都要能搜到。
    ///
    /// 用户记得住的往往只有其中一个：他在别处看到的是 `gpt-4o-mini`，在这里
    /// 显示的却是「GPT-4o mini」。只支持一种就等于让另一半用户搜不到东西。
    static func search(entries: [ModelCatalogEntry], query: String) -> [ModelCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.matches(query: trimmed) }
    }

    /// 排序：精确命中后端 id 的排最前，其余按显示名。
    ///
    /// 搜 `gpt-4o` 时 `gpt-4o` 本身应该在 `gpt-4o-mini-audio-preview` 前面，
    /// 否则用户得在一串更长的名字里找那个最短的。
    static func rank(entries: [ModelCatalogEntry], query: String) -> [ModelCatalogEntry] {
        let needle = normalizeAlias(query)
        guard !needle.isEmpty else {
            return entries.sorted { $0.effectiveDisplayName < $1.effectiveDisplayName }
        }
        func score(_ entry: ModelCatalogEntry) -> Int {
            let backend = entry.backendModelID.lowercased()
            if backend == needle { return 0 }
            if entry.effectiveDisplayName.lowercased() == needle { return 1 }
            if backend.hasPrefix(needle) { return 2 }
            if entry.effectiveDisplayName.lowercased().hasPrefix(needle) { return 3 }
            return 4
        }
        return entries.sorted {
            let left = score($0)
            let right = score($1)
            if left != right { return left < right }
            return $0.effectiveDisplayName < $1.effectiveDisplayName
        }
    }
}
