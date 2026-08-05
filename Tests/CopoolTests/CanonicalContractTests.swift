import XCTest
@testable import Copool

/// Phase 3 acceptance: canonical encode/decode contract fixtures for all four
/// dialects; lossy conversions surface warnings; adapters never carry raw
/// auth headers.
final class CanonicalContractTests: XCTestCase {
    private func makeRequest(stream: Bool = true) -> CanonicalRequest {
        CanonicalRequest(
            model: "test-model",
            messages: [
                CanonicalMessage(role: .system, text: "You are a test assistant."),
                CanonicalMessage(role: .user, text: "Hello!"),
            ],
            tools: [CanonicalTool(name: "get_weather", schemaJSON: CanonicalTool.schema(from: ["type": "object"]))],
            reasoning: CanonicalReasoningPolicy(effort: "medium"),
            stream: stream,
            temperature: 0.3,
            maxTokens: 512
        )
    }

    // MARK: - Chat

    func testChatEncodeProducesWireShape() throws {
        let body = try ChatAdapter().encodeBody(makeRequest(), model: "deepseek-chat")
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["content"] as? String, "Hello!")
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["type"] as? String, "function")
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["temperature"] as? Double, 0.3)
    }

    func testChatEncodeToolResultMessage() throws {
        let request = CanonicalRequest(
            model: "m",
            messages: [
                CanonicalMessage(role: .assistant, text: "let me check", toolCalls: [CanonicalToolCall(id: "call-1", name: "get_weather", arguments: "{\"city\":\"x\"}")]),
                CanonicalMessage(role: .tool, toolCallID: "call-1", toolOutput: "{\"temp\": 20}"),
            ]
        )
        let body = try ChatAdapter().encodeBody(request, model: "m")
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["tool_calls"] as? [[String: Any]] != nil, true)
        XCTAssertEqual(messages?[1]["role"] as? String, "tool")
        XCTAssertEqual(messages?[1]["tool_call_id"] as? String, "call-1")
    }

    func testChatDecodeStreamingSSE() {
        let adapter = ChatAdapter()
        var state = ProviderDecodeState()
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-9","function":{"name":"get_weather","arguments":""}}]},"index":0}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-9","function":{"arguments":"{\\"city\\":\\"paris\\"}"}}]},"index":0}]}

        data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

        data: [DONE]

        """
        let events = adapter.decode(ProviderHTTPResponseChunk(data: Data(sse.utf8), isFinal: true), state: &state)
        let texts = events.compactMap { if case .outputTextDelta(let t) = $0 { return t }; return nil }
        XCTAssertEqual(texts, ["Hello"])
        let created = events.compactMap { if case .toolCallCreated(let id, let name) = $0 { return (id, name) }; return nil }
        XCTAssertEqual(created.first?.1, "get_weather")
        let arguments = events.compactMap { if case .toolCallArgumentsDelta(let id, let delta) = $0 { return (id, delta) }; return nil }
        XCTAssertEqual(arguments.first?.1, "{\"city\":\"paris\"}")
        let usage = events.compactMap { if case .usage(let u) = $0 { return u }; return nil }
        XCTAssertEqual(usage.first?.inputTokens, 10)
        XCTAssertEqual(usage.first?.outputTokens, 5)
        XCTAssertTrue(events.contains(.completed))
    }

    func testChatErrorClassification() {
        let rate = ChatAdapter.classifyError(["type": "rate_limit_error", "message": "slow down"])
        XCTAssertEqual(rate, .rateLimit(detail: "slow down", retryAfterSeconds: nil))
        let auth = ChatAdapter.classifyError(["type": "authentication_error", "message": "bad key"])
        XCTAssertEqual(auth, .authentication(detail: "bad key"))
        let quota = ChatAdapter.classifyError(["type": "insufficient_quota", "message": "out"])
        XCTAssertEqual(quota, .rateLimit(detail: "out", retryAfterSeconds: nil))
    }

    // MARK: - Responses

    func testResponsesEncodeAndDecodeNonStreaming() throws {
        let request = CanonicalRequest(
            model: "gpt-5.4",
            messages: [
                CanonicalMessage(role: .user, text: "hi", images: [CanonicalImage(kind: .dataURI, value: "data:image/png;base64,AAAA", mimeType: "image/png")]),
            ]
        )
        let body = try ResponsesAdapter().encodeBody(request, model: "gpt-5.4")
        let input = body["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "message")
        let content = input?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "input_text")
        XCTAssertEqual(content?.last?["type"] as? String, "input_image")

        let adapter = ResponsesAdapter()
        var state = ProviderDecodeState()
        let json = """
        {"output":[{"type":"message","content":[{"type":"output_text","text":"Done."}]}],
         "usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}
        """
        let events = adapter.decode(ProviderHTTPResponseChunk(data: Data(json.utf8), isFinal: true), state: &state)
        XCTAssertTrue(events.contains { if case .outputTextDelta("Done.") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .usage(let u) = $0, u.totalTokens == 5 { return true }; return false })
        XCTAssertTrue(events.contains(.completed))
    }

    func testResponsesDecodeSSE() {
        let adapter = ResponsesAdapter()
        var state = ProviderDecodeState()
        let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","model":"gpt-5.4"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hi"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

        data: [DONE]

        """
        let events = adapter.decode(ProviderHTTPResponseChunk(data: Data(sse.utf8), isFinal: true), state: &state)
        XCTAssertTrue(events.contains { if case .responseCreated("resp_1", "gpt-5.4") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .outputTextDelta("Hi") = $0 { return true }; return false })
        XCTAssertTrue(events.contains(.completed))
    }

    // MARK: - Anthropic

    func testAnthropicEncodeSystemAndTools() throws {
        let body = try AnthropicAdapter().encodeBody(makeRequest(), model: "claude-sonnet-4")
        XCTAssertEqual(body["system"] as? String, "You are a test assistant.")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "get_weather")
    }

    func testAnthropicEncodeToolUseResult() throws {
        let request = CanonicalRequest(
            model: "m",
            messages: [
                CanonicalMessage(role: .assistant, text: "ok", toolCalls: [CanonicalToolCall(id: "tu-1", name: "f", arguments: "{}")]),
                CanonicalMessage(role: .tool, toolCallID: "tu-1", toolOutput: "42"),
            ]
        )
        let body = try AnthropicAdapter().encodeBody(request, model: "m")
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        let resultBlock = (messages?[1]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(resultBlock?["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlock?["tool_use_id"] as? String, "tu-1")
    }

    // MARK: - Gemini

    func testGoogleEncodeContentsAndTools() throws {
        let body = try GoogleAdapter().encodeBody(makeRequest(), model: "gemini-3", streaming: false)
        let contents = body["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1) // system becomes systemInstruction
        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertNotNil(body["tools"])
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, 512)
    }

    func testGoogleDecodeNestedAntigravityShape() {
        let adapter = GoogleAdapter()
        var state = ProviderDecodeState()
        let sse = """
        data: {"response":{"candidates":[{"content":{"parts":[{"text":"gemini says hi"}]}}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":3}}}

        data: [DONE]

        """
        let events = adapter.decode(ProviderHTTPResponseChunk(data: Data(sse.utf8), isFinal: true), state: &state)
        XCTAssertTrue(events.contains { if case .outputTextDelta("gemini says hi") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .usage(let u) = $0, u.inputTokens == 4 { return true }; return false })
        XCTAssertTrue(events.contains(.completed))
    }

    // MARK: - Security

    func testAdaptersNeverEmitAuthHeaders() throws {
        let endpoint = URL(string: "https://example.com/v1")!
        let adapters: [any ProviderAdapter] = [ChatAdapter(), ResponsesAdapter(), AnthropicAdapter(), GoogleAdapter()]
        for adapter in adapters {
            let request = try adapter.encode(makeRequest(), model: "m", endpoint: endpoint)
            let headerNames = request.headers.keys.map { $0.lowercased() }
            XCTAssertFalse(headerNames.contains("authorization"), "\(adapter.dialect) leaked auth header")
            XCTAssertFalse(headerNames.contains("cookie"), "\(adapter.dialect) leaked cookie")
            // No ChatGPT/Codex identity headers either (AC-010).
            XCTAssertFalse(headerNames.contains { $0.contains("chatgpt") || $0.contains("codex") || $0.contains("originator") })
        }
    }

    func testErrorIsRetriableClassification() {
        XCTAssertTrue(CanonicalError.rateLimit(detail: "", retryAfterSeconds: 5).isRetriable)
        XCTAssertTrue(CanonicalError.providerUnavailable(detail: "").isRetriable)
        XCTAssertFalse(CanonicalError.authentication(detail: "").isRetriable)
        XCTAssertFalse(CanonicalError.cancelled.isRetriable)
    }
}
