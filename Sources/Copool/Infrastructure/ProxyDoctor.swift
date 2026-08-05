import Foundation

/// Outcome severity for a doctor check (AC-014: layered PASS/WARN/FAIL).
enum DoctorSeverity: String, Codable, Equatable, Sendable {
    case pass
    case warn
    case fail
}

/// One diagnostic check result.
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
                name: "Proxy health",
                severity: healthy ? .pass : .fail,
                message: healthy ? nil : "No response on 127.0.0.1:8787/health"
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
                name: "Codex config",
                severity: hasProvider ? .pass : .warn,
                message: hasProvider ? nil : "config.toml does not route through the local provider (third-party models unavailable)"
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
                name: "Models cache",
                severity: hasThirdParty ? .pass : .warn,
                message: hasThirdParty
                    ? nil
                    : "\(missingFromCache.count) configured model(s) missing from models_cache.json"
            )
        )

        // 4. Provider store parses — corrupted data means no third-party
        // routing at all: fail.
        let providers = try? ProviderFileRepository(paths: paths).loadProviders()
        checks.append(
            DoctorCheck(
                id: "providers.store",
                name: "Provider store",
                severity: providers != nil ? .pass : .fail,
                message: providers == nil ? "providers.json failed to parse" : "\(providers?.providers.count ?? 0) provider(s) configured"
            )
        )

        // 5. Codex auth present — native models unavailable without it, but
        // third-party routing keeps working: warn.
        let authExists = FileManager.default.fileExists(atPath: paths.codexAuthPath.path)
        checks.append(
            DoctorCheck(
                id: "codex.auth",
                name: "Codex auth",
                severity: authExists ? .pass : .warn,
                message: authExists ? nil : "auth.json missing — native models may be unavailable"
            )
        )

        // 6. Private file permissions (providers.json) — security relevant: fail.
        let permsOK = (try? FileManager.default.attributesOfItem(atPath: paths.providerStorePath.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { $0.intValue & 0o777 == 0o600 } == true
        checks.append(
            DoctorCheck(
                id: "providers.permissions",
                name: "Provider store permissions",
                severity: permsOK ? .pass : .fail,
                message: permsOK ? nil : "providers.json is not 0600"
            )
        )

        // 7. Usage ledger is writable — auditing degraded only: warn.
        let ledgerWritable = FileManager.default.isWritableFile(atPath: paths.usageEventsPath.path)
            || !FileManager.default.fileExists(atPath: paths.usageEventsPath.path)
        checks.append(
            DoctorCheck(
                id: "usage.ledger",
                name: "Usage ledger",
                severity: ledgerWritable ? .pass : .warn,
                message: ledgerWritable ? nil : "usage-events.jsonl is not writable"
            )
        )

        return checks
    }
}
