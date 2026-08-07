import Foundation

enum L10n {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var localeOverrideIdentifier: String?
    private nonisolated(unsafe) static var cachedBundle: Bundle = rootBundle

    private static var rootBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func setLocale(identifier: String) {
        let resolved = AppLocale.resolve(identifier).identifier
        lock.lock()
        defer { lock.unlock() }
        guard localeOverrideIdentifier != resolved else {
            return
        }

        localeOverrideIdentifier = resolved
        cachedBundle = localizedBundle(for: resolved) ?? rootBundle
    }

    /// 缺键时回落到英文，**而不是把 key 原样显示出来**。
    ///
    /// 非中英的 9 份 strings 天然落后于 zh-Hans/en：新功能先写这两份，其余
    /// 随后补齐。没有这层回落，落后期间用户看到的是
    /// `credentials.health.ready` 这样的字面量——那看起来像 bug，
    /// 而一句英文只是"还没翻译"。
    static func tr(_ key: String) -> String {
        // 哨兵值不可能与真实译文相同，用它区分"查到了"与"缺键"。
        let sentinel = "\u{0}copool.missing"
        let value = currentBundle().localizedString(forKey: key, value: sentinel, table: nil)
        if value != sentinel {
            return value
        }
        guard let fallback = fallbackBundle else { return key }
        return fallback.localizedString(forKey: key, value: key, table: nil)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    private static func currentBundle() -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        return cachedBundle
    }

    /// en.lproj 是覆盖最全的一份（与 zh-Hans 同步维护），用作缺键回落。
    /// 一次解析后常驻，`tr` 是热路径。
    private static let fallbackBundle: Bundle? = localizedBundle(for: "en")

    private static func localizedBundle(for identifier: String) -> Bundle? {
        guard let path = rootBundle.path(forResource: identifier, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
