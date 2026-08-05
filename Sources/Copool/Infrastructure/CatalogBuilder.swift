import Foundation

/// Builds the credential-aware model catalog (AC-011).
///
/// Availability rules:
///   - An instance without a resolvable credential never enters the default
///     catalog (missing keys are not shown as pickable models).
///   - Metadata provenance rides along (provider > live > registry >
///     fallback) so the UI can show where numbers came from.
///   - The registry layer is data-driven: live discovery (listModelIDs +
///     capability refresh) updates entries; curation adds user picks.
struct CatalogBuilder: Sendable {
    /// One catalog row ready for pickers, with provenance.
    struct CatalogRow: Equatable, Sendable, Identifiable {
        var entry: ModelCatalogEntry
        var instance: ProviderInstance
        var credentialResolved: Bool
        var metadataSource: MetadataSource

        var id: String { entry.id }
    }

    /// Builds the default (pickable) catalog: only entries whose instance has
    /// a credential. Returns rows plus the count of hidden entries (missing
    /// credentials / disabled instances) so callers can surface "N hidden".
    func buildDefaultCatalog(
        registry: ProviderRegistryV2,
        credentialResolved: (String) -> Bool
    ) -> (rows: [CatalogRow], hiddenCount: Int) {
        var rows: [CatalogRow] = []
        var hidden = 0

        for entry in registry.catalog {
            guard let instance = registry.instance(id: entry.providerInstanceID) else {
                hidden += 1
                continue
            }
            guard instance.enabled else {
                hidden += 1
                continue
            }
            let resolved = credentialResolved(instance.credentialID)
            guard resolved else {
                hidden += 1
                continue
            }
            let source = entry.metadataSources["contextWindow"] ?? .fallback
            rows.append(
                CatalogRow(
                    entry: entry,
                    instance: instance,
                    credentialResolved: true,
                    metadataSource: source
                )
            )
        }
        return (rows, hidden)
    }

    /// Merges live-discovered model ids into an instance's catalog entries,
    /// keeping curated entries and applying provenance priority
    /// (provider replaces registry, registry replaces fallback).
    func mergeLiveDiscovery(
        registry: ProviderRegistryV2,
        instanceID: String,
        liveModelIDs: [String],
        liveCapabilities: [String: ModelCapabilitiesV2]
    ) -> ProviderRegistryV2 {
        var result = registry
        let existing = Set(result.catalog.filter { $0.providerInstanceID == instanceID }.map(\.backendModelID))

        // Add live models not yet catalogued (visibility .visible, source
        // .provider when capabilities were actually returned).
        for modelID in liveModelIDs where !existing.contains(modelID) {
            let capabilities = liveCapabilities[modelID] ?? ModelCapabilitiesV2()
            let hasProviderData = liveCapabilities[modelID] != nil
            result.catalog.append(
                ModelCatalogEntry(
                    providerInstanceID: instanceID,
                    backendModelID: modelID,
                    displayName: modelID,
                    capabilities: capabilities,
                    metadataSources: hasProviderData ? ["contextWindow": .provider] : ["contextWindow": .registry],
                    visibility: .visible
                )
            )
        }

        // Upgrade provenance of existing entries when live data is richer.
        for index in result.catalog.indices where result.catalog[index].providerInstanceID == instanceID {
            guard let live = liveCapabilities[result.catalog[index].backendModelID] else { continue }
            var entry = result.catalog[index]
            if live.contextWindow != nil {
                entry.capabilities.contextWindow = live.contextWindow
                entry.metadataSources["contextWindow"] = .provider
            }
            if live.supportedReasoningEfforts != nil {
                entry.capabilities.supportedReasoningEfforts = live.supportedReasoningEfforts
                entry.metadataSources["reasoning"] = .provider
            }
            result.catalog[index] = entry
        }
        return result
    }
}
