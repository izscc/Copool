import Foundation

/// One diagnostic check result.
struct DoctorCheck: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let passed: Bool
    let message: String?

    init(id: String, name: String, passed: Bool, message: String? = nil) {
        self.id = id
        self.name = name
        self.passed = passed
        self.message = message
    }
}

/// One-shot environment diagnosis (codex-router's `doctor` checks, adapted to
/// this app's own plumbing). Read-only: it reports, it never repairs.
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

        // 1. Local proxy health.
        let healthy = await healthProbe()
        checks.append(
            DoctorCheck(
                id: "proxy.health",
                name: "Proxy health",
                passed: healthy,
                message: healthy ? nil : "No response on 127.0.0.1:8787/health"
            )
        )

        // 2. Codex config points at the local provider.
        let configText = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        let hasProvider = configText?.contains("model_provider") == true
            && configText?.contains("opencodex") == true
        checks.append(
            DoctorCheck(
                id: "codex.config",
                name: "Codex config",
                passed: hasProvider,
                message: hasProvider ? nil : "config.toml does not route through the local provider"
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
                passed: hasThirdParty,
                message: hasThirdParty
                    ? nil
                    : "\(missingFromCache.count) configured model(s) missing from models_cache.json"
            )
        )

        // 4. Provider store parses.
        let providers = try? ProviderFileRepository(paths: paths).loadProviders()
        checks.append(
            DoctorCheck(
                id: "providers.store",
                name: "Provider store",
                passed: providers != nil,
                message: providers == nil ? "providers.json failed to parse" : "\(providers?.providers.count ?? 0) provider(s) configured"
            )
        )

        // 5. Codex auth present.
        let authExists = FileManager.default.fileExists(atPath: paths.codexAuthPath.path)
        checks.append(
            DoctorCheck(
                id: "codex.auth",
                name: "Codex auth",
                passed: authExists,
                message: authExists ? nil : "auth.json missing — native models may be unavailable"
            )
        )

        // 6. Private file permissions (providers.json).
        let permsOK = (try? FileManager.default.attributesOfItem(atPath: paths.providerStorePath.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
            .map { $0.intValue & 0o777 == 0o600 } == true
        checks.append(
            DoctorCheck(
                id: "providers.permissions",
                name: "Provider store permissions",
                passed: permsOK,
                message: permsOK ? nil : "providers.json is not 0600"
            )
        )

        // 7. Usage ledger is writable (best-effort; missing ledger is fine).
        let ledgerWritable = FileManager.default.isWritableFile(atPath: paths.usageEventsPath.path)
            || !FileManager.default.fileExists(atPath: paths.usageEventsPath.path)
        checks.append(
            DoctorCheck(
                id: "usage.ledger",
                name: "Usage ledger",
                passed: ledgerWritable,
                message: ledgerWritable ? nil : "usage-events.jsonl is not writable"
            )
        )

        return checks
    }
}
