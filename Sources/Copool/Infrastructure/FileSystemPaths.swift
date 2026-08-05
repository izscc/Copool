import Foundation

struct FileSystemPaths {
    var applicationSupportDirectory: URL
    var accountStorePath: URL
    var settingsStorePath: URL
    var providerStorePath: URL
    var registryV2Path: URL
    var migrationJournalPath: URL
    var thirdPartyUsagePath: URL
    var providerRateLimitsPath: URL
    var usageEventsPath: URL
    var routeDecisionsPath: URL
    var agentStorePath: URL
    var agentRouteEventsPath: URL
    var codexAuthPath: URL
    var codexConfigPath: URL
    var codexModelsCachePath: URL
    var proxyDaemonDataDirectory: URL
    var proxyDaemonKeyPath: URL
    var cloudflaredLogDirectory: URL

    static func live(fileManager: FileManager = .default) throws -> FileSystemPaths {
        let appSupportBase = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appSupportDirectory = appSupportBase.appendingPathComponent("CodexToolsSwift", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let proxyDaemonDataDirectory = homeDirectory.appendingPathComponent(".codex-tools-proxyd", isDirectory: true)
        let cloudflaredLogDirectory = appSupportDirectory.appendingPathComponent("cloudflared-logs", isDirectory: true)

        return FileSystemPaths(
            applicationSupportDirectory: appSupportDirectory,
            accountStorePath: appSupportDirectory.appendingPathComponent("accounts.json", isDirectory: false),
            settingsStorePath: appSupportDirectory.appendingPathComponent("settings.json", isDirectory: false),
            providerStorePath: appSupportDirectory.appendingPathComponent("providers.json", isDirectory: false),
            registryV2Path: appSupportDirectory.appendingPathComponent("provider-registry-v2.json", isDirectory: false),
            migrationJournalPath: appSupportDirectory.appendingPathComponent("migration-journal.json", isDirectory: false),
            thirdPartyUsagePath: appSupportDirectory.appendingPathComponent("third-party-usage.json", isDirectory: false),
            providerRateLimitsPath: appSupportDirectory.appendingPathComponent("provider-rate-limits.json", isDirectory: false),
            usageEventsPath: appSupportDirectory.appendingPathComponent("usage-events.jsonl", isDirectory: false),
            routeDecisionsPath: appSupportDirectory.appendingPathComponent("route-decisions.jsonl", isDirectory: false),
            agentStorePath: appSupportDirectory.appendingPathComponent("agents.json", isDirectory: false),
            agentRouteEventsPath: appSupportDirectory.appendingPathComponent("agent-routes.json", isDirectory: false),
            codexAuthPath: codexDirectory.appendingPathComponent("auth.json", isDirectory: false),
            codexConfigPath: codexDirectory.appendingPathComponent("config.toml", isDirectory: false),
            codexModelsCachePath: codexDirectory.appendingPathComponent("models_cache.json", isDirectory: false),
            proxyDaemonDataDirectory: proxyDaemonDataDirectory,
            proxyDaemonKeyPath: proxyDaemonDataDirectory.appendingPathComponent("api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: cloudflaredLogDirectory
        )
    }
}
