import Foundation

// MARK: - Chat Completions adapter (OpenAI-compatible)

/// Adapter for the OpenAI-compatible Chat Completions dialect.
struct ChatAdapter: ProviderAdapter {
    static let dialect = APIDialect.chat

    func encode(_ request: CanonicalRequest, model: String, endpoint: URL) throws -> ProviderHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: encodeBody(request, model: model))
        return ProviderHTTPRequest(
            url: endpoint.appendingPathComponent("chat/completions"),
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    /// Body-only encoding; the caller supplies the endpoint (keeps the
    /// adapter stateless and testable).
    func encodeBody(_ request: CanonicalRequest, model: String) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": try encodeMessages(request.messages),
            "stream": request.stream,
        ]
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function", "function": ["name": tool.name, "parameters": (tool.schemaJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]]]
            }
        }
        if let toolChoice = request.toolChoice {
            body["tool_choice"] = toolChoice
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }
        var lossyFields = request.lossyFields
        if let effort = request.reasoning?.effort, !lossyFields.contains("reasoning") {
            // Some OpenAI-compatible providers accept reasoning_effort.
            body["reasoning_effort"] = effort
        } else if request.reasoning?.effort != nil {
            lossyFields.append("reasoning")
        }
        return body
    }

    func encodeMessages(_ messages: [CanonicalMessage]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            var role = message.role.rawValue
            if role == "developer" { role = "system" }
            if role == "tool" {
                out.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "content": message.toolOutput ?? "",
                ])
                continue
            }
            var content: Any = message.text ?? ""
            if let images = message.images, !images.isEmpty {
                var parts: [[String: Any]] = []
                if let text = message.text, !text.isEmpty {
                    parts.append(["type": "text", "text": text])
                }
                for image in images {
                    switch image.kind {
                    case .dataURI:
                        parts.append(["type": "image_url", "image_url": ["url": image.value]])
                    case .remoteURL:
                        parts.append(["type": "image_url", "image_url": ["url": image.value]])
                    }
                }
                content = parts
            }
            var item: [String: Any] = ["role": role, "content": content]
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                item["tool_calls"] = toolCalls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                }
            }
            out.append(item)
        }
        return out
    }

    func decode(_ chunk: ProviderHTTPResponseChunk, state: inout ProviderDecodeState) -> [CanonicalEvent] {
        if chunk.isFinal && state.buffer.isEmpty && !chunk.data.isEmpty {
            // Non-streaming body path.
            return decodeNonStreaming(chunk.data)
        }
        state.buffer.append(chunk.data)
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: state.buffer, isFinal: chunk.isFinal)
        var out: [CanonicalEvent] = []
        for event in events {
            guard event.data != "[DONE]",
                  let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                continue
            }
            if let error = payload["error"] as? [String: Any] {
                out.append(.failed(error: Self.classifyError(error)))
                continue
            }
            guard let choices = payload["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            if let delta = first["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    out.append(.outputTextDelta(text: text))
                }
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    out.append(.reasoningDelta(text: reasoning))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let id = (call["id"] as? String) ?? ""
                        let function = (call["function"] as? [String: Any]) ?? [:]
                        let name = (function["name"] as? String) ?? ""
                        let arguments = (function["arguments"] as? String) ?? ""
                        if !id.isEmpty && !name.isEmpty && arguments.isEmpty {
                            out.append(.toolCallCreated(id: id, name: name))
                        } else if !arguments.isEmpty {
                            out.append(.toolCallArgumentsDelta(id: id, delta: arguments))
                        }
                    }
                }
            } else if let message = first["message"] as? [String: Any] {
                // Non-streaming style inside a chunk (rare).
                if let text = message["content"] as? String, !text.isEmpty {
                    out.append(.outputTextDelta(text: text))
                }
            }
            if let finish = first["finish_reason"] as? String, finish == "stop" {
                out.append(.completed)
            }
            if let usage = payload["usage"] as? [String: Any] {
                out.append(.usage(Self.usage(from: usage)))
            }
        }
        if chunk.isFinal {
            state.buffer.removeAll()
            out.append(.completed)
        }
        return out
    }

    private func decodeNonStreaming(_ body: Data) -> [CanonicalEvent] {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [.failed(error: .protocolTranslation(detail: "invalid JSON body"))]
        }
        if let error = payload["error"] as? [String: Any] {
            return [.failed(error: Self.classifyError(error))]
        }
        var out: [CanonicalEvent] = []
        if let choices = payload["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    out.append(.outputTextDelta(text: text))
                }
                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let id = (call["id"] as? String) ?? ""
                        let function = (call["function"] as? [String: Any]) ?? [:]
                        out.append(.toolCallCreated(id: id, name: (function["name"] as? String) ?? ""))
                        out.append(.toolCallCompleted(id: id, arguments: (function["arguments"] as? String) ?? ""))
                    }
                }
            }
        }
        if let usage = payload["usage"] as? [String: Any] {
            out.append(.usage(Self.usage(from: usage)))
        }
        out.append(.completed)
        return out
    }

    static func usage(from object: [String: Any]) -> CanonicalUsage {
        CanonicalUsage(
            inputTokens: object["prompt_tokens"] as? Int,
            outputTokens: object["completion_tokens"] as? Int,
            totalTokens: object["total_tokens"] as? Int,
            cachedTokens: (object["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
            reasoningTokens: (object["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int,
            origin: .observed
        )
    }

    static func classifyError(_ object: [String: Any]) -> CanonicalError {
        let type = (object["type"] as? String) ?? ""
        let message = (object["message"] as? String) ?? ""
        let code = (object["code"] as? String) ?? ""
        if type.contains("rate_limit") || code.contains("rate") || (object["status"] as? Int) == 429 {
            return .rateLimit(detail: message, retryAfterSeconds: nil)
        }
        if type.contains("auth") || code.contains("invalid_api_key") || (object["status"] as? Int) == 401 {
            return .authentication(detail: message)
        }
        if (object["status"] as? Int) == 403 {
            return .securityPolicy(detail: message)
        }
        if type.contains("insufficient_quota") {
            return .rateLimit(detail: message, retryAfterSeconds: nil)
        }
        if type.contains("context") || type.contains("length") {
            return .contextOverflow(detail: message)
        }
        if type.contains("server") || type.contains("unavailable") || (object["status"] as? Int) == 502 {
            return .providerUnavailable(detail: message)
        }
        return .protocolTranslation(detail: "\(type): \(message)")
    }
}

// MARK: - Responses API adapter

/// Adapter for the Responses API dialect (native Codex surface).
struct ResponsesAdapter: ProviderAdapter {
    static let dialect = APIDialect.responses

    func encodeBody(_ request: CanonicalRequest, model: String) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": request.stream,
            "store": false,
        ]
        var input: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .developer, .system:
                if let text = message.text {
                    body["instructions"] = (body["instructions"] as? String ?? "") + text
                }
            case .user:
                var parts: [[String: Any]] = []
                if let text = message.text, !text.isEmpty {
                    parts.append(["type": "input_text", "text": text])
                }
                for image in message.images ?? [] {
                    parts.append(["type": "input_image", "image_url": image.value])
                }
                input.append(["type": "message", "role": "user", "content": parts])
            case .assistant:
                var item: [String: Any] = ["type": "message", "role": "assistant"]
                var parts: [[String: Any]] = []
                if let text = message.text, !text.isEmpty {
                    parts.append(["type": "output_text", "text": text])
                }
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    item["tool_calls"] = toolCalls.map { call -> [String: Any] in
                        [
                            "type": "function_call",
                            "id": call.id,
                            "name": call.name,
                            "arguments": call.arguments,
                        ]
                    }
                }
                if !parts.isEmpty { item["content"] = parts }
                input.append(item)
            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.toolOutput ?? "",
                ])
            }
        }
        body["input"] = input
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "name": $0.name, "parameters": ($0.schemaJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]] }
        }
        if let effort = request.reasoning?.effort {
            body["reasoning"] = ["effort": effort]
        }
        if let maxTokens = request.maxTokens {
            body["max_output_tokens"] = maxTokens
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        return body
    }

    func encode(_ request: CanonicalRequest, model: String, endpoint: URL) throws -> ProviderHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: encodeBody(request, model: model))
        return ProviderHTTPRequest(
            url: endpoint.appendingPathComponent("responses"),
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    func decode(_ chunk: ProviderHTTPResponseChunk, state: inout ProviderDecodeState) -> [CanonicalEvent] {
        if chunk.isFinal && state.buffer.isEmpty && !chunk.data.isEmpty {
            return decodeNonStreaming(chunk.data)
        }
        state.buffer.append(chunk.data)
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: state.buffer, isFinal: chunk.isFinal)
        var out: [CanonicalEvent] = []
        for event in events {
            guard event.data != "[DONE]",
                  let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                continue
            }
            let type = (payload["type"] as? String) ?? ""
            switch type {
            case "response.created":
                if let response = payload["response"] as? [String: Any] {
                    out.append(.responseCreated(id: (response["id"] as? String) ?? "", model: (response["model"] as? String) ?? ""))
                }
            case "response.output_text.delta":
                if let delta = payload["delta"] as? String {
                    out.append(.outputTextDelta(text: delta))
                }
            case "response.reasoning_summary_text.delta":
                if let delta = payload["delta"] as? String {
                    out.append(.reasoningDelta(text: delta))
                }
            case "response.reasoning_summary_text.done":
                if let text = payload["text"] as? String {
                    out.append(.reasoningSummary(text: text))
                }
            case "response.output_item.added":
                if let item = payload["item"] as? [String: Any], (item["type"] as? String) == "function_call" {
                    out.append(.toolCallCreated(id: (item["id"] as? String) ?? "", name: (item["name"] as? String) ?? ""))
                }
            case "response.function_call_arguments.delta":
                if let delta = payload["delta"] as? String {
                    out.append(.toolCallArgumentsDelta(id: (payload["item_id"] as? String) ?? "", delta: delta))
                }
            case "response.function_call_arguments.done":
                if let arguments = payload["arguments"] as? String {
                    out.append(.toolCallCompleted(id: (payload["item_id"] as? String) ?? "", arguments: arguments))
                }
            case "response.completed":
                if let response = payload["response"] as? [String: Any],
                   let usage = response["usage"] as? [String: Any] {
                    out.append(.usage(responsesUsage(usage)))
                }
                out.append(.completed)
            case "response.failed":
                let err = (payload["response"] as? [String: Any])?["error"] as? [String: Any]
                out.append(.failed(error: .providerUnavailable(detail: (err?["message"] as? String) ?? "response failed")))
            case "error":
                out.append(.failed(error: ChatAdapter.classifyError(payload)))
            default:
                break
            }
        }
        return out
    }

    private func decodeNonStreaming(_ body: Data) -> [CanonicalEvent] {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [.failed(error: .protocolTranslation(detail: "invalid JSON body"))]
        }
        if let error = payload["error"] as? [String: Any] {
            return [.failed(error: ChatAdapter.classifyError(error))]
        }
        var out: [CanonicalEvent] = []
        if let output = payload["output"] as? [[String: Any]] {
            for item in output {
                switch item["type"] as? String {
                case "message":
                    if let content = item["content"] as? [[String: Any]] {
                        for part in content {
                            if (part["type"] as? String) == "output_text", let text = part["text"] as? String {
                                out.append(.outputTextDelta(text: text))
                            }
                        }
                    }
                case "function_call":
                    out.append(.toolCallCreated(id: (item["id"] as? String) ?? "", name: (item["name"] as? String) ?? ""))
                    out.append(.toolCallCompleted(id: (item["id"] as? String) ?? "", arguments: (item["arguments"] as? String) ?? ""))
                default:
                    break
                }
            }
        }
        if let usage = payload["usage"] as? [String: Any] {
            out.append(.usage(responsesUsage(usage)))
        }
        out.append(.completed)
        return out
    }

    private func responsesUsage(_ usage: [String: Any]) -> CanonicalUsage {
        CanonicalUsage(
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int,
            cachedTokens: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
            reasoningTokens: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int,
            origin: .observed
        )
    }
}

// MARK: - Anthropic Messages adapter

/// Adapter for the Anthropic Messages dialect.
struct AnthropicAdapter: ProviderAdapter {
    static let dialect = APIDialect.anthropic

    func encodeBody(_ request: CanonicalRequest, model: String) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens ?? 8192,
            "stream": request.stream,
        ]
        var system: [String] = []
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system, .developer:
                if let text = message.text { system.append(text) }
            case .user:
                messages.append(["role": "user", "content": message.text ?? ""])
            case .assistant:
                var content: Any = message.text ?? ""
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    var blocks: [[String: Any]] = []
                    if let text = message.text, !text.isEmpty {
                        blocks.append(["type": "text", "text": text])
                    }
                    for call in toolCalls {
                        blocks.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.name,
                            "input": (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:],
                        ])
                    }
                    content = blocks
                }
                messages.append(["role": "assistant", "content": content])
            case .tool:
                messages.append([
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.toolOutput ?? ""]],
                ])
            }
        }
        if !system.isEmpty {
            body["system"] = system.joined(separator: "\n\n")
        }
        body["messages"] = messages
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "input_schema": ($0.schemaJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]] }
        }
        return body
    }

    func encode(_ request: CanonicalRequest, model: String, endpoint: URL) throws -> ProviderHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: encodeBody(request, model: model))
        return ProviderHTTPRequest(
            url: endpoint.appendingPathComponent("v1/messages"),
            headers: ["Content-Type": "application/json", "anthropic-version": "2023-06-01"],
            body: body
        )
    }

    func decode(_ chunk: ProviderHTTPResponseChunk, state: inout ProviderDecodeState) -> [CanonicalEvent] {
        if chunk.isFinal && state.buffer.isEmpty && !chunk.data.isEmpty {
            return decodeNonStreaming(chunk.data)
        }
        state.buffer.append(chunk.data)
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: state.buffer, isFinal: chunk.isFinal)
        var out: [CanonicalEvent] = []
        for event in events {
            guard let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                continue
            }
            switch payload["type"] as? String {
            case "content_block_delta":
                let delta = (payload["delta"] as? [String: Any]) ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        out.append(.outputTextDelta(text: text))
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String {
                        out.append(.toolCallArgumentsDelta(id: "", delta: partial))
                    }
                default:
                    break
                }
            case "content_block_start":
                let block = (payload["content_block"] as? [String: Any]) ?? [:]
                if (block["type"] as? String) == "tool_use" {
                    out.append(.toolCallCreated(id: (block["id"] as? String) ?? "", name: (block["name"] as? String) ?? ""))
                }
            case "message_delta":
                if let usage = (payload["usage"] as? [String: Any]) {
                    out.append(
                        .usage(
                            CanonicalUsage(
                                inputTokens: usage["input_tokens"] as? Int,
                                outputTokens: usage["output_tokens"] as? Int,
                                totalTokens: nil,
                                cachedTokens: nil,
                                reasoningTokens: nil,
                                origin: .observed
                            )
                        )
                    )
                }
            case "message_stop":
                out.append(.completed)
            case "error":
                out.append(.failed(error: .providerUnavailable(detail: "anthropic error")))
            default:
                break
            }
        }
        return out
    }

    private func decodeNonStreaming(_ body: Data) -> [CanonicalEvent] {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [.failed(error: .protocolTranslation(detail: "invalid JSON body"))]
        }
        var out: [CanonicalEvent] = []
        if let content = payload["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String {
                        out.append(.outputTextDelta(text: text))
                    }
                case "tool_use":
                    out.append(.toolCallCreated(id: (block["id"] as? String) ?? "", name: (block["name"] as? String) ?? ""))
                    if let input = block["input"], let data = try? JSONSerialization.data(withJSONObject: input) {
                        out.append(.toolCallCompleted(id: (block["id"] as? String) ?? "", arguments: String(data: data, encoding: .utf8) ?? ""))
                    }
                default:
                    break
                }
            }
        }
        if let usage = payload["usage"] as? [String: Any] {
            out.append(
                .usage(
                    CanonicalUsage(
                        inputTokens: usage["input_tokens"] as? Int,
                        outputTokens: usage["output_tokens"] as? Int,
                        totalTokens: nil,
                        cachedTokens: nil,
                        reasoningTokens: nil,
                        origin: .observed
                    )
                )
            )
        }
        out.append(.completed)
        return out
    }
}

// MARK: - Gemini adapter

/// Adapter for the Gemini `:generateContent` / `:streamGenerateContent`
/// dialect (including Antigravity's nested `response` SSE shape).
struct GoogleAdapter: ProviderAdapter {
    static let dialect = APIDialect.google

    func encodeBody(_ request: CanonicalRequest, model: String, streaming: Bool) throws -> [String: Any] {
        var contents: [[String: Any]] = []
        var systemInstruction: String?

        for message in request.messages {
            switch message.role {
            case .system, .developer:
                systemInstruction = message.text
            case .user:
                var parts: [[String: Any]] = []
                if let text = message.text, !text.isEmpty {
                    parts.append(["text": text])
                }
                for image in message.images ?? [] {
                    switch image.kind {
                    case .dataURI:
                        if let comma = image.value.firstIndex(of: ",") {
                            let data = String(image.value[image.value.index(after: comma)...])
                            parts.append(["inline_data": ["mime_type": image.mimeType ?? "image/png", "data": data]])
                        }
                    case .remoteURL:
                        parts.append(["file_data": ["file_uri": image.value, "mime_type": image.mimeType ?? "image/png"]])
                    }
                }
                contents.append(["role": "user", "parts": parts])
            case .assistant:
                var parts: [[String: Any]] = []
                if let text = message.text, !text.isEmpty {
                    parts.append(["text": text])
                }
                for call in message.toolCalls ?? [] {
                    var args: [String: Any] = [:]
                    if let data = call.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        args = parsed
                    }
                    parts.append(["functionCall": ["name": call.name, "args": args]])
                }
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
            case .tool:
                var parts: [[String: Any]] = []
                var output: Any = message.toolOutput ?? ""
                if let data = message.toolOutput?.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    output = parsed
                }
                parts.append(["functionResponse": ["name": message.toolCallID ?? "", "response": ["result": output]]])
                contents.append(["role": "user", "parts": parts])
            }
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": request.temperature ?? 0.7,
                "maxOutputTokens": request.maxTokens ?? 4096,
            ],
        ]
        if let systemInstruction {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { ["name": $0.name, "parameters": ($0.schemaJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]] }]]
        }
        if streaming {
            body["alt"] = "sse"
        }
        return body
    }

    func encode(_ request: CanonicalRequest, model: String, endpoint: URL) throws -> ProviderHTTPRequest {
        let streaming = request.stream
        let body = try JSONSerialization.data(withJSONObject: encodeBody(request, model: model, streaming: streaming))
        let method = streaming ? ":streamGenerateContent" : ":generateContent"
        return ProviderHTTPRequest(
            url: endpoint.appendingPathComponent("models/\(model):\(method)"),
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    func decode(_ chunk: ProviderHTTPResponseChunk, state: inout ProviderDecodeState) -> [CanonicalEvent] {
        if chunk.isFinal && state.buffer.isEmpty && !chunk.data.isEmpty {
            return decodeNonStreaming(chunk.data)
        }
        state.buffer.append(chunk.data)
        let decoder = SSEStreamDecoder()
        let events = decoder.push(data: state.buffer, isFinal: chunk.isFinal)
        var out: [CanonicalEvent] = []
        for event in events {
            guard event.data != "[DONE]",
                  let payloadData = event.data.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }
            // Antigravity nests under `response`; the public API is top-level.
            let parsed = (root["response"] as? [String: Any]) ?? root
            if let error = parsed["error"] as? [String: Any] {
                out.append(.failed(error: ChatAdapter.classifyError(error)))
                continue
            }
            if let candidates = parsed["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        out.append(.outputTextDelta(text: text))
                    }
                    if let functionCall = part["functionCall"] as? [String: Any],
                       let name = functionCall["name"] as? String {
                        let id = "fc-\(UUID().uuidString.prefix(8))"
                        out.append(.toolCallCreated(id: id, name: name))
                        if let args = functionCall["args"] as? [String: Any],
                           let data = try? JSONSerialization.data(withJSONObject: args) {
                            out.append(.toolCallCompleted(id: id, arguments: String(data: data, encoding: .utf8) ?? ""))
                        }
                    }
                }
            }
            if let usage = parsed["usageMetadata"] as? [String: Any] {
                let inTokens = (usage["promptTokenCount"] as? Int) ?? (usage["prompt_tokens"] as? Int)
                let outTokens = (usage["candidatesTokenCount"] as? Int) ?? (usage["completion_tokens"] as? Int)
                out.append(.usage(CanonicalUsage(inputTokens: inTokens, outputTokens: outTokens, totalTokens: nil, cachedTokens: nil, reasoningTokens: nil, origin: .observed)))
            }
        }
        if chunk.isFinal {
            state.buffer.removeAll()
            out.append(.completed)
        }
        return out
    }

    private func decodeNonStreaming(_ body: Data) -> [CanonicalEvent] {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [.failed(error: .protocolTranslation(detail: "invalid JSON body"))]
        }
        var out: [CanonicalEvent] = []
        if let candidates = payload["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    out.append(.outputTextDelta(text: text))
                }
            }
        }
        out.append(.completed)
        return out
    }
}
