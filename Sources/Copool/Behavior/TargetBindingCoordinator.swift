import Foundation

/// 目标绑定协调器（M3）。
///
/// 职责：绑定的增删改、plan → apply → verify → rollback 的编排、
/// apply 成功后写入目录指纹（FR-CAT-11）、以及过期检测。
///
/// 适配器由外部以闭包注入：`CodexTargetAdapter` / `TargetJSONConfigAdapter`
/// 都是 Infrastructure 类型，Behavior 直接 new 它们会把分层打穿。闭包让
/// 组装的知识留在 AppContainer，这里只认 `TargetConfigManaging` 协议。
@MainActor
final class TargetBindingCoordinator: ObservableObject {
    /// 一个绑定的配置适配器 + 它的目标配置文本生成器。
    ///
    /// 两者绑在一起是因为它们必须来自同一个适配器实例：`desiredConfig`
    /// 要读当前文件内容来保留用户自有配置，用另一个实例算出来的期望值
    /// 有可能对着一个不同的路径。
    struct AdapterBundle {
        var adapter: any TargetConfigManaging
        /// 端口 → 期望写入的完整配置文本。
        var desiredConfig: (Int) -> String

        init(adapter: any TargetConfigManaging, desiredConfig: @escaping (Int) -> String) {
            self.adapter = adapter
            self.desiredConfig = desiredConfig
        }
    }

    private let bindingRepository: TargetBindingRepositoryProtocol
    private let registryRepository: ProviderRegistryRepository
    private let makeBundle: (String) -> AdapterBundle?

    @Published private(set) var bindings: [TargetBinding] = []
    /// 每个绑定最近一次 plan 的摘要，供 UI 在 apply 前展示。
    @Published private(set) var planSummaries: [String: String] = [:]
    /// 目录已漂移的绑定（FR-CAT-11）。
    @Published private(set) var staleBindingIDs: Set<String> = []
    @Published var notice: String?

    init(
        bindingRepository: TargetBindingRepositoryProtocol,
        registryRepository: ProviderRegistryRepository,
        makeBundle: @escaping (String) -> AdapterBundle?
    ) {
        self.bindingRepository = bindingRepository
        self.registryRepository = registryRepository
        self.makeBundle = makeBundle
    }

    // MARK: - 载入

    func loadBindings() {
        do {
            bindings = try bindingRepository.load().bindings
        } catch {
            // 读不出来时保留内存里已有的那份，而不是清空：清空会让 UI 看起来
            // 像"绑定被删了"，而实际上磁盘上的文件还在。
            notice = L10n.tr("targets.error.load_failed")
        }
        refreshStaleness()
    }

    // MARK: - 增删改

    func toggleEnabled(bindingID: String) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        bindings[index].enabled.toggle()
        persist()
    }

    func setPort(bindingID: String, port: Int?) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        bindings[index].listenerPort = port
        persist()
    }

    /// 设置该绑定可路由到的 provider 实例（AC-008）。
    ///
    /// 改完立刻重算过期状态：provider 集合变了，目录指纹的取值范围就变了，
    /// 不重算的话 UI 会继续显示上一份集合的结论。
    func setProviders(bindingID: String, instanceIDs: [String]) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        bindings[index].enabledProviderInstanceIDs = instanceIDs
        persist()
        refreshStaleness()
    }

    func toggleProvider(bindingID: String, instanceID: String) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        var ids = bindings[index].enabledProviderInstanceIDs
        if let position = ids.firstIndex(of: instanceID) {
            ids.remove(at: position)
        } else {
            ids.append(instanceID)
        }
        setProviders(bindingID: bindingID, instanceIDs: ids)
    }

    // MARK: - 探测与计划

    func detect(bindingID: String) -> TargetDetection? {
        guard let bundle = makeBundle(bindingID) else { return nil }
        guard let snapshot = bundle.adapter.detect() else {
            return TargetDetection(
                bindingID: bindingID,
                configExists: false,
                configText: nil,
                managedBlocksPresent: 0,
                preservedUserLineCount: 0
            )
        }
        return TargetDetection(
            bindingID: bindingID,
            configExists: true,
            configText: snapshot.content,
            managedBlocksPresent: Self.managedBlockCount(in: snapshot.content),
            preservedUserLineCount: 0
        )
    }

    /// 只算不写。UI 用返回的摘要让用户先看清将要发生什么（AC-007）。
    @discardableResult
    func plan(bindingID: String, port: Int) -> TargetConfigDiff? {
        guard let bundle = makeBundle(bindingID) else {
            notice = L10n.tr("targets.error.no_adapter")
            return nil
        }
        let diff = bundle.adapter.plan(to: bundle.desiredConfig(port))
        planSummaries[bindingID] = Self.summary(for: diff)
        return diff
    }

    // MARK: - 应用

    /// 应用配置。verify 不过时抛错并保留备份，让用户可以回滚。
    ///
    /// 指纹在 verify 通过之后才写：先写指纹再验证的话，一次失败的 apply
    /// 会留下"已应用且最新"的假象，而磁盘上根本不是那份内容。
    func applyConfig(bindingID: String, port: Int) throws {
        guard let binding = bindings.first(where: { $0.id == bindingID }) else {
            throw AppError.io(L10n.tr("targets.error.binding_missing"))
        }
        guard let bundle = makeBundle(bindingID) else {
            throw AppError.io(L10n.tr("targets.error.no_adapter"))
        }

        let desired = bundle.desiredConfig(port)
        let diff = bundle.adapter.plan(to: desired)
        try bundle.adapter.apply(diff)

        guard bundle.adapter.verify(diff) else {
            throw AppError.io(L10n.tr("targets.error.verify_failed"))
        }

        let registry = registryRepository.loadRegistry()
        if let index = bindings.firstIndex(where: { $0.id == bindingID }) {
            bindings[index].appliedCatalogFingerprint = CatalogFingerprint.compute(
                registry: registry,
                enabledInstanceIDs: binding.enabledProviderInstanceIDs
            )
            bindings[index].configFingerprint = ContentFingerprint.of(desired)
            persist()
        }

        planSummaries[bindingID] = Self.summary(for: diff)
        refreshStaleness()
        notice = String(format: L10n.tr("targets.notice.applied_format"), binding.displayName)
    }

    func rollback(bindingID: String, port: Int) throws {
        guard let bundle = makeBundle(bindingID) else {
            throw AppError.io(L10n.tr("targets.error.no_adapter"))
        }
        // 回滚只需要 before：适配器从备份恢复，after 是什么无关紧要，
        // 但协议要求给一个，所以用当前 plan 的结果填。
        let diff = bundle.adapter.plan(to: bundle.desiredConfig(port))
        try bundle.adapter.rollback(diff)

        // 回滚之后磁盘上不再是我们写的那份，指纹必须清掉，
        // 否则过期检测会拿一个已经不成立的基准去比。
        if let index = bindings.firstIndex(where: { $0.id == bindingID }) {
            bindings[index].appliedCatalogFingerprint = nil
            bindings[index].configFingerprint = nil
            persist()
        }
        planSummaries.removeValue(forKey: bindingID)
        refreshStaleness()
        notice = L10n.tr("targets.notice.rolled_back")
    }

    /// 卸载指定绑定的托管配置（移除 copool 托管块）。
    func uninstall(bindingID: String) throws {
        guard let bundle = makeBundle(bindingID) else {
            throw AppError.io(L10n.tr("targets.error.no_adapter"))
        }
        try bundle.adapter.uninstall()

        if let index = bindings.firstIndex(where: { $0.id == bindingID }) {
            bindings[index].appliedCatalogFingerprint = nil
            bindings[index].configFingerprint = nil
            persist()
        }
        planSummaries.removeValue(forKey: bindingID)
        refreshStaleness()
        notice = L10n.tr("targets.notice.uninstalled")
    }

    // MARK: - 目录过期（FR-CAT-11）

    func refreshStaleness() {
        let registry = registryRepository.loadRegistry()
        staleBindingIDs = Set(
            bindings.filter { $0.isCatalogStale(against: registry) }.map(\.id)
        )
    }

    func isStale(bindingID: String) -> Bool {
        staleBindingIDs.contains(bindingID)
    }

    // MARK: - 内部

    private func persist() {
        do {
            try bindingRepository.save(TargetBindingStore(bindings: bindings))
        } catch {
            notice = L10n.tr("targets.error.save_failed")
        }
    }

    private static func managedBlockCount(in text: String) -> Int {
        max(0, text.components(separatedBy: ">>> copool managed").count - 1)
    }

    private static func summary(for diff: TargetConfigDiff) -> String {
        let before = diff.before?.content.split(separator: "\n").count ?? 0
        let after = diff.after.content.split(separator: "\n").count
        return String(
            format: L10n.tr("targets.plan.summary_format"),
            before,
            after,
            diff.preservedUserLines.count
        )
    }
}
