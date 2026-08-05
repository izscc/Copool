import Foundation

/// A user-defined role that binds a task shape to a specific model.
///
/// Ported from opencodex's Agent Profile: the user names a capability
/// ("frontend refactor", "写测试"), points it at one model, and the router
/// picks it when a Codex subagent turn looks like that kind of work.
struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    /// Task categories this profile claims, matched exactly against a
    /// request's `task_type`.
    var taskTypes: [String]
    /// Free-form labels; also fed to the text-overlap match.
    var tags: [String]
    var modelRef: AgentModelRef?
    var reasoningEffort: String?
    /// Tools the profile can service. A request naming a tool this profile
    /// lacks disqualifies it outright.
    var tools: [String]
    /// Tried in order when this profile's own model is unavailable.
    var fallbackProfileIDs: [String]
    var subagentEnabled: Bool
    var enabled: Bool
    /// Tie-breaker added to the match score; may be negative.
    var priority: Int
    var updatedAt: Int64

    init(
        id: String = UUID().uuidString,
        name: String,
        summary: String = "",
        taskTypes: [String] = [],
        tags: [String] = [],
        modelRef: AgentModelRef? = nil,
        reasoningEffort: String? = nil,
        tools: [String] = [],
        fallbackProfileIDs: [String] = [],
        subagentEnabled: Bool = true,
        enabled: Bool = true,
        priority: Int = 0,
        updatedAt: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.taskTypes = taskTypes
        self.tags = tags
        self.modelRef = modelRef
        self.reasoningEffort = reasoningEffort
        self.tools = tools
        self.fallbackProfileIDs = fallbackProfileIDs
        self.subagentEnabled = subagentEnabled
        self.enabled = enabled
        self.priority = priority
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        taskTypes = try container.decodeIfPresent([String].self, forKey: .taskTypes) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        modelRef = try container.decodeIfPresent(AgentModelRef.self, forKey: .modelRef)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        fallbackProfileIDs = try container.decodeIfPresent([String].self, forKey: .fallbackProfileIDs) ?? []
        subagentEnabled = try container.decodeIfPresent(Bool.self, forKey: .subagentEnabled) ?? true
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }

    /// A profile can only be routed to when it names a model.
    var isRoutable: Bool {
        enabled && modelRef != nil && !(modelRef?.backendModel.isEmpty ?? true)
    }
}

/// Points a profile at one catalog entry.
///
/// `catalogSlug` is what Codex asks for; `backendModel` is what the provider
/// expects. Keeping both means a profile survives a provider renaming its
/// display slug.
struct AgentModelRef: Codable, Equatable, Sendable {
    var provider: String
    var backendModel: String
    var catalogSlug: String?

    init(provider: String, backendModel: String, catalogSlug: String? = nil) {
        self.provider = provider
        self.backendModel = backendModel
        self.catalogSlug = catalogSlug
    }
}

/// How aggressively the router may redirect subagent turns.
enum AgentRoutingMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Never redirect; children inherit the parent model.
    case off
    /// Score profiles against each task and pick the best match.
    case auto
    /// Send every child to one pinned profile or model.
    case forced
}

struct AgentRoutingSettings: Codable, Equatable, Sendable {
    var mode: AgentRoutingMode
    var defaultProfileID: String?
    var forcedProfileID: String?
    var forcedModel: String?
    /// When a request names a `task_type` that nothing matches, fail instead
    /// of falling back to the default profile.
    var strictMatching: Bool

    static let defaultValue = AgentRoutingSettings(
        mode: .off,
        defaultProfileID: nil,
        forcedProfileID: nil,
        forcedModel: nil,
        strictMatching: false
    )

    init(
        mode: AgentRoutingMode = .off,
        defaultProfileID: String? = nil,
        forcedProfileID: String? = nil,
        forcedModel: String? = nil,
        strictMatching: Bool = false
    ) {
        self.mode = mode
        self.defaultProfileID = defaultProfileID
        self.forcedProfileID = forcedProfileID
        self.forcedModel = forcedModel
        self.strictMatching = strictMatching
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AgentRoutingMode.self, forKey: .mode) ?? .off
        defaultProfileID = try container.decodeIfPresent(String.self, forKey: .defaultProfileID)
        forcedProfileID = try container.decodeIfPresent(String.self, forKey: .forcedProfileID)
        forcedModel = try container.decodeIfPresent(String.self, forKey: .forcedModel)
        strictMatching = try container.decodeIfPresent(Bool.self, forKey: .strictMatching) ?? false
    }
}

/// Persisted agent configuration.
struct AgentProfileStore: Codable, Equatable, Sendable {
    var version: Int
    var profiles: [AgentProfile]
    var settings: AgentRoutingSettings

    static let currentVersion = 1

    init(
        version: Int = AgentProfileStore.currentVersion,
        profiles: [AgentProfile] = [],
        settings: AgentRoutingSettings = .defaultValue
    ) {
        self.version = version
        self.profiles = profiles
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AgentProfileStore.currentVersion
        profiles = try container.decodeIfPresent([AgentProfile].self, forKey: .profiles) ?? []
        settings = try container.decodeIfPresent(AgentRoutingSettings.self, forKey: .settings) ?? .defaultValue
    }

    mutating func upsert(_ profile: AgentProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Removes a profile and any routing setting or fallback chain that
    /// pointed at it, so no dangling reference can silently disable routing.
    mutating func remove(id: String) {
        profiles.removeAll { $0.id == id }
        for index in profiles.indices {
            profiles[index].fallbackProfileIDs.removeAll { $0 == id }
        }
        if settings.defaultProfileID == id { settings.defaultProfileID = nil }
        if settings.forcedProfileID == id { settings.forcedProfileID = nil }
    }
}

/// One routing decision, kept for the Agents page's activity list.
struct AgentRouteEvent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var at: Int64
    var taskID: String?
    /// Codex session display name resolved from session_index.jsonl, when the
    /// thread belongs to a named session.
    var sessionName: String?
    var profileID: String?
    var profileName: String?
    var model: String?
    var reasoningEffort: String?
    var resolved: Bool
    var reason: String

    init(
        id: String = UUID().uuidString,
        at: Int64,
        taskID: String? = nil,
        sessionName: String? = nil,
        profileID: String? = nil,
        profileName: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        resolved: Bool,
        reason: String
    ) {
        self.id = id
        self.at = at
        self.taskID = taskID
        self.profileID = profileID
        self.profileName = profileName
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.resolved = resolved
        self.reason = reason
        self.sessionName = sessionName
    }
}

struct AgentRouteEventStore: Codable, Equatable, Sendable {
    var version: Int
    var events: [AgentRouteEvent]

    static let currentVersion = 1
    /// Bound the log so a long-running proxy cannot grow it without limit.
    static let maxEvents = 200

    init(version: Int = AgentRouteEventStore.currentVersion, events: [AgentRouteEvent] = []) {
        self.version = version
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AgentRouteEventStore.currentVersion
        events = try container.decodeIfPresent([AgentRouteEvent].self, forKey: .events) ?? []
    }

    mutating func append(_ event: AgentRouteEvent) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }
}
