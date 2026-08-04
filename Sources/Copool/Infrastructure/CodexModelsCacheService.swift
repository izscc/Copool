import Foundation

/// Writes the third-party model catalog for Codex Desktop and points
/// `~/.codex/config.toml` at it via `model_catalog_json`.
///
/// Codex owns `models_cache.json` (server-fetched, refreshed frequently), so
/// injecting into it is unreliable — Codex overwrites it. The supported
/// mechanism is a custom catalog file referenced by `model_catalog_json` in
/// config.toml; Codex merges those entries into the model menu.
struct CodexModelsCacheService {
    private let fileManager: FileManager
    private let paths: FileSystemPaths

    /// Custom catalog file that Codex reads via `model_catalog_json`.
    var customCatalogPath: URL {
        paths.codexModelsCachePath
            .deletingLastPathComponent()
            .appendingPathComponent("custom_model_catalog.json", isDirectory: false)
    }

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    // MARK: - Catalog file access

    /// Reads the current custom catalog entries (empty when absent).
    func readCustomCatalog() throws -> [JSONValue] {
        let path = customCatalogPath
        guard fileManager.fileExists(atPath: path.path) else { return [] }

        let data = try Data(contentsOf: path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { try? JSONValue.from(any: $0) }
    }

    func writeCustomCatalog(_ models: [JSONValue]) throws {
        let directory = customCatalogPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let object: [String: Any] = ["models": models.map { $0.toAny() }]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: customCatalogPath, options: .atomic)
    }

    // MARK: - config.toml

    /// Points Codex at the custom catalog by setting `model_catalog_json` in
    /// `~/.codex/config.toml`. Preserves all other settings; replaces an
    /// existing managed value only when it points at our catalog.
    func setModelCatalogInConfig() throws {
        let configPath = paths.codexConfigPath
        guard fileManager.fileExists(atPath: configPath.path) else { return }

        var text = try String(contentsOf: configPath, encoding: .utf8)
        let catalogLine = "model_catalog_json = \"\(customCatalogPath.path)\""

        let managedValue = "\"\(customCatalogPath.path)\""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var foundManaged = false
        var insertIndex = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("model_catalog_json") else { continue }
            if trimmed.contains(managedValue) {
                foundManaged = true
                insertIndex = index
                break
            }
            // A different model_catalog_json value exists; leave it untouched.
            return
        }

        if foundManaged {
            lines[insertIndex] = catalogLine
        } else {
            lines.insert(catalogLine, at: 0)
        }

        text = lines.joined(separator: "\n")
        try text.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Merging

    /// True when the entry is a native Codex/OpenAI model that must be preserved as-is.
    static func isNativeModel(_ model: JSONValue) -> Bool {
        guard case .object(let dict) = model else { return false }
        let slug = (dict["slug"]?.stringValue ?? dict["model"]?.stringValue ?? "")
            .lowercased()
        let provider = (dict["provider"]?.stringValue ?? dict["model_provider"]?.stringValue ?? "")
            .lowercased()
        if provider == "openai" { return true }
        if slug.isEmpty { return false }
        return slug.hasPrefix("gpt-") || slug.hasPrefix("o1") || slug.hasPrefix("o3")
            || slug.hasPrefix("codex-") || slug.hasPrefix("chatgpt")
    }

    /// Builds a Codex-compatible catalog entry for a third-party model.
    ///
    /// Aligned with opencodex: the slug is the plain backend model id (no
    /// provider prefix), and provider is a neutral marker (`opencodex`).
    /// Prefixing the slug (`antigravity/gemini-3.6-flash`) makes ChatGPT.app
    /// truncate it to `agy/...` and reject the model as unsupported.
    static func catalogEntry(providerName: String, clientModelID: String, backendModel: String, protocol: ProviderProtocol) -> JSONValue {
        let contextWindow = 200_000
        var entry: [String: Any] = [
            "slug": backendModel,
            "model": backendModel,
            "display_name": clientModelID,
            "backend_model": backendModel,
            "backend_provider": providerName,
            "protocol": `protocol` == .responses ? "responses" : "chat",
            "backend_protocol": `protocol` == .responses ? "responses" : "chat",
            "provider": "opencodex",
            "model_provider": "opencodex",
            "description": "\(providerName): \(backendModel) via Copool",
            "context_window": contextWindow,
            "max_context_window": contextWindow,
            "auto_compact_token_limit": Int(Double(contextWindow) * 0.8),
            "truncation_policy": ["mode": "tokens", "limit": Int(Double(contextWindow) * 0.2)],
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Minimal reasoning for simple tasks"],
                ["effort": "medium", "description": "Balances speed and reasoning depth"],
                ["effort": "high", "description": "Greater reasoning depth for complex problems"],
            ],
            "default_reasoning_level": "medium",
            "default_reasoning_summary": "none",
            "reasoning_summary_format": "none",
            "supports_reasoning_summaries": true,
            "default_verbosity": "low",
            "support_verbosity": false,
            "apply_patch_tool_type": "freeform",
            "web_search_tool_type": "text_and_image",
            "supports_search_tool": false,
            "supports_parallel_tool_calls": true,
            "input_modalities": ["text", "image"],
            "supports_image_detail_original": true,
            "shell_type": "shell_command",
            "visibility": "list",
            "minimal_client_version": "0.0.1",
            "supported_in_api": true,
            "upgrade": NSNull(),
            "priority": 100,
            "prefer_websockets": false,
            "supports_websockets": false,
            "available_in_plans": ["free", "plus", "pro", "team", "business", "enterprise"],
            "base_instructions": "You are a helpful AI coding assistant in Codex.",
            "supports_computer_use": false,
            "supports_mcp": false,
            "experimental_supported_tools": ["mcp"],
        ]
        if `protocol` == .responses {
            entry["supports_reasoning_summaries"] = false
            entry["reasoning_summary_format"] = NSNull()
        }
        var converted: [String: JSONValue] = [:]
        for (key, value) in entry {
            if let jsonValue = try? JSONValue.from(any: value) {
                converted[key] = jsonValue
            }
        }
        return JSONValue.object(converted)
    }

    /// Builds the catalog entries for the configured providers.
    func catalogEntries(providers: [ProviderConfig]) -> [JSONValue] {
        providers.flatMap { provider in
            provider.clientModels.map { clientID, backendID in
                Self.catalogEntry(
                    providerName: provider.name,
                    clientModelID: clientID,
                    backendModel: backendID,
                    protocol: provider.resolvedProtocol(forModel: backendID)
                )
            }
        }
    }

    /// True when the entry is a native Codex/OpenAI model that must be
    /// preserved in models_cache.json. Third-party entries (any provider
    /// marker) are rebuilt from the catalog on every sync.
    static func isNativeCacheEntry(_ model: JSONValue) -> Bool {
        guard case .object(let dict) = model else { return false }
        let slug = (dict["slug"]?.stringValue ?? dict["model"]?.stringValue ?? "")
            .lowercased()
        let provider = (dict["provider"]?.stringValue ?? dict["model_provider"]?.stringValue ?? "")
            .lowercased()
        if provider == "openai" { return true }
        if slug.isEmpty { return false }
        return slug.hasPrefix("gpt-") || slug.hasPrefix("o1") || slug.hasPrefix("o3")
            || slug.hasPrefix("codex-") || slug.hasPrefix("chatgpt")
    }

    /// Reads Codex's own models_cache.json (server-fetched; native entries).
    func readModelsCache() throws -> [JSONValue] {
        let path = paths.codexModelsCachePath
        guard fileManager.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { try? JSONValue.from(any: $0) }
    }

    /// Rewrites models_cache.json keeping native entries and appending the
    /// third-party catalog. This is the file ChatGPT.app's model menu reads.
    ///
    /// Stale third-party entries from previous runs (e.g. `agy/...` or
    /// provider-prefixed slugs) are dropped so they never reach the menu.
    func mergeCatalogIntoModelsCache(providers: [ProviderConfig]) throws {
        let nativeModels = try readModelsCache()
        let thirdParty = catalogEntries(providers: providers)
        var merged = nativeModels.filter { Self.isNativeCacheEntry($0) }
        let existingSlugs = Set(merged.compactMap { $0.objectValue?["slug"]?.stringValue })
        for entry in thirdParty {
            let slug = entry.objectValue?["slug"]?.stringValue
            if let slug, !existingSlugs.contains(slug) {
                merged.append(entry)
            }
        }

        let directory = paths.codexModelsCachePath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = ["models": merged.map { $0.toAny() }]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.codexModelsCachePath, options: .atomic)
    }

    /// Full sync: writes the custom catalog (native models from models_cache
    /// merged with third-party entries), points config.toml at it, and merges
    /// entries into models_cache.json for the desktop model menu.
    ///
    /// opencodex does the same: the custom catalog must include the official
    /// models (from `codex debug models` / models_cache.json) or ChatGPT.app
    /// shows only the third-party entries when `model_catalog_json` is set.
    func sync(providers: [ProviderConfig]) throws -> [JSONValue] {
        let thirdParty = catalogEntries(providers: providers)

        // Native models come from Codex's own server-fetched cache; keep them
        // so the desktop model menu still shows gpt-5.x / o-series models.
        let nativeModels = (try? readModelsCache()) ?? []
        var merged = nativeModels.filter { Self.isNativeModel($0) }
        let existingSlugs = Set(merged.compactMap { $0.objectValue?["slug"]?.stringValue })
        for entry in thirdParty {
            let slug = entry.objectValue?["slug"]?.stringValue
            if let slug, !existingSlugs.contains(slug) {
                merged.append(entry)
            }
        }

        try writeCustomCatalog(merged)
        try setModelCatalogInConfig()
        try mergeCatalogIntoModelsCache(providers: providers)
        return thirdParty
    }
}
