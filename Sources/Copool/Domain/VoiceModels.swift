import Foundation

// MARK: - Voice & Realtime domain (Phase 8)
//
// Pluginized by design: nothing loads, nothing asks for permissions, and no
// audio engine is touched until a plugin is explicitly enabled (AC-201).
// Recordings are ephemeral by default and cancelled explicitly (AC-202).

/// Voice capability kinds.
enum VoiceCapability: String, Codable, Equatable, Sendable, CaseIterable {
    case stt
    case tts
    case vad
    case realtime
}

/// Plugin configuration — enabling a plugin is the ONLY trigger for loading
/// its implementation or requesting permissions.
struct VoicePluginConfig: Codable, Equatable, Sendable {
    var pluginID: String
    var enabled: Bool
    var capabilities: Set<VoiceCapability>
    /// True when the plugin may transcribe/persist audio; off by default
    /// (privacy: 默认不持久化).
    var mayPersistAudio: Bool
}

/// Lifecycle of one voice session.
enum VoiceSessionState: Equatable, Sendable {
    case idle
    case listening
    case processing
    case speaking
    case cancelled
    case failed(String)
}

/// One user utterance captured by a VAD/STT plugin.
struct Utterance: Equatable, Sendable {
    var transcript: String
    var confidence: Double?
    var durationMs: Int
    var isFinal: Bool
}

/// A TTS request (synthesized audio is never persisted by default).
struct SpeechSynthesisRequest: Equatable, Sendable {
    var text: String
    var voiceID: String?
    var speed: Double?
}

/// Plugin contract. Implementations only exist when the plugin is enabled;
/// the manager never instantiates a disabled plugin.
protocol VoicePlugin: Sendable {
    var pluginID: String { get }
    var capabilities: Set<VoiceCapability> { get }

    /// Asks the OS for permissions ONLY when called (post-enablement).
    func requestPermissions() async -> Bool
    func transcribe(audioURL: URL?) async throws -> Utterance
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> Data
}

protocol RealtimeTransport: Sendable {
    func connect(session: RealtimeSession) async throws
    func send(text: String, session: RealtimeSession) async throws
    func receive(session: RealtimeSession) async throws -> AsyncThrowingStream<String, Error>
    func close(session: RealtimeSession) async
}

/// Deterministic transport used by the app's plugin boundary and tests. A
/// production audio provider can implement the same protocol without changing
/// session or confirmation semantics.
actor InMemoryRealtimeTransport: RealtimeTransport {
    private var messages: [String: [String]] = [:]

    func connect(session: RealtimeSession) async throws {
        messages[session.id] = []
    }

    func send(text: String, session: RealtimeSession) async throws {
        guard !session.cancelled else { return }
        messages[session.id, default: []].append(text)
    }

    func receive(session: RealtimeSession) async throws -> AsyncThrowingStream<String, Error> {
        let buffered = messages[session.id, default: []]
        return AsyncThrowingStream { continuation in
            buffered.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func close(session: RealtimeSession) async {
        messages.removeValue(forKey: session.id)
    }
}

// MARK: - Realtime separation (AC-202)

/// Realtime sessions are split by purpose: a conversation session can never
/// touch coding execution state, and vice versa.
enum RealtimeSessionKind: String, Codable, Equatable, Sendable {
    case conversation
    case codingExecution
}

/// One realtime session.
struct RealtimeSession: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: RealtimeSessionKind
    var startedAt: Int64
    var pluginID: String
    /// Set when the session was cancelled; audio is discarded.
    var cancelled: Bool
    var transcriptCount: Int
}

/// A unit of delegated work from a realtime session. MUST be confirmed by the
/// user before any execution side effect happens (AC-203: TaskEnvelope 必须
/// 用户确认后执行).
struct TaskEnvelope: Codable, Equatable, Sendable, Identifiable {
    // Codable with a custom Status encoding (case name + optional detail).
    enum CodingKeys: String, CodingKey {
        case id, sessionID, kind, intent, payloadRef, userConfirmed, status, statusDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(RealtimeSessionKind.self, forKey: .kind)
        intent = try container.decode(String.self, forKey: .intent)
        payloadRef = try container.decodeIfPresent(String.self, forKey: .payloadRef)
        userConfirmed = try container.decode(Bool.self, forKey: .userConfirmed)
        switch try container.decode(String.self, forKey: .status) {
        case "pending": status = .pending
        case "confirmed": status = .confirmed
        case "rejected": status = .rejected
        case "executing": status = .executing
        case "completed": status = .completed
        case "failed":
            status = .failed((try? container.decode(String.self, forKey: .statusDetail)) ?? "")
        default: status = .pending
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        try container.encode(intent, forKey: .intent)
        try container.encodeIfPresent(payloadRef, forKey: .payloadRef)
        try container.encode(userConfirmed, forKey: .userConfirmed)
        switch status {
        case .pending: try container.encode("pending", forKey: .status)
        case .confirmed: try container.encode("confirmed", forKey: .status)
        case .rejected: try container.encode("rejected", forKey: .status)
        case .executing: try container.encode("executing", forKey: .status)
        case .completed: try container.encode("completed", forKey: .status)
        case .failed(let detail):
            try container.encode("failed", forKey: .status)
            try container.encode(detail, forKey: .statusDetail)
        }
    }
    var id: String
    var sessionID: String
    var kind: RealtimeSessionKind
    /// The requested action, as understood by the delegation layer.
    var intent: String
    /// Optional payload reference (never inline secrets).
    var payloadRef: String?
    /// User confirmation gate.
    var userConfirmed: Bool
    var status: Status

    enum Status: Equatable, Sendable {
        case pending
        case confirmed
        case rejected
        case executing
        case completed
        case failed(String)
    }

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        kind: RealtimeSessionKind,
        intent: String,
        payloadRef: String? = nil,
        userConfirmed: Bool = false,
        status: Status = .pending
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.intent = intent
        self.payloadRef = payloadRef
        self.userConfirmed = userConfirmed
        self.status = status
    }

    /// Confirms (or rejects) the envelope. Execution is only reachable
    /// through a confirmed envelope.
    mutating func confirm() {
        userConfirmed = true
        status = .confirmed
    }

    mutating func reject() {
        userConfirmed = false
        status = .rejected
    }
}

// MARK: - Manager (permission gate)

/// Coordinates voice plugins and realtime sessions. Never touches plugins,
/// permissions or audio until enablement (AC-201).
struct RealtimeSessionManager: Sendable {
    var enabledPlugins: [VoicePluginConfig]
    var now: @Sendable () -> Int64

    init(enabledPlugins: [VoicePluginConfig], now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.enabledPlugins = enabledPlugins
        self.now = now
    }

    /// True when a plugin with the capability is enabled — the only condition
    /// under which the app may request permissions or load audio services.
    func isCapabilityEnabled(_ capability: VoiceCapability) -> Bool {
        enabledPlugins.contains { $0.enabled && $0.capabilities.contains(capability) }
    }

    func isRealtimeEnabled() -> Bool {
        isCapabilityEnabled(.realtime)
    }

    /// Creates a session only when the plugin is enabled and the capability
    /// requested matches the plugin's declared set.
    func createSession(kind: RealtimeSessionKind, pluginID: String) -> RealtimeSession? {
        guard let plugin = enabledPlugins.first(where: { $0.pluginID == pluginID && $0.enabled }) else {
            return nil
        }
        guard plugin.capabilities.contains(.realtime) else { return nil }
        return RealtimeSession(
            id: UUID().uuidString,
            kind: kind,
            startedAt: now(),
            pluginID: pluginID,
            cancelled: false,
            transcriptCount: 0
        )
    }

    /// Cancellation is terminal and discards any in-memory transcript count;
    /// no audio persistence path exists in the domain manager.
    func cancel(_ session: RealtimeSession) -> RealtimeSession {
        var cancelled = session
        cancelled.cancelled = true
        cancelled.transcriptCount = 0
        return cancelled
    }

    func makeTransport(for session: RealtimeSession) -> (any RealtimeTransport)? {
        guard isRealtimeEnabled(),
              enabledPlugins.contains(where: { $0.pluginID == session.pluginID && $0.enabled }) else {
            return nil
        }
        return InMemoryRealtimeTransport()
    }
}
