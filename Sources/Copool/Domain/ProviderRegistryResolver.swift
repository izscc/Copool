import Foundation

/// 把"内置种子 + 用户覆盖层 + 进程环境"解析成一份可直接展示与请求的
/// provider 视图（FR-PRV-03、FR-PRV-06）。
///
/// 纯函数，无 IO：环境变量由调用方以字典形式注入。这样单测不必污染
/// 进程环境，也不会因为测试并行跑而互相干扰。
enum ProviderRegistryResolver {

    // MARK: - 覆盖层合并

    /// 字段级覆盖：`userDefinitions[id]` 里**被用户显式改过**的字段生效，
    /// 其余回落内置值。
    ///
    /// 为什么不整条替换：种子会随版本升级带来新字段与更正后的默认值
    /// （比如某家换了域名）。整条替换会把用户几个月前的快照永久钉死，
    /// 用户只改过一个显示名，却再也拿不到新的 defaultBaseURL。
    ///
    /// "显式改过"的判定标准是**与内置值不同**。这有一个已知的取舍：用户
    /// 把某字段手动改回和内置值一样，就等于放弃了覆盖。这是可接受的——
    /// 结果值完全相同，用户观察不到差异，除非内置值日后再变（那时采用新值
    /// 恰恰是本条要的行为）。
    static func merge(
        builtIn: ProviderDefinition,
        override: ProviderDefinition?
    ) -> ProviderDefinition {
        guard let override else { return builtIn }

        var merged = builtIn
        // id 永不参与合并——它是身份，不是内容（AC-005）。
        if override.displayName != builtIn.displayName, !override.displayName.isEmpty {
            merged.displayName = override.displayName
        }
        if override.defaultBaseURL != builtIn.defaultBaseURL, !override.defaultBaseURL.isEmpty {
            merged.defaultBaseURL = override.defaultBaseURL
        }
        if override.supportedProtocols != builtIn.supportedProtocols, !override.supportedProtocols.isEmpty {
            merged.supportedProtocols = override.supportedProtocols
        }
        if override.credentialKinds != builtIn.credentialKinds, !override.credentialKinds.isEmpty {
            merged.credentialKinds = override.credentialKinds
        }
        if override.baseURLEnvironmentVariable != builtIn.baseURLEnvironmentVariable,
           override.baseURLEnvironmentVariable?.isEmpty == false {
            merged.baseURLEnvironmentVariable = override.baseURLEnvironmentVariable
        }
        if override.environmentVariables != builtIn.environmentVariables, !override.environmentVariables.isEmpty {
            merged.environmentVariables = override.environmentVariables
        }
        if override.rateLimitHeaderPrefix != builtIn.rateLimitHeaderPrefix,
           !override.rateLimitHeaderPrefix.isEmpty {
            merged.rateLimitHeaderPrefix = override.rateLimitHeaderPrefix
        }
        if override.notes != builtIn.notes, override.notes?.isEmpty == false {
            merged.notes = override.notes
        }
        // isBuiltIn 不可被覆盖：它描述"这条定义打哪儿来"，不是用户偏好。
        // catalogOnly / sharedCredentialGroup / externalSession 同理——
        // 它们是 provider 的固有性质，用户改这些只会让行为无法解释。
        return merged
    }

    /// 解析出全部可见的 provider 定义：内置（应用覆盖层）+ 纯用户自定义。
    ///
    /// 顺序稳定：内置按种子顺序，自定义按注册表顺序。UI 依赖顺序稳定，
    /// 否则每次重建列表都会跳动。
    static func resolveDefinitions(
        builtIn: [ProviderDefinition],
        userDefinitions: [ProviderDefinition]
    ) -> [ProviderDefinition] {
        let overridesByID = Dictionary(userDefinitions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let builtInIDs = Set(builtIn.map(\.id))

        var resolved = builtIn.map { merge(builtIn: $0, override: overridesByID[$0.id]) }
        // 覆盖层里 id 不在内置清单中的，是用户自定义 provider（FR-PRV-04）。
        resolved.append(contentsOf: userDefinitions.filter { !builtInIDs.contains($0.id) })
        return resolved
    }

    /// 用户是否覆盖过这家（UI 要显示"已修改"标记与"恢复默认"）。
    static func isOverridden(
        builtIn: [ProviderDefinition],
        userDefinitions: [ProviderDefinition],
        id: String
    ) -> Bool {
        guard let base = builtIn.first(where: { $0.id == id }),
              let override = userDefinitions.first(where: { $0.id == id }) else {
            return false
        }
        return merge(builtIn: base, override: override) != base
    }

    // MARK: - baseURL 三级优先级（FR-PRV-06）

    /// 当前 baseURL 取值来自哪一级。UI 必须显示它，否则用户改了环境变量
    /// 却看到内置默认值，会以为改动没生效。
    enum BaseURLSource: Equatable, Sendable {
        /// 用户在实例上显式覆盖。
        case userOverride
        /// 来自环境变量，附带变量名——只有名字，永远不含值。
        case environment(variable: String)
        /// 种子里的内置默认值。
        case builtInDefault
        /// 三级都为空。外部 CLI 会话类 provider（kimi-oauth / grok-oauth）
        /// 的端点由登录态决定，这里为空是正常的。
        case unset

        var localizedKey: String {
            switch self {
            case .userOverride: return "providers.baseurl.source.override"
            case .environment: return "providers.baseurl.source.environment"
            case .builtInDefault: return "providers.baseurl.source.builtin"
            case .unset: return "providers.baseurl.source.unset"
            }
        }
    }

    struct ResolvedBaseURL: Equatable, Sendable {
        var value: String
        var source: BaseURLSource

        var isEmpty: Bool { value.isEmpty }
    }

    /// 用户覆盖 > 环境变量 `baseUrlEnv` > 内置 `defaultBaseURL`。
    ///
    /// 典型场景：`qwen-plan` 种子里是新加坡端点，国内用户设一个
    /// `QWEN_PLAN_BASE_URL` 就能切北京，不必改配置文件。
    static func resolveBaseURL(
        definition: ProviderDefinition,
        instanceOverride: String?,
        environment: [String: String]
    ) -> ResolvedBaseURL {
        if let override = instanceOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return ResolvedBaseURL(value: override, source: .userOverride)
        }
        if let variable = definition.baseURLEnvironmentVariable,
           !variable.isEmpty,
           let fromEnvironment = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnvironment.isEmpty {
            return ResolvedBaseURL(value: fromEnvironment, source: .environment(variable: variable))
        }
        let builtIn = definition.defaultBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !builtIn.isEmpty else {
            return ResolvedBaseURL(value: "", source: .unset)
        }
        return ResolvedBaseURL(value: builtIn, source: .builtInDefault)
    }

    // MARK: - 环境变量凭据探测（FR-IDT-03）

    /// 按种子声明的顺序找第一个**已设置且非空**的候选变量。
    ///
    /// 只返回**变量名**，绝不返回值——值在发请求那一刻才读，读完即弃。
    /// 返回值一旦进了这个函数的返回类型，就迟早会被谁打进日志。
    static func detectCredentialEnvironmentVariable(
        definition: ProviderDefinition,
        environment: [String: String]
    ) -> String? {
        definition.environmentVariables.first { name in
            guard let value = environment[name] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - 共用凭据组（FR-PRV-02）

    /// 与给定 provider 共用同一把凭据的所有 provider id（含自己）。
    ///
    /// opencode Go 是一份订阅、三条协议通道，用户填一次 Key 三个都该就绪。
    /// UI 得据此显示"该 Key 被 3 个通道共用"，删除时也要照实警告影响面——
    /// 用户以为在删一个，实际断掉三个。
    static func sharedCredentialPeers(
        definitions: [ProviderDefinition],
        id: String
    ) -> [String] {
        guard let target = definitions.first(where: { $0.id == id }),
              let group = target.sharedCredentialGroup,
              !group.isEmpty else {
            return [id]
        }
        return definitions
            .filter { $0.sharedCredentialGroup == group }
            .map(\.id)
    }

    /// 按共用组归并：返回 [组名或 provider id: 该组的 provider 列表]。
    /// 不属于任何组的 provider 自成一组，键就是它自己的 id。
    static func groupBySharedCredential(
        definitions: [ProviderDefinition]
    ) -> [String: [ProviderDefinition]] {
        Dictionary(grouping: definitions) { definition in
            definition.sharedCredentialGroup.flatMap { $0.isEmpty ? nil : $0 } ?? definition.id
        }
    }
}
