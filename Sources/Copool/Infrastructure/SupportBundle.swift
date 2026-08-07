import Foundation

// `SecretRedactor` 与 `NSRegularExpression.stringByReplacingMatches` 已移至
// Domain/SecretRedactor.swift：脱敏是纯字符串变换，且 `CredentialHealthEvaluator`
// 落盘前必须调它（INV-1），留在 Infrastructure 会让 Domain 反向依赖 Infrastructure。

/// Collects a redacted diagnostic bundle: environment facts, config
/// fingerprints, provider metadata (references, never values) and recent
/// ledger stats. No secrets, no keychain values, no auth payloads.
struct SupportBundleBuilder: Sendable {
    var paths: FileSystemPaths
    var now: @Sendable () -> Date

    init(paths: FileSystemPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.now = now
    }

    /// Builds a redacted support bundle as a JSON document.
    func build(
        providers: [ProviderConfig],
        engineStatus: RouterEngineStatus?,
        doctorChecks: [DoctorCheck] = []
    ) async -> String {
        var bundle: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: now()),
            "appVersion": AppVersion.current.description,
        ]

        // Environment facts.
        bundle["environment"] = [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostname": Host.current().localizedName ?? "unknown",
        ]

        // Provider metadata: references only.
        bundle["providers"] = providers.map { provider in
            [
                "id": provider.id,
                "name": provider.name,
                "baseURL": provider.baseURL,
                "authKind": provider.authKind.rawValue,
                "modelCount": provider.models.count,
                "keychainAccountRef": "keychain:\(provider.id)",
            ]
        }

        // Config fingerprints (never content).
        bundle["configFingerprints"] = [
            "codexConfig": fingerprint(paths.codexConfigPath),
            "providersStore": fingerprint(paths.providerStorePath),
            "registryV2": fingerprint(paths.registryV2Path),
        ]

        // Engine status (may contain the API key — redact it).
        if let status = engineStatus {
            bundle["engine"] = [
                "running": status.running,
                "port": status.port ?? -1,
                "apiKey": status.apiKey.map { _ in SecretRedactor.redaction } ?? "none",
                "availableAccounts": status.availableAccounts,
                "lastError": status.lastError.map(SecretRedactor.redactText) ?? "none",
            ]
        }

        // Recent usage ledger stats (no prompts, only aggregates).
        let ledger = UsageEventLedger(path: paths.usageEventsPath)
        let aggregates = ledger.dailyAggregates(days: 3)
        bundle["usageLast3Days"] = aggregates.map {
            ["day": $0.day, "providerID": $0.providerID, "requests": $0.requests, "totalTokens": $0.totalTokens]
        }

        // 诊断结果（M5）。支持包的用途就是"用户遇到问题时一次性交出上下文"，
        // 而 Doctor 恰恰是那份上下文里最直接的部分——没有它，收到包的人还得
        // 再来回问一遍"代理起来了吗、config 指对了吗"。
        //
        // `message` 里可能带路径与计数，但不含秘密（检查项本身只读元数据），
        // 仍然过一遍脱敏兜底。
        if !doctorChecks.isEmpty {
            bundle["doctor"] = doctorChecks.map { check in
                [
                    "id": check.id,
                    "severity": check.severity.rawValue,
                    "message": check.message.map(SecretRedactor.redactText) ?? "",
                ]
            }
        }

        // 凭据健康（M5）。只出状态与形态，**绝不**出引用名或秘密本身：
        // `SecureReference.name` 是 Keychain 账户名/环境变量名/会话文件路径，
        // 后两者会直接暴露用户的目录结构和自定义变量命名。
        bundle["credentials"] = credentialSummary()

        // 路由决策的近期统计。不放 trace 原文——那里面有模型名与请求 ID，
        // 量也大；这里只回答"最近路由得顺不顺"。
        bundle["routeDecisions"] = routeDecisionSummary()

        let data = (try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 按健康状态计数的凭据摘要。
    ///
    /// 注册表不存在时返回空字典而不是省略这个键：收到包的人需要能区分
    /// "没有凭据"和"这份包是旧版本生成的、根本没这一项"。
    private func credentialSummary() -> [String: Any] {
        guard let data = try? Data(contentsOf: paths.registryV2Path),
              let registry = try? JSONDecoder().decode(ProviderRegistryV2.self, from: data) else {
            return ["registryPresent": false]
        }
        var byState: [String: Int] = [:]
        for credential in registry.credentials {
            byState[credential.healthState.rawValue, default: 0] += 1
        }
        var byKind: [String: Int] = [:]
        for credential in registry.credentials {
            byKind[credential.kind.rawValue, default: 0] += 1
        }
        return [
            "registryPresent": true,
            "registryVersion": registry.version,
            "instanceCount": registry.instances.count,
            "catalogCount": registry.catalog.count,
            "byHealthState": byState,
            "byKind": byKind,
            "fallbackStrategy": registry.fallbackPolicy.strategy.rawValue,
        ]
    }

    /// 最近 50 条路由决策的结局分布与转移率。
    private func routeDecisionSummary() -> [String: Any] {
        let traces = RouteDecisionLedger(fileURL: paths.routeDecisionsPath).recent(limit: 50)
        guard !traces.isEmpty else { return ["count": 0] }
        var byOutcome: [String: Int] = [:]
        for trace in traces {
            byOutcome[trace.outcome.rawValue, default: 0] += 1
        }
        return [
            "count": traces.count,
            "byOutcome": byOutcome,
            "failoverCount": traces.filter(\.didFailover).count,
        ]
    }

    private func fingerprint(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "absent" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
