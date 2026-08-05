import Foundation

// MARK: - Canonical router types (Phase 3)
//
// The dialect-neutral request/event surface the router core speaks. Provider
// adapters translate to/from this; any lossy conversion must surface a
// warning event instead of silently dropping data (AC: "lossy conversion 有
// warning").

// MARK: Roles & content

enum CanonicalRole: String, Codable, Equatable, Sendable {
    case system
    case developer
    case user
    case assistant
    case tool
}

/// One inline image in a user message (data URI or remote URL).
struct CanonicalImage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case dataURI
        case remoteURL
    }

    var kind: Kind
    var value: String
    var mimeType: String?
}

/// A tool call inside an assistant message.
struct CanonicalToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

/// One message in canonical form. Fields that a dialect cannot represent are
/// recorded in `lossyFields` so the adapter can emit a warning event.
struct CanonicalMessage: Codable, Equatable, Sendable {
    var role: CanonicalRole
    var text: String?
    var images: [CanonicalImage]?
    var toolCalls: [CanonicalToolCall]?
    /// tool_call_id + output for a tool result message.
    var toolCallID: String?
    var toolOutput: String?
    var lossyFields: [String]

    init(
        role: CanonicalRole,
        text: String? = nil,
        images: [CanonicalImage]? = nil,
        toolCalls: [CanonicalToolCall]? = nil,
        toolCallID: String? = nil,
        toolOutput: String? = nil,
        lossyFields: [String] = []
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolOutput = toolOutput
        self.lossyFields = lossyFields
    }
}

// MARK: Request

/// One tool the model may call.
struct CanonicalTool: Codable, Equatable, Sendable {
    var name: String
    /// JSON-serialized parameter schema (bytes avoid `Any` in Sendable
    /// types; nil means "no declared schema").
    var schemaJSON: Data?

    init(name: String, schemaJSON: Data? = nil) {
        self.name = name
        self.schemaJSON = schemaJSON
    }

    /// Convenience: build from a JSON object.
    static func schema(from object: [String: Any]?) -> Data? {
        guard let object else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

/// Reasoning policy for a request.
struct CanonicalReasoningPolicy: Codable, Equatable, Sendable {
    var effort: String?
    var summary: String?
}

/// Dialect-neutral request. Every field the router core understands.
struct CanonicalRequest: Codable, Equatable, Sendable {
    var requestID: String
    var sessionID: String?
    var turnID: String?
    var model: String
    var messages: [CanonicalMessage]
    var tools: [CanonicalTool]?
    var toolChoice: String?
    var parallelToolCalls: Bool?
    var reasoning: CanonicalReasoningPolicy?
    var stream: Bool
    var temperature: Double?
    var maxTokens: Int?
    var contextBudgetTokens: Int?
    var timeoutSeconds: Int?
    var idempotencyKey: String?
    /// Fields the caller asked for that a dialect cannot express.
    var lossyFields: [String]

    init(
        requestID: String = UUID().uuidString,
        sessionID: String? = nil,
        turnID: String? = nil,
        model: String,
        messages: [CanonicalMessage],
        tools: [CanonicalTool]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool? = nil,
        reasoning: CanonicalReasoningPolicy? = nil,
        stream: Bool = true,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        contextBudgetTokens: Int? = nil,
        timeoutSeconds: Int? = nil,
        idempotencyKey: String? = nil,
        lossyFields: [String] = []
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.reasoning = reasoning
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextBudgetTokens = contextBudgetTokens
        self.timeoutSeconds = timeoutSeconds
        self.idempotencyKey = idempotencyKey
        self.lossyFields = lossyFields
    }
}

// MARK: Events

/// Token usage reported by a provider.
struct CanonicalUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cachedTokens: Int?
    var reasoningTokens: Int?
    /// Where the numbers came from (AC-106).
    enum Origin: String, Codable, Equatable, Sendable {
        case vendor
        case header
        case observed
        case estimated
    }

    var origin: Origin
}

/// One canonical stream event. The router core never sees dialect shapes.
enum CanonicalEvent: Equatable, Sendable {
    case responseCreated(id: String, model: String)
    case reasoningDelta(text: String)
    case reasoningSummary(text: String)
    case outputTextDelta(text: String)
    case toolCallCreated(id: String, name: String)
    case toolCallArgumentsDelta(id: String, delta: String)
    case toolCallCompleted(id: String, arguments: String)
    case imageDelta(dataURI: String, mimeType: String?)
    case usage(CanonicalUsage)
    /// Lossy translation or unsupported field notice — never silent.
    case warning(message: String)
    case completed
    case cancelled
    case failed(error: CanonicalError)
}

/// Structured error classification (docs/12_api_contracts.md §错误分类).
enum CanonicalError: Error, Equatable, Sendable {
    case authentication(detail: String)
    case rateLimit(detail: String, retryAfterSeconds: Int?)
    case providerUnavailable(detail: String)
    case protocolTranslation(detail: String)
    case capabilityMismatch(detail: String)
    case contextOverflow(detail: String)
    case toolStateConflict(detail: String)
    case targetConfiguration(detail: String)
    case securityPolicy(detail: String)
    case cancelled

    var isRetriable: Bool {
        switch self {
        case .rateLimit, .providerUnavailable: return true
        case .authentication, .protocolTranslation, .capabilityMismatch,
             .contextOverflow, .toolStateConflict, .targetConfiguration,
             .securityPolicy, .cancelled:
            return false
        }
    }
}

// MARK: - Provider adapter contract

/// One request as a provider actually wants it on the wire.
struct ProviderHTTPRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    init(method: String = "POST", url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One response chunk as received from a provider.
struct ProviderHTTPResponseChunk: Equatable, Sendable {
    var data: Data
    var isFinal: Bool
}

/// Contract a dialect adapter must fulfill (docs/12_api_contracts.md).
///
/// Implementations are stateless: streaming decode state travels in
/// `ProviderDecodeState` carried by the caller.
protocol ProviderAdapter: Sendable {
    static var dialect: APIDialect { get }

    /// Encodes a canonical request into the provider's wire shape.
    func encode(_ request: CanonicalRequest, model: String, endpoint: URL) throws -> ProviderHTTPRequest

    /// Decodes one SSE chunk (or a full non-streaming body when
    /// `isFinal=true` with no prior chunks) into canonical events.
    func decode(_ chunk: ProviderHTTPResponseChunk, state: inout ProviderDecodeState) -> [CanonicalEvent]
}

/// Mutable decode state owned by the caller (thread-confined).
struct ProviderDecodeState: @unchecked Sendable {
    var buffer: Data = Data()
    var geminiThoughtSignatures: [String: String] = [:]
}
