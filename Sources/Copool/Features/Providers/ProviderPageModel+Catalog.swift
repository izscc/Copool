import Foundation

/// M2 模型目录的页面动作（FR-CAT-*、SCR-PRV-02）。
///
/// 与 `+Registry.swift` 分开：那边管的是"这家能不能用"，这边管的是"这家能
/// 用哪些模型"。两者的刷新时机不同——凭据一改就要重算健康，目录只在用户
/// 主动刷新或切到目录页时重建。
@MainActor
extension ProviderPageModel {

    // MARK: - 重建

    /// 重建管理视图的分组（SCR-PRV-02）。
    ///
    /// 与 `loadCatalog()` 的区别是它**包含**隐藏和缺凭据的条目：默认目录回答
    /// "现在能选什么"，管理视图回答"我都有什么、要不要改"。用同一份数据回答
    /// 两个问题会让"隐藏"变成一个没有出口的单向操作。
    func loadManagementCatalog() {
        guard let registryRepository else {
            catalogGroups = []
            return
        }
        let seed = try? ProviderRegistrySeedLoader.load()
        let registry = registryRepository.loadRegistry()
        let definitions = ProviderRegistryResolver.resolveDefinitions(
            builtIn: seed?.definitions ?? [],
            userDefinitions: registry.userDefinitions
        )

        // 预览条目的 instance id 传空串：它们不入库，只用于渲染"配好之后能
        // 拿到什么"。给个假 id 反而危险——将来谁把它当真条目写回去就产生了
        // 一批指向不存在实例的孤儿。
        var seedByDefinition: [String: [ModelCatalogEntry]] = [:]
        if let seed {
            for definition in definitions {
                let entries = seed.catalogEntries(definitionID: definition.id, instanceID: "")
                if !entries.isEmpty { seedByDefinition[definition.id] = entries }
            }
        }

        catalogGroups = CatalogBuilder().buildManagementCatalog(
            registry: registry,
            definitions: definitions,
            seedEntriesByDefinition: seedByDefinition,
            credentialResolved: Self.credentialResolver(registry: registry),
            query: catalogQuery,
            includeHidden: catalogShowsHidden
        )
        catalogAliasConflicts = CatalogCuration.aliasConflicts(in: registry.catalog)
    }

    /// 目录页的搜索框（FR-CAT-08）。显示名与后端 ID 都能命中。
    func updateCatalogQuery(_ query: String) {
        catalogQuery = query
        loadManagementCatalog()
    }

    func toggleCatalogShowsHidden() {
        catalogShowsHidden.toggle()
        loadManagementCatalog()
    }

    // MARK: - 策展（FR-CAT-09）

    func setCatalogVisibility(_ visibility: ModelVisibility, entryIDs: Set<String>) {
        mutateCatalog { catalog in
            CatalogCuration.bulkSetVisibility(visibility, entryIDs: entryIDs, in: catalog)
        }
        catalogSelection.subtract(entryIDs)
    }

    func toggleCatalogVisibility(entryID: String) {
        mutateCatalog { catalog in
            CatalogCuration.toggleVisibility(entryID: entryID, in: catalog)
        }
    }

    func renameCatalogEntry(entryID: String, to displayName: String) {
        mutateCatalog { catalog in
            CatalogCuration.rename(entryID: entryID, to: displayName, in: catalog)
        }
    }

    /// 写别名。冲突时一条都不写，并把冲突原因报给用户（FR-CAT-07）。
    func setCatalogAliases(_ aliases: [String], entryID: String) {
        guard let registryRepository else { return }
        let registry = registryRepository.loadRegistry()
        guard let updated = CatalogCuration.setAliases(aliases, entryID: entryID, in: registry.catalog) else {
            let reason = aliases
                .lazy
                .map { ($0, CatalogCuration.validateAlias($0, for: entryID, in: registry.catalog)) }
                .first { $0.1 != .ok }
            notice = NoticeMessage(style: .error, text: Self.describe(aliasValidation: reason))
            return
        }
        writeCatalog(updated, registry: registry)
    }

    /// 选中/取消一条，供批量操作使用。
    func toggleCatalogSelection(entryID: String) {
        if catalogSelection.contains(entryID) {
            catalogSelection.remove(entryID)
        } else {
            catalogSelection.insert(entryID)
        }
    }

    func clearCatalogSelection() {
        catalogSelection.removeAll()
    }

    /// 全选当前分组里可见的行。批量隐藏两百个模型时，逐条勾选是不可接受的。
    func selectAllInGroup(_ group: CatalogBuilder.ManagementGroup) {
        catalogSelection.formUnion(group.rows.map(\.id))
    }

    // MARK: - 实时发现（FR-CAT-03）

    /// 刷新一个实例的模型列表。
    ///
    /// 失败**不清空目录**，只在分组上留一条"上次刷新失败 + 时间 + 原因"。
    /// 这是这条路径上最重要的一句话：把网络失败等同于"上游没有模型了"，
    /// 会让用户策展了半天的目录在一次点击后凭空消失。
    func refreshCatalog(instanceID: String) async {
        guard let registryRepository, !catalogRefreshingInstanceIDs.contains(instanceID) else { return }
        catalogRefreshingInstanceIDs.insert(instanceID)
        defer { catalogRefreshingInstanceIDs.remove(instanceID) }

        let registry = registryRepository.loadRegistry()
        guard let instance = registry.instance(id: instanceID) else { return }

        let seed = try? ProviderRegistrySeedLoader.load()
        let definitions = ProviderRegistryResolver.resolveDefinitions(
            builtIn: seed?.definitions ?? [],
            userDefinitions: registry.userDefinitions
        )
        guard let definition = definitions.first(where: { $0.id == instance.definitionID }) else {
            recordRefreshFailure(instanceID: instanceID, reason: L10n.tr("catalog.discovery.error.definition_missing"))
            return
        }

        let resolvedBase = ProviderRegistryResolver.resolveBaseURL(
            definition: definition,
            instanceOverride: instance.endpoint.isEmpty ? nil : instance.endpoint,
            environment: ProcessInfo.processInfo.environment
        )
        guard !resolvedBase.value.isEmpty else {
            recordRefreshFailure(instanceID: instanceID, reason: L10n.tr("catalog.discovery.error.baseurl_missing"))
            return
        }
        guard let token = Self.resolveToken(credentialID: instance.credentialID, registry: registry) else {
            recordRefreshFailure(instanceID: instanceID, reason: L10n.tr("catalog.discovery.error.credential_missing"))
            return
        }

        let outcome = await CatalogDiscoveryService().discover(
            baseURL: resolvedBase.value,
            dialect: instance.defaultProtocol,
            token: token
        )

        // 重新读一次注册表：网络往返期间用户可能改过策展，用发请求前的快照
        // 写回去会把那些改动静默覆盖掉。
        var current = registryRepository.loadRegistry()
        let stamp = Int64(Date().timeIntervalSince1970)

        guard outcome.succeeded else {
            var state = current.catalogRefreshStates[instanceID] ?? CatalogRefreshState(lastAttemptAt: stamp)
            state.lastAttemptAt = stamp
            state.failureReason = outcome.failureReason
            current.catalogRefreshStates[instanceID] = state
            persist(current)
            notice = NoticeMessage(style: .error, text: outcome.failureReason ?? L10n.tr("catalog.discovery.error.unknown"))
            loadManagementCatalog()
            return
        }

        let merged = CatalogBuilder().applyDiscovery(
            registry: current,
            instanceID: instanceID,
            liveModelIDs: outcome.modelIDs,
            liveCapabilities: outcome.capabilities
        )
        current = merged.registry
        current.catalogRefreshStates[instanceID] = CatalogRefreshState(
            lastAttemptAt: stamp,
            lastSuccessAt: stamp,
            failureReason: nil,
            discoveredCount: outcome.modelIDs.count,
            addedCount: merged.addedCount
        )
        persist(current)

        notice = NoticeMessage(
            style: .success,
            text: String(
                format: L10n.tr("catalog.refresh.summary_format"),
                outcome.modelIDs.count,
                merged.addedCount,
                merged.delistedCount
            )
        )
        loadManagementCatalog()
        loadCatalog()
        onProvidersChanged()
    }

    // MARK: - 私有

    /// 目录写入的公共骨架：读 → 改 → 落盘 → 重建两个视图。
    ///
    /// 每次都从仓储重读而不是用 `catalogGroups` 里的快照：那份快照是给渲染
    /// 用的投影，拿它当写入基线会把界面上没显示的条目（被搜索过滤掉的那些）
    /// 一起丢掉。
    private func mutateCatalog(_ transform: ([ModelCatalogEntry]) -> [ModelCatalogEntry]) {
        guard let registryRepository else { return }
        let registry = registryRepository.loadRegistry()
        writeCatalog(transform(registry.catalog), registry: registry)
    }

    private func writeCatalog(_ catalog: [ModelCatalogEntry], registry: ProviderRegistryV2) {
        var updated = registry
        updated.catalog = catalog
        persist(updated)
        loadManagementCatalog()
        loadCatalog()
        onProvidersChanged()
    }

    private func persist(_ registry: ProviderRegistryV2) {
        guard let registryRepository else { return }
        do {
            try registryRepository.saveRegistry(registry)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func recordRefreshFailure(instanceID: String, reason: String) {
        guard let registryRepository else { return }
        var registry = registryRepository.loadRegistry()
        let stamp = Int64(Date().timeIntervalSince1970)
        var state = registry.catalogRefreshStates[instanceID] ?? CatalogRefreshState(lastAttemptAt: stamp)
        state.lastAttemptAt = stamp
        state.failureReason = reason
        registry.catalogRefreshStates[instanceID] = state
        persist(registry)
        notice = NoticeMessage(style: .error, text: reason)
        loadManagementCatalog()
    }

    private static func describe(aliasValidation: (String, CatalogCuration.AliasValidation)?) -> String {
        guard let (alias, validation) = aliasValidation else {
            return L10n.tr("catalog.alias.error.generic")
        }
        switch validation {
        case .ok:
            return L10n.tr("catalog.alias.error.generic")
        case .empty:
            return L10n.tr("catalog.alias.error.empty")
        case .shadowsBackendModel(let modelID):
            return String(format: L10n.tr("catalog.alias.error.shadows_format"), modelID)
        case .duplicate:
            return String(format: L10n.tr("catalog.alias.error.duplicate_format"), alias)
        }
    }

    /// 凭据是否可解析。与 `loadCatalog()` 用的是同一套判断，抽出来避免两处
    /// 各自演化——它们一旦不一致，目录页和管理页就会对同一家给出不同答案。
    static func credentialResolver(registry: ProviderRegistryV2) -> (String) -> Bool {
        let secrets = KeychainSecretStore()
        return { credentialID in
            guard let credential = registry.credential(id: credentialID),
                  let reference = credential.secureReference else {
                return false
            }
            switch reference.storage {
            case .keychainAccount:
                return secrets.read(account: reference.name) != nil
            case .environmentVariable:
                return !(ProcessInfo.processInfo.environment[reference.name] ?? "").isEmpty
            case .externalSessionFile:
                // 只看源文件在不在。**不读内容**——真正读取要过 SEC-08 同意门禁。
                return FileManager.default.fileExists(atPath: reference.name)
            }
        }
    }

    /// 取出用于发现请求的令牌。
    ///
    /// `externalSessionFile` 在这里**返回 nil**：读第三方 CLI 的登录态需要
    /// 走同意门禁并按各家格式解析，那是 FR-IDT-04 的事，不该为了刷一次模型
    /// 列表在这里复制一份简化版。宁可让这类凭据的发现明确失败，也不要出现
    /// 一条绕过门禁的读取路径（SEC-08）。
    static func resolveToken(credentialID: String, registry: ProviderRegistryV2) -> String? {
        guard let credential = registry.credential(id: credentialID),
              let reference = credential.secureReference else {
            return nil
        }
        switch reference.storage {
        case .keychainAccount:
            let value = KeychainSecretStore().read(account: reference.name)
            return (value?.isEmpty ?? true) ? nil : value
        case .environmentVariable:
            let value = ProcessInfo.processInfo.environment[reference.name]
            return (value?.isEmpty ?? true) ? nil : value
        case .externalSessionFile:
            return nil
        }
    }
}
