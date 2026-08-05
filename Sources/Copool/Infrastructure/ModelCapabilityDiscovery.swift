import Foundation

/// Discovers what a third-party model can actually do, instead of assuming.
///
/// opencodex's rule, kept here: a model's reasoning levels and context window
/// come from the provider when it will say, from a registry of known models
/// when it will not, and only then from a conservative default. Hardcoding
/// three reasoning levels for every model advertises options the provider
/// rejects, and a fixed 200K window mis-sizes compaction on both ends.
struct ModelCapabilityDiscovery: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Refreshes metadata for every model of a provider.
    ///
    /// Returns the models unchanged when the provider cannot be reached — a
    /// transient network failure must not erase capabilities it confirmed
    /// earlier.
    func refresh(provider: ProviderConfig) async -> [ProviderModel] {
        let discovered = await fetchProviderMetadata(provider: provider)
        return provider.models.map { model in
            var updated = model
            if let entry = discovered[model.id.lowercased()] {
                apply(entry, to: &updated, source: .provider)
            }
            applyRegistryDefaults(to: &updated)
            return updated
        }
    }

    // MARK: - Provider metadata

    /// Queries the provider's model listing. Only OpenAI-compatible and
    /// Anthropic endpoints expose one in a shape worth parsing; Google's
    /// internal CloudCode listing is handled by the subscription importer.
    private func fetchProviderMetadata(provider: ProviderConfig) async -> [String: ModelMetadataEntry] {
        guard let url = modelsURL(for: provider) else { return [:] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        switch provider.defaultProtocol {
        case .anthropic:
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .chat, .responses, .google:
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        let entries = (json["data"] as? [Any]) ?? (json["models"] as? [Any]) ?? []
        var result: [String: ModelMetadataEntry] = [:]
        for raw in entries {
            guard let object = raw as? [String: Any] else { continue }
            let id = (object["id"] as? String) ?? (object["name"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            result[id.lowercased()] = Self.parse(object)
        }
        return result
    }

    private func modelsURL(for provider: ProviderConfig) -> URL? {
        guard var base = URL(string: provider.baseURL) else { return nil }
        // Anthropic exposes /v1/models; the OpenAI-compatible shape is
        // /models relative to the configured base.
        if provider.defaultProtocol == .anthropic {
            base = base.appendingPathComponent("v1")
        }
        return base.appendingPathComponent("models")
    }

    /// Reads the capability fields providers actually publish. Key names vary
    /// between vendors, so each is checked in turn.
    static func parse(_ object: [String: Any]) -> ModelMetadataEntry {
        var entry = ModelMetadataEntry()

        // Google's generativelanguage API names the input budget
        // `inputTokenLimit`; OpenAI-compatible vendors use the others.
        for key in ["context_window", "context_length", "max_context_length", "max_input_tokens", "inputTokenLimit", "input_token_limit"] {
            if let value = positiveInt(object[key]) {
                entry.contextWindow = value
                break
            }
        }
        // Some vendors nest the limits.
        if entry.contextWindow == nil {
            for container in ["limit", "limits", "capabilities"] {
                guard let nested = object[container] as? [String: Any] else { continue }
                for key in ["context", "context_window", "context_length", "input"] {
                    if let value = positiveInt(nested[key]) {
                        entry.contextWindow = value
                        break
                    }
                }
                if entry.contextWindow != nil { break }
            }
        }

        // An explicit `false` is a real answer: this model has no reasoning
        // picker at all, which is different from "not reported".
        if let reasoning = object["reasoning"] as? Bool, !reasoning {
            entry.supportedReasoningEfforts = []
        }

        for key in ["supported_reasoning_levels", "supported_reasoning_efforts", "reasoning_efforts", "reasoning_options"] {
            guard let raw = object[key] as? [Any] else { continue }
            let levels = raw.compactMap { item -> String? in
                if let text = item as? String { return text }
                if let dictionary = item as? [String: Any] {
                    return (dictionary["effort"] as? String) ?? (dictionary["value"] as? String)
                }
                return nil
            }
            let normalized = levels
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            if !normalized.isEmpty {
                entry.supportedReasoningEfforts = Array(NSOrderedSet(array: normalized)) as? [String] ?? normalized
                break
            }
        }

        if let value = object["default_reasoning_level"] as? String {
            entry.defaultReasoningEffort = value.lowercased()
        } else if let nested = object["default_reasoning_level"] as? [String: Any],
                  let value = nested["effort"] as? String {
            entry.defaultReasoningEffort = value.lowercased()
        }

        return entry
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let number = value as? Int, number > 0 { return number }
        if let number = value as? Double, number > 0 { return Int(number) }
        if let text = value as? String, let number = Int(text), number > 0 { return number }
        return nil
    }

    private func apply(_ entry: ModelMetadataEntry, to model: inout ProviderModel, source: ModelMetadataSource) {
        if let contextWindow = entry.contextWindow,
           ProviderModel.shouldReplace(model.contextWindowSource, with: source) {
            model.contextWindow = contextWindow
            model.contextWindowSource = source
        }
        if let efforts = entry.supportedReasoningEfforts,
           ProviderModel.shouldReplace(model.reasoningSource, with: source) {
            model.supportedReasoningEfforts = efforts
            model.reasoningSource = source
            // A default outside the declared list would be rejected upstream.
            if let declared = entry.defaultReasoningEffort, efforts.contains(declared) {
                model.defaultReasoningEffort = declared
            } else if efforts.contains("medium") {
                model.defaultReasoningEffort = "medium"
            } else {
                model.defaultReasoningEffort = efforts.first
            }
        }
    }

    /// Fills gaps from the built-in registry of well-known model families.
    private func applyRegistryDefaults(to model: inout ProviderModel) {
        guard let entry = ModelCapabilityRegistry.lookup(model.id) else { return }
        apply(entry, to: &model, source: .registry)
    }
}

/// One model's discovered capabilities.
struct ModelMetadataEntry: Equatable, Sendable {
    var contextWindow: Int?
    var supportedReasoningEfforts: [String]?
    var defaultReasoningEffort: String?
}

/// Context windows for model families whose providers do not publish them.
///
/// Matched by prefix so version suffixes still resolve. Kept deliberately
/// small: this is a fallback for well-known families, not a substitute for
/// asking the provider.
enum ModelCapabilityRegistry {
    private static let entries: [(prefix: String, metadata: ModelMetadataEntry)] = [
        ("claude-opus-4", ModelMetadataEntry(contextWindow: 200_000)),
        ("claude-sonnet-4", ModelMetadataEntry(contextWindow: 200_000)),
        ("claude-haiku-4", ModelMetadataEntry(contextWindow: 200_000)),
        ("gemini-3", ModelMetadataEntry(contextWindow: 1_048_576)),
        ("gemini-2.5", ModelMetadataEntry(contextWindow: 1_048_576)),
        ("grok-4", ModelMetadataEntry(contextWindow: 256_000)),
        ("deepseek", ModelMetadataEntry(contextWindow: 128_000)),
        ("qwen", ModelMetadataEntry(contextWindow: 128_000)),
        ("kimi", ModelMetadataEntry(contextWindow: 256_000)),
        ("glm", ModelMetadataEntry(contextWindow: 128_000)),
        ("minimax", ModelMetadataEntry(contextWindow: 1_000_000)),
        ("gpt-oss", ModelMetadataEntry(contextWindow: 128_000)),
    ]

    static func lookup(_ modelID: String) -> ModelMetadataEntry? {
        let normalized = modelID.lowercased()
        // Longest prefix wins so `gemini-3` cannot shadow a more specific
        // entry added later.
        return entries
            .filter { normalized.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .metadata
    }
}
