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

    enum Status: String, Codable, Equatable, Sendable {
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
        let required: VoiceCapability = kind == .codingExecution ? .realtime : .realtime
        guard plugin.capabilities.contains(required) else { return nil }
        return RealtimeSession(
            id: UUID().uuidString,
            kind: kind,
            startedAt: now(),
            pluginID: pluginID,
            cancelled: false,
            transcriptCount: 0
        )
    }
}
