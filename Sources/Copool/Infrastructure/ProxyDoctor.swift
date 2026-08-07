import Foundation

/// Outcome severity for a doctor check (AC-014: layered PASS/WARN/FAIL).
enum DoctorSeverity: String, Codable, Equatable, Sendable {
    case pass
    case warn
    case fail
}

/// One diagnostic check result.
///
/// `name` 与 `message` 存的是**已本地化的字符串**，不是键。检查项的消息里
/// 大多要嵌运行时数字（"3 个模型缺失"），存键就还得把参数一起带上，等于
/// 在这里重新发明一套格式化。
struct DoctorCheck: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Layered outcome (AC-014). `warn` = degraded but not broken.
    let severity: DoctorSeverity
    let message: String?

    var passed: Bool { severity == .pass }

    init(id: String, name: String, severity: DoctorSeverity, message: String? = nil) {
        self.id = id
        self.name = name
        self.severity = severity
        self.message = message
    }

    init(id: String, name: String, passed: Bool, message: String? = nil) {
        self.init(id: id, name: name, severity: passed ? .pass : .fail, message: message)
    }
}

/// One-shot environment diagnosis (codex-router's `doctor` checks, adapted to
/// this app's own plumbing). Read-only: it reports, it never repairs.
///
/// Severity policy (AC-014):
/// - `.fail`  — the proxy or its data is broken and needs attention.
/// - `.warn`  — degraded: native or third-party capability partially missing,
///              or an app-managed setting is not currently applied.
/// - `.pass`  — healthy.
struct ProxyDoctor: Sendable {
    var healthProbe: @Sendable () async -> Bool
    var now: @Sendable () -> Date

    init(
        healthProbe: @escaping @Sendable () async -> Bool = {
            guard let url = URL(string: "http://127.0.0.1:8787/health") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.healthProbe = healthProbe
        self.now = now
    }

    func run(paths: FileSystemPaths) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // 1. Local proxy health — the proxy is the core of the app: fail.
        let healthy = await healthProbe()
        checks.append(
            DoctorCheck(
                id: "proxy.health",
                name: L10n.tr("doctor.proxy.health"),
                severity: healthy ? .pass : .fail,
                message: healthy ? nil : L10n.tr("doctor.proxy.health.fail")
            )
        )

        // 2. Codex config points at the local provider — app-managed and
        // self-healing (the proxy rewrites it on start/stop): warn when off.
        let configText = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        let hasProvider = configText?.contains("model_provider") == true
            && configText?.contains("opencodex") == true
        checks.append(
            DoctorCheck(
                id: "codex.config",
                name: L10n.tr("doctor.codex.config"),
                severity: hasProvider ? .pass : .warn,
                message: hasProvider ? nil : L10n.tr("doctor.codex.config.warn")
            )
        )

        // 3. Models cache carries third-party models (ids without namespace
        // prefixes — icopool merges the provider models verbatim).
        let configuredModelIDs = Set(
            (try? ProviderFileRepository(paths: paths).loadProviders())?
                .providers.flatMap { $0.models.map { $0.id.lowercased() } } ?? []
        )
        let cachedModelIDs: Set<String> = {
            guard let data = try? Data(contentsOf: paths.codexModelsCachePath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            let models = (json["models"] as? [[String: Any]]) ?? []
            return Set(models.compactMap { ($0["id"] as? String)?.lowercased() })
        }()
        let missingFromCache = configuredModelIDs.subtracting(cachedModelIDs)
        let hasThirdParty = !configuredModelIDs.isEmpty && missingFromCache.isEmpty
        checks.append(
            DoctorCheck(
                id: "codex.models_cache",
                name: L10n.tr("doctor.codex.models_cache"),
                severity: hasThirdParty ? .pass : .warn,
                message: hasThirdParty
                    ? nil
                    : L10n.tr("doctor.codex.models_cache.warn_format", String(missingFromCache.count))
            )
        )

        // 4. Provider store parses — corrupted data means no third-party
        // routing at all: fail.
        let providers = try? ProviderFileRepository(paths: paths).loadProviders()
        checks.append(
            DoctorCheck(
                id: "providers.store",
                name: L10n.tr("doctor.providers.store"),
                severity: providers != nil ? .pass : .fail,
                message: providers == nil
                    ? L10n.tr("doctor.providers.store.fail")
                    : L10n.tr("doctor.providers.store.pass_format", String(providers?.providers.count ?? 0))
            )
        )

        // 5. Codex auth present — native models unavailable without it, but
        // third-party routing keeps working: warn.
        let authExists = FileManager.default.fileExists(atPath: paths.codexAuthPath.path)
        checks.append(
            DoctorCheck(
                id: "codex.auth",
                name: L10n.tr("doctor.codex.auth"),
                severity: authExists ? .pass : .warn,
                message: authExists ? nil : L10n.tr("doctor.codex.auth.warn")
            )
        )

        // 6. Private file permissions (providers.json) — security relevant: fail.
        let permsOK = (try? FileManager.default.attributesOfItem(atPath: paths.providerStorePath.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { $0.intValue & 0o777 == 0o600 } == true
        checks.append(
            DoctorCheck(
                id: "providers.permissions",
                name: L10n.tr("doctor.providers.permissions"),
                severity: permsOK ? .pass : .fail,
                message: permsOK ? nil : L10n.tr("doctor.providers.permissions.fail")
            )
        )

        // 7. Usage ledger is writable — auditing degraded only: warn.
        let ledgerWritable = FileManager.default.isWritableFile(atPath: paths.usageEventsPath.path)
            || !FileManager.default.fileExists(atPath: paths.usageEventsPath.path)
        checks.append(
            DoctorCheck(
                id: "usage.ledger",
                name: L10n.tr("doctor.usage.ledger"),
                severity: ledgerWritable ? .pass : .warn,
                message: ledgerWritable ? nil : L10n.tr("doctor.usage.ledger.warn")
            )
        )

        checks.append(contentsOf: registryChecks(paths: paths))
        return checks
    }

    // MARK: - v2 注册表（M5）

    /// 注册表侧的四项检查。
    ///
    /// 注册表不存在**不是错误**：v1-only 的用户从没跑过迁移，那是完全正常的
    /// 状态。这种情况下四项一起跳过，而不是报四条"缺失"——用户会以为自己
    /// 装坏了什么。
    private func registryChecks(paths: FileSystemPaths) -> [DoctorCheck] {
        guard FileManager.default.fileExists(atPath: paths.registryV2Path.path) else { return [] }

        var checks: [DoctorCheck] = []
        let raw = try? Data(contentsOf: paths.registryV2Path)
        guard let registry = raw.flatMap({ try? JSONDecoder().decode(ProviderRegistryV2.self, from: $0) }) else {
            checks.append(
                DoctorCheck(
                    id: "registry.version",
                    name: L10n.tr("doctor.registry.version"),
                    severity: .fail,
                    message: L10n.tr("doctor.registry.version.fail")
                )
            )
            // 解析失败时后面三项没有可检查的对象，继续走只会连报三条同因错误。
            return checks
        }

        // 8. 注册表能解析且版本是当前版本。解析不了 = 第三方路由整体失效：fail。
        // 版本落后只是还没迁移，路由会回落 v1，仍然可用：warn。
        let current = registry.version == ProviderRegistryV2.currentVersion
        checks.append(
            DoctorCheck(
                id: "registry.version",
                name: L10n.tr("doctor.registry.version"),
                severity: current ? .pass : .warn,
                message: current
                    ? nil
                    : L10n.tr(
                        "doctor.registry.version.warn_format",
                        String(registry.version),
                        String(ProviderRegistryV2.currentVersion)
                    )
            )
        )

        // 9. 凭据健康：有多少把处于"用不了"的状态。
        //
        // `.unconfigured` 不计入：那是"还没填"，不是"坏了"。把它算成异常会让
        // 一个刚装好、只配了一家 provider 的用户看到一屏红色。
        let broken = registry.credentials.filter {
            $0.healthState == .unauthorized || $0.healthState == .expired
        }
        checks.append(
            DoctorCheck(
                id: "registry.credentials",
                name: L10n.tr("doctor.registry.credentials"),
                severity: broken.isEmpty ? .pass : .warn,
                message: broken.isEmpty
                    ? L10n.tr("doctor.registry.credentials.pass_format", String(registry.credentials.count))
                    : L10n.tr("doctor.registry.credentials.warn_format", String(broken.count))
            )
        )

        // 10. 目录非空。空目录意味着任何模型名都解析不出来，请求会 404：
        // 但 v1 精确匹配仍然兜得住，所以是 warn 不是 fail。
        checks.append(
            DoctorCheck(
                id: "registry.catalog",
                name: L10n.tr("doctor.registry.catalog"),
                severity: registry.catalog.isEmpty ? .warn : .pass,
                message: registry.catalog.isEmpty
                    ? L10n.tr("doctor.registry.catalog.warn")
                    : L10n.tr("doctor.registry.catalog.pass_format", String(registry.catalog.count))
            )
        )

        // 11. 路由决策账本可写。写不动只是失去可解释性，请求照常路由：warn。
        let decisionsWritable = FileManager.default.isWritableFile(atPath: paths.routeDecisionsPath.path)
            || !FileManager.default.fileExists(atPath: paths.routeDecisionsPath.path)
        checks.append(
            DoctorCheck(
                id: "registry.route_ledger",
                name: L10n.tr("doctor.registry.route_ledger"),
                severity: decisionsWritable ? .pass : .warn,
                message: decisionsWritable ? nil : L10n.tr("doctor.registry.route_ledger.warn")
            )
        )

        // 12. 注册表文件权限。里面有凭据引用与账号标识，和 providers.json
        // 同等敏感：fail。
        let registryPermsOK = (try? FileManager.default.attributesOfItem(atPath: paths.registryV2Path.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { $0.intValue & 0o777 == 0o600 } == true
        checks.append(
            DoctorCheck(
                id: "registry.permissions",
                name: L10n.tr("doctor.registry.permissions"),
                severity: registryPermsOK ? .pass : .fail,
                message: registryPermsOK ? nil : L10n.tr("doctor.registry.permissions.fail")
            )
        )

        return checks
    }
}
