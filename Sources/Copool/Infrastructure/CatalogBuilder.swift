import Foundation

/// 目录的三个来源在这里汇合：种子、实时发现、用户策展（FR-CAT-01…04）。
///
/// 可见性规则（AC-011）：
///   - 凭据解析不出来的实例不进默认目录。列出一个填了就报 401 的模型，
///     比不列出它更糟——用户会以为是模型坏了而不是自己没配 key。
///   - 元数据带着出处走（provider > registry > fallback），UI 才能把估算值
///     和上游确认过的值区分开（FR-CAT-06）。
///   - 用户隐藏过的、上游已下架的都不进默认目录，但都留在管理视图里，
///     因为"隐藏"必须可逆，"下架"必须可见（FR-CAT-04）。
struct CatalogBuilder: Sendable {
    /// One catalog row ready for pickers, with provenance.
    struct CatalogRow: Equatable, Sendable, Identifiable {
        var entry: ModelCatalogEntry
        var instance: ProviderInstance
        var credentialResolved: Bool
        var metadataSource: MetadataSource

        var id: String { entry.id }

        var isHidden: Bool { entry.visibility == .hidden }
        var isDelisted: Bool { !entry.upstreamAvailable }
    }

    /// 管理视图（SCR-PRV-02）的一个 provider 分组。
    ///
    /// 未配置的 provider 也要出现在这里：用户需要在配置**之前**就看到这家能
    /// 给他什么模型，否则"要不要填这个 key"是个没有依据的决定。
    struct ManagementGroup: Equatable, Sendable, Identifiable {
        var definitionID: String
        var displayName: String
        /// nil 表示这家还没有实例——即"缺少凭据"分组里的成员。
        var instance: ProviderInstance?
        var credentialResolved: Bool
        /// 已入库的条目（含隐藏与下架，由调用方决定显不显示）。
        var rows: [CatalogRow]
        /// 尚未入库、仅来自种子的预览条目。只在未配置时非空。
        var pendingEntries: [ModelCatalogEntry]
        /// 被搜索或可见性过滤掉的条目数。
        var filteredCount: Int
        var refreshState: CatalogRefreshState?

        var id: String { instance?.id ?? "definition:\(definitionID)" }

        /// 归入"缺少凭据"分组的条件。没有实例，或有实例但凭据解析不出来，
        /// 对用户来说是同一件事：这家现在用不了。
        var needsCredential: Bool { instance == nil || !credentialResolved }

        var modelCount: Int { rows.isEmpty ? pendingEntries.count : rows.count }
    }

    /// 一次实时发现合并后的结果。计数是为了让 UI 能回答"刷新到底做了什么"——
    /// 一个只会转圈然后什么都不说的按钮，用户第二次就不会再点了。
    struct DiscoveryMergeResult: Equatable, Sendable {
        var registry: ProviderRegistryV2
        var addedCount: Int
        var updatedCount: Int
        var delistedCount: Int
        var relistedCount: Int
    }

    // MARK: - 默认目录

    /// Builds the default (pickable) catalog: only entries whose instance has
    /// a credential. Returns rows plus the count of hidden entries (missing
    /// credentials / disabled instances / hidden / de-listed) so callers can
    /// surface "N hidden".
    func buildDefaultCatalog(
        registry: ProviderRegistryV2,
        credentialResolved: (String) -> Bool
    ) -> (rows: [CatalogRow], hiddenCount: Int) {
        var rows: [CatalogRow] = []
        var hidden = 0
        // 目录可能有几百条而凭据只有十几个，而 credentialResolved 背后往往是
        // 一次 Keychain 查询。不缓存的话打开一次页面就是几百次钥匙串访问。
        var resolutionCache: [String: Bool] = [:]

        for entry in registry.catalog {
            guard let instance = registry.instance(id: entry.providerInstanceID) else {
                hidden += 1
                continue
            }
            guard instance.enabled else {
                hidden += 1
                continue
            }
            // 用户显式隐藏的条目不进选择器（FR-CAT-01 条件三）。`.curated`
            // 是"用户挑出来的"，属于可见的一种，不在此列。
            guard entry.visibility != .hidden else {
                hidden += 1
                continue
            }
            // 上游已下架：留档但不可选。仍然出现在管理视图里带下架标记。
            guard entry.upstreamAvailable else {
                hidden += 1
                continue
            }
            let key = instance.credentialID
            let resolved: Bool
            if let cached = resolutionCache[key] {
                resolved = cached
            } else {
                resolved = credentialResolved(key)
                resolutionCache[key] = resolved
            }
            guard resolved else {
                hidden += 1
                continue
            }
            rows.append(
                CatalogRow(
                    entry: entry,
                    instance: instance,
                    credentialResolved: true,
                    metadataSource: entry.contextWindowSource
                )
            )
        }
        return (rows, hidden)
    }

    // MARK: - 管理视图

    /// 组装 SCR-PRV-02 的分组列表。
    ///
    /// `seedEntriesByDefinition` 提供未配置 provider 的预览条目；已配置的
    /// provider 一律以注册表为准，因为那份已经过发现与策展，种子只是初值。
    func buildManagementCatalog(
        registry: ProviderRegistryV2,
        definitions: [ProviderDefinition],
        seedEntriesByDefinition: [String: [ModelCatalogEntry]],
        credentialResolved: (String) -> Bool,
        query: String = "",
        includeHidden: Bool = true
    ) -> [ManagementGroup] {
        var resolutionCache: [String: Bool] = [:]
        func resolve(_ credentialID: String) -> Bool {
            if let cached = resolutionCache[credentialID] { return cached }
            let value = credentialResolved(credentialID)
            resolutionCache[credentialID] = value
            return value
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        var groups: [ManagementGroup] = []

        for definition in definitions {
            let instances = registry.instances.filter { $0.definitionID == definition.id }
            if instances.isEmpty {
                let seedEntries = seedEntriesByDefinition[definition.id] ?? []
                let matched = seedEntries.filter { $0.matches(query: trimmedQuery) }
                // 搜索时空分组只是噪声；不搜索时空分组是有意义的（这家没有
                // 已知模型），所以只在搜索态下丢弃。
                if matched.isEmpty && !trimmedQuery.isEmpty { continue }
                groups.append(
                    ManagementGroup(
                        definitionID: definition.id,
                        displayName: definition.displayName,
                        instance: nil,
                        credentialResolved: false,
                        rows: [],
                        pendingEntries: matched.sorted { $0.effectiveDisplayName < $1.effectiveDisplayName },
                        filteredCount: seedEntries.count - matched.count,
                        refreshState: nil
                    )
                )
                continue
            }

            for instance in instances {
                let resolved = resolve(instance.credentialID)
                let entries = registry.catalogEntries(instanceID: instance.id)
                var rows: [CatalogRow] = []
                var filtered = 0
                for entry in entries {
                    if !includeHidden && entry.visibility == .hidden {
                        filtered += 1
                        continue
                    }
                    guard entry.matches(query: trimmedQuery) else {
                        filtered += 1
                        continue
                    }
                    rows.append(
                        CatalogRow(
                            entry: entry,
                            instance: instance,
                            credentialResolved: resolved,
                            metadataSource: entry.contextWindowSource
                        )
                    )
                }
                // 已配置但目录还是空的（凭据刚填、还没刷新过）时退回种子预览，
                // 否则用户会看到一个空分组并以为配置失败了。
                var pending: [ModelCatalogEntry] = []
                if entries.isEmpty {
                    pending = (seedEntriesByDefinition[definition.id] ?? [])
                        .filter { $0.matches(query: trimmedQuery) }
                        .sorted { $0.effectiveDisplayName < $1.effectiveDisplayName }
                }
                if rows.isEmpty && pending.isEmpty && !trimmedQuery.isEmpty { continue }
                rows.sort { $0.entry.effectiveDisplayName < $1.entry.effectiveDisplayName }
                groups.append(
                    ManagementGroup(
                        definitionID: definition.id,
                        displayName: instance.displayName.isEmpty ? definition.displayName : instance.displayName,
                        instance: instance,
                        credentialResolved: resolved,
                        rows: rows,
                        pendingEntries: pending,
                        filteredCount: filtered,
                        refreshState: registry.catalogRefreshStates[instance.id]
                    )
                )
            }
        }

        // 缺少凭据的沉底：可用的东西排在前面，需要动手的排在后面且集中成一
        // 段，用户能一眼数清"还差几家"。同段内保持定义顺序，不按名字重排——
        // 位置每次都变的列表没法形成肌肉记忆。
        let ready = groups.filter { !$0.needsCredential }
        let blocked = groups.filter { $0.needsCredential }
        return ready + blocked
    }

    // MARK: - 种子具化

    /// 把某个 definition 的种子条目绑定到一个实例上，跳过已存在的。
    ///
    /// 幂等：重复调用不会产生重复条目，也不会覆盖用户改过的显示名与可见性。
    /// 这一点很重要——种子升级会再次调用它，而用户的策展必须活下来（MIG-03）。
    func materializeSeedCatalog(
        registry: ProviderRegistryV2,
        instanceID: String,
        seedEntries: [ModelCatalogEntry]
    ) -> ProviderRegistryV2 {
        var result = registry
        let existing = Set(
            result.catalog
                .filter { $0.providerInstanceID == instanceID }
                .map(\.backendModelID)
        )
        for seed in seedEntries where !existing.contains(seed.backendModelID) {
            var entry = seed
            entry.providerInstanceID = instanceID
            entry.origin = .seed
            result.catalog.append(entry)
        }
        return result
    }

    // MARK: - 实时发现合并

    /// Merges live-discovered model ids into an instance's catalog entries.
    ///
    /// 兼容旧调用点的薄封装，语义见 `applyDiscovery`。
    func mergeLiveDiscovery(
        registry: ProviderRegistryV2,
        instanceID: String,
        liveModelIDs: [String],
        liveCapabilities: [String: ModelCapabilitiesV2]
    ) -> ProviderRegistryV2 {
        applyDiscovery(
            registry: registry,
            instanceID: instanceID,
            liveModelIDs: liveModelIDs,
            liveCapabilities: liveCapabilities
        ).registry
    }

    /// 合并一次成功的 `/models` 结果（FR-CAT-03）。
    ///
    /// **优先级是反直觉的：种子的元数据字段赢过实时发现。** 因为绝大多数
    /// provider 的 `/models` 只返回 id 和 owned_by，拿它去覆盖种子里人工核对
    /// 过的上下文窗口，等于用空值换掉正确值。实时发现的真正价值在另外两件事
    /// 上：补上种子没有的新模型，以及填种子留空的字段。
    ///
    /// 用户策展的部分（显示名、别名、可见性）在这里一概不碰。
    func applyDiscovery(
        registry: ProviderRegistryV2,
        instanceID: String,
        liveModelIDs: [String],
        liveCapabilities: [String: ModelCapabilitiesV2]
    ) -> DiscoveryMergeResult {
        var result = registry
        var added = 0
        var updated = 0
        var delisted = 0
        var relisted = 0

        let liveSet = Set(liveModelIDs)
        let existing = Set(
            result.catalog
                .filter { $0.providerInstanceID == instanceID }
                .map(\.backendModelID)
        )

        // 1) 新模型入库。这是实时发现不可替代的价值：种子是构建期快照，
        //    上游今天发的模型只有这条路径能进来。
        for modelID in liveModelIDs where !existing.contains(modelID) {
            let capabilities = liveCapabilities[modelID] ?? ModelCapabilitiesV2()
            var sources: [String: MetadataSource] = [:]
            if capabilities.contextWindow != nil { sources["contextWindow"] = .provider }
            if capabilities.supportedReasoningEfforts != nil { sources["reasoningEfforts"] = .provider }
            result.catalog.append(
                ModelCatalogEntry(
                    providerInstanceID: instanceID,
                    backendModelID: modelID,
                    // 不塞 displayName：塞成 id 会让"没有友好名"和"友好名恰好
                    // 等于 id"变得无法区分，之后种子补名字时就不知道能不能覆盖。
                    displayName: nil,
                    capabilities: capabilities,
                    metadataSources: sources,
                    visibility: .visible,
                    origin: .discovered,
                    upstreamAvailable: true
                )
            )
            added += 1
        }

        // 2) 已有条目：补空缺，按 origin 决定能不能覆盖已有值。
        for index in result.catalog.indices
        where result.catalog[index].providerInstanceID == instanceID {
            var entry = result.catalog[index]
            var changed = false

            if let live = liveCapabilities[entry.backendModelID] {
                // `.discovered` 的既有值本来就来自上一次发现，理应被新一次刷新
                // 更新；`.seed` 与 `.userAdded` 的值另有出处，只填空不覆盖。
                let mayOverwrite = entry.origin == .discovered

                if let liveWindow = live.contextWindow,
                   entry.capabilities.contextWindow == nil || mayOverwrite {
                    if entry.capabilities.contextWindow != liveWindow {
                        entry.capabilities.contextWindow = liveWindow
                        changed = true
                    }
                    entry.metadataSources["contextWindow"] = .provider
                }

                // FR-CAT-05：`nil`（未知）可以被真实发现结果填上，`[]`（上游
                // 明确表示没有档位）绝不能被任何东西覆盖回去。
                if let liveEfforts = live.supportedReasoningEfforts,
                   entry.capabilities.supportedReasoningEfforts == nil || mayOverwrite {
                    if entry.capabilities.supportedReasoningEfforts != liveEfforts {
                        entry.capabilities.supportedReasoningEfforts = liveEfforts
                        changed = true
                    }
                    entry.metadataSources["reasoningEfforts"] = .provider
                }

                if entry.capabilities.defaultReasoningEffort == nil,
                   let liveDefault = live.defaultReasoningEffort {
                    entry.capabilities.defaultReasoningEffort = liveDefault
                    changed = true
                }
                if entry.capabilities.supportsVision == nil, let vision = live.supportsVision {
                    entry.capabilities.supportsVision = vision
                    changed = true
                }
            }

            // 3) 上下架标记。只对 `.discovered` 生效：那些条目本就是从列表里
            //    来的，它们从列表里消失是有意义的信号。种子条目不同——不少
            //    provider 的 `/models` 只返回账号已开通的子集，拿它去下架一个
            //    其实能用的种子模型，代价远大于留着一条过期记录（FR-CAT-04）。
            //    另外整份列表为空时一律不下架：那更像是上游抽风而不是清空。
            if !liveSet.isEmpty, entry.origin == .discovered {
                let available = liveSet.contains(entry.backendModelID)
                if entry.upstreamAvailable != available {
                    entry.upstreamAvailable = available
                    changed = true
                    if available { relisted += 1 } else { delisted += 1 }
                }
            } else if liveSet.contains(entry.backendModelID), !entry.upstreamAvailable {
                // 种子条目曾被标下架又重新出现在列表里，恢复它。
                entry.upstreamAvailable = true
                changed = true
                relisted += 1
            }

            if changed {
                result.catalog[index] = entry
                updated += 1
            }
        }

        return DiscoveryMergeResult(
            registry: result,
            addedCount: added,
            updatedCount: updated,
            delistedCount: delisted,
            relistedCount: relisted
        )
    }
}
