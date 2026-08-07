import Foundation

/// M1 供应商注册表的页面动作（FR-PRV-*、FR-IDT-*）。
///
/// 与 v1 的 `providers` 列表并存而不是替换：v1 列表是"用户手工加的自定义
/// 端点"，注册表是"内置 23 家 + 用户覆盖"。两者的生命周期不同，合并显示
/// 会让"删掉一条"的语义变得无法解释。
@MainActor
extension ProviderPageModel {

    /// 重建分组列表。种子解析失败时如实报错——种子是构建产物，
    /// 静默显示空列表会让用户以为是自己的配置丢了。
    func loadProviderGroups() {
        guard let registryRepository else {
            providerGroups = []
            return
        }

        let seed: ProviderRegistrySeedLoader.Seed
        do {
            seed = try ProviderRegistrySeedLoader.load()
            registrySeedError = nil
        } catch {
            registrySeedError = error.localizedDescription
            providerGroups = []
            return
        }

        let registry = registryRepository.loadRegistry()
        let definitions = ProviderRegistryResolver.resolveDefinitions(
            builtIn: seed.definitions,
            userDefinitions: registry.userDefinitions
        )

        // 种子目录按 definition 归属，实例目录按 instance 归属。没有实例的
        // provider 显示种子里的条目数，让用户在配置前就知道能拿到什么。
        var catalogCounts: [String: Int] = [:]
        for entry in seed.catalog {
            catalogCounts[entry.provider, default: 0] += 1
        }
        for definition in definitions {
            guard let instance = registry.instances.first(where: { $0.definitionID == definition.id }) else { continue }
            let live = registry.catalogEntries(instanceID: instance.id).count
            // 实例一旦有了自己的目录就以它为准：那是发现+策展后的真实结果，
            // 种子只是配置前的预期值。
            if live > 0 { catalogCounts[definition.id] = live }
        }

        providerGroups = ProviderRegistryPresenter.groups(
            definitions: definitions,
            registry: registry,
            environment: ProcessInfo.processInfo.environment,
            catalogCounts: catalogCounts,
            throttledCredentialIDs: throttledCredentialIDs(registry: registry)
        )
    }

    /// 启动时重算一遍健康状态，避免 UI 一进来显示的是上次退出时的缓存。
    func refreshCredentialHealth() {
        guard let credentials else { return }
        do {
            try credentials.refreshAllHealth()
            loadProviderGroups()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    // MARK: - 面板开合

    func beginConfiguringCredential(_ group: ProviderRegistryPresenter.GroupViewData) {
        // 需要披露的两类走同意面板，不进录入面板：录入面板没有勾选门禁，
        // 从那里进去等于绕过 SEC-08。
        if let spec = group.externalSession,
           group.credentialKinds.contains(.externalCLISession) {
            let path = Self.expandTilde(spec.sessionPathHint ?? "")
            consentSheet = ConsentSheetContext(group: group, spec: spec, resolvedPath: path)
            return
        }
        credentialSheet = CredentialSheetContext(group: group)
    }

    func dismissCredentialSheets() {
        credentialSheet = nil
        consentSheet = nil
    }

    // MARK: - 写入

    func saveAPIKey(for group: ProviderRegistryPresenter.GroupViewData, key: String) {
        performCredentialWrite(group: group) { coordinator, instanceID in
            try coordinator.saveAPIKey(instanceID: instanceID, key: key)
        }
    }

    func bindEnvironmentVariable(for group: ProviderRegistryPresenter.GroupViewData, name: String) {
        performCredentialWrite(group: group) { coordinator, instanceID in
            try coordinator.bindEnvironmentVariable(instanceID: instanceID, variableName: name)
        }
    }

    /// 复用第三方 CLI 的本机登录态（FR-IDT-04）。`disclosure` 传的是**用户
    /// 刚刚看到的那段原文**，它会被原样写进审计记录。
    func bindExternalSession(
        for group: ProviderRegistryPresenter.GroupViewData,
        sessionPath: String,
        disclosure: String
    ) {
        performCredentialWrite(group: group) { coordinator, instanceID in
            try coordinator.bindExternalSession(
                instanceID: instanceID,
                sessionPath: sessionPath,
                disclosure: disclosure,
                userConsented: true
            )
        }
    }

    /// 撤销一条凭据（FR-IDT-08）。只清 Copool 自己存的那份，
    /// 不碰第三方 CLI/客户端里的原始登录态。
    func revokeCredential(for group: ProviderRegistryPresenter.GroupViewData) {
        guard let credentials else { return }
        do {
            try credentials.deleteCredential(credentialID: group.credentialID)
            loadProviderGroups()
            notice = NoticeMessage(style: .success, text: L10n.tr("credentials.notice.revoked"))
            onProvidersChanged()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    // MARK: - 私有

    /// 所有写入路径共享的骨架：按需建实例 → 写凭据 → 刷新 → 关面板。
    ///
    /// 失败时**不关面板**：关掉会让用户失去刚才输入的内容，还得重新粘贴一次。
    private func performCredentialWrite(
        group: ProviderRegistryPresenter.GroupViewData,
        _ write: (CredentialCoordinator, String) throws -> CredentialIdentity
    ) {
        guard let credentials else {
            notice = NoticeMessage(style: .error, text: L10n.tr("credentials.error.registry_unavailable"))
            return
        }
        guard let definitionID = group.channels.first?.definitionID else { return }

        do {
            let seed = try? ProviderRegistrySeedLoader.load()
            // 共用组要给每条通道都建实例，否则只有第一条能被路由到——
            // "填一次三条通道都就绪"里的"三条"就是这里落地的。
            var instanceIDs: [String] = []
            for channel in group.channels {
                let definition = seed?.definitions.first { $0.id == channel.definitionID }
                instanceIDs.append(
                    try credentials.ensureInstance(
                        definitionID: channel.definitionID,
                        displayName: channel.displayName,
                        definition: definition,
                        catalogSeed: { instanceID in
                            seed?.catalogEntries(
                                definitionID: channel.definitionID,
                                instanceID: instanceID
                            ) ?? []
                        }
                    )
                )
            }
            guard let primary = instanceIDs.first else { return }
            _ = try write(credentials, primary)

            loadProviderGroups()
            dismissCredentialSheets()
            notice = NoticeMessage(style: .success, text: L10n.tr("credentials.notice.saved"))
            onProvidersChanged()
        } catch {
            _ = definitionID
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    /// 限流是正交维度：被限流的凭据仍然就绪，只是权重该降低。这里从被动
    /// 采集的限流头快照里推断，剩余额度为 0 且尚未到重置时刻即视为限流中。
    private func throttledCredentialIDs(registry: ProviderRegistryV2) -> Set<String> {
        let now = Int64(Date().timeIntervalSince1970)
        var result: Set<String> = []
        for (providerID, snapshot) in rateLimits {
            let windows = [snapshot.requests, snapshot.tokens].compactMap { $0 }
            let exhausted = windows.contains { window in
                window.remaining == 0 && (window.resetAt ?? now) > now
            }
            guard exhausted else { continue }
            guard let instance = registry.instance(id: providerID) else { continue }
            result.insert(instance.credentialID.isEmpty ? "cred-\(instance.id)" : instance.credentialID)
        }
        return result
    }

    /// 种子里的路径提示写成 `~/.claude/...`，展开成绝对路径才能判断存在性。
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
