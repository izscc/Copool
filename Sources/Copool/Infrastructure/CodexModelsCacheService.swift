import Foundation

/// Reads/writes Codex Desktop's model cache (`~/.codex/models_cache.json`) so
/// third-party models can appear in the ChatGPT.app model menu.
///
/// The cache is a JSON object `{ "models": [...] }` owned by Codex. We merge
/// third-party catalog entries in while preserving native entries, so a later
/// Codex-side refresh does not drop the injected models.
struct CodexModelsCacheService {
    private let fileManager: FileManager
    private let paths: FileSystemPaths

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    // MARK: - Cache file access

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

    func writeModelsCache(_ models: [JSONValue]) throws {
        let directory = paths.codexModelsCachePath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let object: [String: Any] = ["models": models.map { $0.toAny() }]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.codexModelsCachePath, options: .atomic)
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
    static func catalogEntry(providerName: String, clientModelID: String, backendModel: String, protocol: ProviderProtocol) -> JSONValue {
        let contextWindow = 200_000
        var entry: [String: Any] = [
            "slug": clientModelID,
            "model": clientModelID,
            "display_name": clientModelID,
            "backend_model": backendModel,
            "backend_provider": providerName,
            "protocol": `protocol` == .responses ? "responses" : "chat",
            "backend_protocol": `protocol` == .responses ? "responses" : "chat",
            "provider": "copool",
            "model_provider": "copool",
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
            "available_in_plans": ["free", "plus", "pro", "team", "business", "enterprise"],
            "base_instructions": "You are a helpful AI coding assistant in Codex.",
            "supports_computer_use": false,
            "supports_mcp": false,
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

    /// Preserves native entries and injects/updates third-party entries.
    /// Native entries are identified by provider == "openai" or slug prefix;
    /// third-party entries carry provider == "copool" and are rebuilt from the
    /// provider store so deletions/renames are reflected on the next sync.
    func mergedModelsCache(cacheModels: [JSONValue], providers: [ProviderConfig]) -> [JSONValue] {
        var result: [JSONValue] = []

        for model in cacheModels {
            if Self.isNativeModel(model) {
                result.append(model)
            } else if case .object(let dict) = model, (dict["provider"]?.stringValue ?? "") != "copool" {
                // Unknown/non-managed entries (e.g. other tools) are left untouched.
                result.append(model)
            }
            // copool-managed entries are dropped and rebuilt below.
        }

        for provider in providers {
            for (clientID, backendID) in provider.clientModels {
                result.append(
                    Self.catalogEntry(
                        providerName: provider.name,
                        clientModelID: clientID,
                        backendModel: backendID,
                        protocol: provider.resolvedProtocol(forModel: backendID)
                    )
                )
            }
        }

        return result
    }

    /// Rebuilds the cache file with the merged catalog. Returns the new model list.
    func sync(providers: [ProviderConfig]) throws -> [JSONValue] {
        let cacheModels = try readModelsCache()
        let merged = mergedModelsCache(cacheModels: cacheModels, providers: providers)
        try writeModelsCache(merged)
        return merged
    }
}
