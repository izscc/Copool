import Foundation

// MARK: - vNext registry domain (Phase 2)
//
// Clean split required by the PRD (docs/11_data_model.md):
//   ProviderDefinition (public, no secrets)
//   1---* ProviderInstance (user config) *---1 CredentialIdentity (ref only)
//   ProviderInstance 1---* ModelCatalogEntry (stable unique key)
//
// Invariants enforced by the type system:
//   - No secret value is Codable/Equatable/loggable: CredentialIdentity holds
//     only a SecureReference (keychain account / env var name).
//   - No ID derives from displayName (AC-005): instance ids are stable UUIDs
//     inherited from v1 and model entries key off instanceID + backendModelID.

/// API dialect spoken by a provider endpoint (maps to the legacy
/// `ProviderProtocol` values).
enum APIDialect: String, Codable, Equatable, Sendable, CaseIterable {
    case chat
    case responses
    case anthropic
    case google

    init(_ legacy: ProviderProtocol) {
        switch legacy {
        case .chat: self = .chat
        case .responses: self = .responses
        case .anthropic: self = .anthropic
        case .google: self = .google
        }
    }

    var legacy: ProviderProtocol {
        switch self {
        case .chat: return .chat
        case .responses: return .responses
        case .anthropic: return .anthropic
        case .google: return .google
        }
    }
}

/// How a provider authenticates (no values, only kinds).
enum CredentialKind: String, Codable, Equatable, Sendable, CaseIterable {
    case apiKey
    case oauth
    case subscriptionImport
}

/// Where a credential originally came from.
enum CredentialSource: String, Codable, Equatable, Sendable {
    case userEntered
    case importedFromApp
    case environment
    case keychainMigrated
}

/// Opaque reference to a stored secret. Never carries the value.
struct SecureReference: Codable, Equatable, Sendable {
    enum Storage: String, Codable, Equatable, Sendable {
        case keychainAccount
        case environmentVariable
    }

    var storage: Storage
    /// Keychain account name or environment variable name.
    var name: String
}

/// Public definition of a provider (registry entry, no user data).
struct ProviderDefinition: Codable, Equatable, Sendable, Identifiable {
    /// Stable id, e.g. "deepseek". Never derived from displayName.
    var id: String
    var displayName: String
    var ownership: String
    var supportedProtocols: Set<APIDialect>
    var defaultBaseURL: String
    var credentialKinds: Set<CredentialKind>
    var isBuiltIn: Bool
}

/// One provider's credential as stored (reference only — no value).
struct CredentialIdentity: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: CredentialKind
    var secureReference: SecureReference?
    var source: CredentialSource
    var scopes: [String]
    var expiresAt: Int64?
    var lastVerifiedAt: Int64?
}

/// Per-model capability facts with provenance.
struct ModelCapabilitiesV2: Codable, Equatable, Sendable {
    var contextWindow: Int?
    var supportedReasoningEfforts: [String]?
    var defaultReasoningEffort: String?
    var supportsVision: Bool?
}

/// Provenance per metadata field (provider > registry > fallback).
enum MetadataSource: String, Codable, Equatable, Sendable {
    case provider
    case registry
    case fallback

    init(_ legacy: ModelMetadataSource) {
        switch legacy {
        case .provider: self = .provider
        case .registry: self = .registry
        case .fallback: self = .fallback
        }
    }
}

/// How visible a model is in pickers.
enum ModelVisibility: String, Codable, Equatable, Sendable {
    case visible
    case hidden
    case curated
}

/// Stable catalog entry: unique key = providerInstanceID + backendModelID.
struct ModelCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    var providerInstanceID: String
    var backendModelID: String
    var displayName: String?
    var capabilities: ModelCapabilitiesV2
    var metadataSources: [String: MetadataSource]
    var visibility: ModelVisibility

    /// Stable unique key (AC-011): instance + backend model.
    var id: String { "\(providerInstanceID)/\(backendModelID)" }

    init(
        providerInstanceID: String,
        backendModelID: String,
        displayName: String? = nil,
        capabilities: ModelCapabilitiesV2 = ModelCapabilitiesV2(),
        metadataSources: [String: MetadataSource] = [:],
        visibility: ModelVisibility = .visible
    ) {
        self.providerInstanceID = providerInstanceID
        self.backendModelID = backendModelID
        self.displayName = displayName
        self.capabilities = capabilities
        self.metadataSources = metadataSources
        self.visibility = visibility
    }
}

/// User-configured provider channel (billable endpoint).
struct ProviderInstance: Codable, Equatable, Sendable, Identifiable {
    /// Stable route key (AC-005). v1 UUIDs are inherited as-is.
    var id: String
    var definitionID: String
    var displayName: String
    var endpoint: String
    var credentialID: String
    var protocolBindings: [String: APIDialect]
    var defaultProtocol: APIDialect
    var enabled: Bool
    var addedAt: Int64
}

/// Versioned v2 registry store (no secrets by construction).
struct ProviderRegistryV2: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var definitions: [ProviderDefinition]
    var instances: [ProviderInstance]
    var credentials: [CredentialIdentity]
    var catalog: [ModelCatalogEntry]
    /// Definitions the user overrode or added (user overlay layer).
    var userDefinitions: [ProviderDefinition]

    init(
        version: Int = ProviderRegistryV2.currentVersion,
        definitions: [ProviderDefinition] = [],
        instances: [ProviderInstance] = [],
        credentials: [CredentialIdentity] = [],
        catalog: [ModelCatalogEntry] = [],
        userDefinitions: [ProviderDefinition] = []
    ) {
        self.version = version
        self.definitions = definitions
        self.instances = instances
        self.credentials = credentials
        self.catalog = catalog
        self.userDefinitions = userDefinitions
    }

    func definition(id: String) -> ProviderDefinition? {
        definitions.first { $0.id == id } ?? userDefinitions.first { $0.id == id }
    }

    func instance(id: String) -> ProviderInstance? {
        instances.first { $0.id == id }
    }

    func credential(id: String) -> CredentialIdentity? {
        credentials.first { $0.id == id }
    }

    func catalogEntries(instanceID: String) -> [ModelCatalogEntry] {
        catalog.filter { $0.providerInstanceID == instanceID }
    }
}

// MARK: - Migration journal

/// One completed (or rolled back) v1→v2 migration step.
struct MigrationEntry: Codable, Equatable, Sendable {
    var journalID: String
    var migratedAt: Int64
    var fromVersion: Int
    var toVersion: Int
    /// Shadow writes land in a sidecar before the active store flips.
    var shadowed: Bool
    var verified: Bool
    var rolledBack: Bool?
    /// Fingerprint of the source (v1) store, for idempotence.
    var sourceHash: String
}

/// Append-only migration ledger (migration-journal.json).
struct MigrationJournal: Codable, Equatable, Sendable {
    var version: Int
    var entries: [MigrationEntry]

    static let currentVersion = 1

    init(version: Int = MigrationJournal.currentVersion, entries: [MigrationEntry] = []) {
        self.version = version
        self.entries = entries
    }

    func lastEntry(sourceHash: String) -> MigrationEntry? {
        entries.last { $0.sourceHash == sourceHash }
    }
}
