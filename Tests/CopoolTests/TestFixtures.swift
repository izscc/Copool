import Foundation
@testable import Copool

// MARK: - FileSystemPaths test convenience

/// Test helper: most repository tests only need the paths they touch, so this
/// mirrors the pre-`6b7dbe6` memberwise shape and derives the newer paths
/// (provider store, usage ledger, agent stores, models cache) from the
/// application-support directory.
extension FileSystemPaths {
    init(
        applicationSupportDirectory: URL,
        accountStorePath: URL,
        settingsStorePath: URL,
        codexAuthPath: URL,
        codexConfigPath: URL,
        proxyDaemonDataDirectory: URL,
        proxyDaemonKeyPath: URL,
        cloudflaredLogDirectory: URL
    ) {
        let codexDirectory = codexAuthPath.deletingLastPathComponent()
        self.init(
            applicationSupportDirectory: applicationSupportDirectory,
            accountStorePath: accountStorePath,
            settingsStorePath: settingsStorePath,
            providerStorePath: applicationSupportDirectory.appendingPathComponent("providers.json", isDirectory: false),
            registryV2Path: applicationSupportDirectory.appendingPathComponent("provider-registry-v2.json", isDirectory: false),
            migrationJournalPath: applicationSupportDirectory.appendingPathComponent("migration-journal.json", isDirectory: false),
            thirdPartyUsagePath: applicationSupportDirectory.appendingPathComponent("third-party-usage.json", isDirectory: false),
            providerRateLimitsPath: applicationSupportDirectory.appendingPathComponent("provider-rate-limits.json", isDirectory: false),
            usageEventsPath: applicationSupportDirectory.appendingPathComponent("usage-events.jsonl", isDirectory: false),
            agentStorePath: applicationSupportDirectory.appendingPathComponent("agents.json", isDirectory: false),
            agentRouteEventsPath: applicationSupportDirectory.appendingPathComponent("agent-routes.json", isDirectory: false),
            codexAuthPath: codexAuthPath,
            codexConfigPath: codexConfigPath,
            codexModelsCachePath: codexDirectory.appendingPathComponent("models_cache.json", isDirectory: false),
            proxyDaemonDataDirectory: proxyDaemonDataDirectory,
            proxyDaemonKeyPath: proxyDaemonKeyPath,
            cloudflaredLogDirectory: cloudflaredLogDirectory
        )
    }
}
