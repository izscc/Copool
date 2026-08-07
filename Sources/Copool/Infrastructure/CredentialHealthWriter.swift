import Foundation

/// 把**真实请求**的结果写回凭据健康状态（FR-IDT-07 / FR-RTE-04）。
///
/// 为什么不直接用 `CredentialCoordinator`：那是 Behavior 层的 `@MainActor`
/// 类型，代理运行时是 Infrastructure 层的 actor，方向反了。这里只做
/// "读注册表 → 套用纯判定 → 写回"这一件事，判定规则仍然是
/// `CredentialHealthEvaluator` 那一份，不复制第二套。
///
/// 与 `markCooldown` 的分工：冷却是**进程内**的临时降权，重启即失效；
/// 这里写的是**落盘**的健康状态，重启后路由的凭据门禁仍然认得它。一个 401
/// 只冷却不落盘，用户重启一次 App 就会重新把请求打到那把已被吊销的 Key 上。
final class CredentialHealthWriter: @unchecked Sendable {
    private let repository: ProviderRegistryV2Repository
    private let now: @Sendable () -> Int64
    private let lock = NSLock()

    init(
        repository: ProviderRegistryV2Repository,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.repository = repository
        self.now = now
    }

    /// 按 provider 实例 id 定位它绑定的凭据并写回结果。
    ///
    /// 运行时手里只有 v1 的 provider id，而它与 v2 的 `ProviderInstance.id`
    /// 是同一个 UUID（AC-005），所以这个入口足够用，不需要让运行时去理解
    /// 凭据模型。
    ///
    /// 找不到实例或它没绑凭据时静默返回：v1-only 的用户根本没有 registry，
    /// 那不是异常，只是没有可写的对象。
    func record(instanceID: String, statusCode: Int, responseBody: String?) {
        let outcome = CredentialHealthEvaluator.outcome(statusCode: statusCode, responseBody: responseBody)
        record(instanceID: instanceID, outcome: outcome)
    }

    /// 网络层失败没有状态码，单独入口。**不会**把凭据判成无权限——
    /// 网络不通是链路问题，误判会让用户去重填一把完全正常的 Key（FR-CAT-09）。
    func recordNetworkFailure(instanceID: String, error: Error) {
        record(instanceID: instanceID, outcome: .networkFailure(detail: error.localizedDescription))
    }

    func record(instanceID: String, outcome: CredentialHealthEvaluator.ProbeOutcome) {
        lock.lock()
        defer { lock.unlock() }

        var registry = repository.loadRegistry()
        // `credentialID` 是非可选的，空串表示这条实例还没绑凭据——那没有
        // 可写的对象，静默返回。
        guard let instance = registry.instances.first(where: { $0.id == instanceID }),
              !instance.credentialID.isEmpty,
              let index = registry.credentials.firstIndex(where: { $0.id == instance.credentialID }) else {
            return
        }

        let credential = registry.credentials[index]
        let timestamp = now()
        let signals = CredentialHealthEvaluator.Signals(
            kind: credential.kind,
            // 这条路径的前提就是"刚用这把凭据发过一个真实请求"，秘密必然
            // 存在过。重新探测 Keychain 会在每个请求尾部多一次同步 IO，而
            // 它能改变的结论只有"用户恰好在这几毫秒内删了凭据"。
            secretPresent: true,
            expiresAt: credential.expiresAt,
            now: timestamp,
            lastProbe: outcome,
            verificationInFlight: false
        )
        let verdict = CredentialHealthEvaluator.evaluate(signals)
        let updated = CredentialHealthEvaluator.apply(verdict, to: credential, at: timestamp)
        // 状态没变就不写盘。成功请求是绝大多数，每一条都重写 registry.json
        // 会让磁盘一直在响，而内容一个字节都没变。
        guard updated != credential else { return }
        registry.credentials[index] = updated
        try? repository.saveRegistry(registry)
    }
}
