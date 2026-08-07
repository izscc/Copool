import Foundation

/// 一条 provider 通道在列表里的展示数据。
///
/// 视图层只认这个投影，不认注册表的三层模型——把
/// `ProviderDefinition + ProviderInstance + CredentialIdentity` 三者的拼装
/// 留在这里，视图就不必知道 baseURL 是从哪一级解析出来的。
struct ProviderChannelRow: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var definitionID: String
    /// 已解析的 baseURL 与它的来源（FR-PRV-06）。
    var baseURL: String
    var baseURLSourceKey: String
    var baseURLSourceDetail: String?
    var protocols: [APIDialect]
    var health: CredentialHealthState
    var throttled: Bool
    var failureReason: String?
    var lastVerifiedAt: Int64?
    var modelCount: Int
    var enabled: Bool
    /// 目录完全靠实时发现，没有内置模型（FR-PRV-01）。
    var catalogOnly: Bool
}

/// 把注册表三层模型摊平成"按共用凭据分组的通道列表"（CMP-01 的数据来源）。
///
/// 纯函数，无 IO：定义、实例、凭据、环境变量全部由调用方注入。视图与
/// PageModel 都不必再知道 baseURL 走的是哪一级、凭据 id 怎么命名。
enum ProviderRegistryPresenter {

    /// 一个共用凭据组的展示数据。单通道的 provider 也是一个组（只有一条通道），
    /// 这样视图只有一条渲染路径。
    struct GroupViewData: Identifiable, Equatable {
        /// 组 id：共用组名，或单个 provider 的 definition id。
        var id: String
        var title: String
        /// 组内共用的凭据 id。UI 用它调用 CredentialCoordinator。
        var credentialID: String
        var health: CredentialHealthState
        var throttled: Bool
        var failureReason: String?
        var lastVerifiedAt: Int64?
        var channels: [ProviderChannelRow]
        /// 组内通道数 > 1 才算"共用"，需要在 UI 上明示影响面。
        var isSharedCredential: Bool { channels.count > 1 }
        /// 该组支持的录入方式（取组内各 provider 的并集）。
        var credentialKinds: Set<CredentialKind>
        var credentialPrompt: String?
        var environmentVariableCandidates: [String]
        /// 复用第三方 CLI 登录态的规格。非 nil 时 UI 要给出披露入口。
        var externalSession: ExternalSessionSpec?
    }

    /// 组装全部分组。
    ///
    /// `definitions` 应当是 `ProviderRegistryResolver.resolveDefinitions` 的输出，
    /// 即已经合并过用户覆盖层的结果。
    static func groups(
        definitions: [ProviderDefinition],
        registry: ProviderRegistryV2,
        environment: [String: String],
        catalogCounts: [String: Int] = [:],
        throttledCredentialIDs: Set<String> = []
    ) -> [GroupViewData] {
        // 分组键：共用组名优先，否则 provider 自己的 id。顺序沿用
        // definitions 的顺序（种子顺序），列表才不会每次重建都跳动。
        var order: [String] = []
        var buckets: [String: [ProviderDefinition]] = [:]
        for definition in definitions {
            let key = definition.sharedCredentialGroup.flatMap { $0.isEmpty ? nil : $0 } ?? definition.id
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(definition)
        }

        return order.compactMap { key -> GroupViewData? in
            guard let members = buckets[key], let first = members.first else { return nil }
            let credentialID = credentialIdentityID(group: key, members: members, registry: registry)
            let credential = registry.credential(id: credentialID)

            let channels = members.map { definition in
                channelRow(
                    definition: definition,
                    registry: registry,
                    environment: environment,
                    credential: credential,
                    throttled: throttledCredentialIDs.contains(credentialID),
                    catalogCount: catalogCounts[definition.id]
                )
            }

            return GroupViewData(
                id: key,
                // 共用组用组名作标题（"opencode-go"），否则用 provider 显示名。
                // 组内三条通道各有自己的显示名，标题重复其中一个会误导。
                title: members.count > 1 ? groupTitle(key: key, members: members) : first.displayName,
                credentialID: credentialID,
                health: credential?.healthState ?? .unconfigured,
                throttled: throttledCredentialIDs.contains(credentialID),
                failureReason: credential?.lastFailureReason,
                lastVerifiedAt: credential?.lastVerifiedAt,
                channels: channels,
                credentialKinds: members.reduce(into: Set<CredentialKind>()) { $0.formUnion($1.credentialKinds) },
                credentialPrompt: members.compactMap(\.credentialPrompt).first,
                environmentVariableCandidates: members.flatMap(\.environmentVariables).uniqued(),
                externalSession: members.compactMap(\.externalSession).first
            )
        }
    }

    /// 组的凭据 id。与 `CredentialCoordinator.credentialIdentityID` 必须一致，
    /// 否则 UI 显示的状态和真正被写入的凭据不是同一条。
    static func credentialIdentityID(
        group key: String,
        members: [ProviderDefinition],
        registry: ProviderRegistryV2
    ) -> String {
        if members.count > 1 || members.first?.sharedCredentialGroup?.isEmpty == false {
            return "shared-\(key)"
        }
        guard let definitionID = members.first?.id,
              let instance = registry.instances.first(where: { $0.definitionID == definitionID }) else {
            // 实例还不存在（用户没配过这家）。此时没有稳定 id 可给——
            // 用 definition id 占位，实例创建后立刻会被真实 id 取代。
            return "pending-\(key)"
        }
        return instance.credentialID.isEmpty ? "cred-\(instance.id)" : instance.credentialID
    }

    private static func groupTitle(key: String, members: [ProviderDefinition]) -> String {
        // 同组成员的 ownership 一致时用它当标题（"opencode"），否则退回组键。
        let owners = Set(members.map(\.ownership)).filter { !$0.isEmpty }
        guard owners.count == 1, let owner = owners.first else { return key }
        return owner
    }

    private static func channelRow(
        definition: ProviderDefinition,
        registry: ProviderRegistryV2,
        environment: [String: String],
        credential: CredentialIdentity?,
        throttled: Bool,
        catalogCount: Int?
    ) -> ProviderChannelRow {
        let instance = registry.instances.first { $0.definitionID == definition.id }
        let resolved = ProviderRegistryResolver.resolveBaseURL(
            definition: definition,
            instanceOverride: instance?.baseURLOverride,
            environment: environment
        )
        var sourceDetail: String?
        if case .environment(let variable) = resolved.source {
            sourceDetail = variable
        }

        // 协议顺序按 APIDialect 的声明顺序过滤，而不是遍历 Set——
        // Set 顺序每次进程都可能不同，标签会无规律地换位置。
        let dialects = APIDialect.allCases.filter { definition.supportedProtocols.contains($0) }

        return ProviderChannelRow(
            id: instance?.id ?? "definition-\(definition.id)",
            displayName: definition.displayName,
            definitionID: definition.id,
            baseURL: resolved.value,
            baseURLSourceKey: resolved.source.localizedKey,
            baseURLSourceDetail: sourceDetail,
            protocols: dialects.isEmpty ? [.chat] : dialects,
            health: credential?.healthState ?? .unconfigured,
            throttled: throttled,
            failureReason: credential?.lastFailureReason,
            lastVerifiedAt: credential?.lastVerifiedAt,
            modelCount: catalogCount
                ?? instance.map { registry.catalogEntries(instanceID: $0.id).count }
                ?? 0,
            enabled: instance?.enabled ?? true,
            catalogOnly: definition.catalogOnly
        )
    }
}

extension Array where Element: Hashable {
    /// 保序去重。共用组会把多个成员声明的同名环境变量合到一起。
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
