import Foundation

/// Protocol adapters translating between the ChatGPT client's OpenAI-shaped
/// requests and third-party provider APIs (Anthropic / Google Gemini).
///
/// Modeled after opencodex's `adapters/factory.ts` + `anthropic.ts`:
/// - `.anthropic` -> POST `{baseURL}/v1/messages` with `x-api-key`
/// - `.google`    -> POST `{baseURL}/models/{model}:streamGenerateContent`
///   (or `:generateContent` for non-streaming)
extension SwiftNativeProxyRuntimeService {
    // MARK: - Anthropic

    /// Converts an OpenAI chat payload into an Anthropic Messages request.
    func convertChatToAnthropic(_ chatBody: [String: Any], model: String) -> [String: Any] {
        var systemPrompt = ""
        var claudeMessages: [[String: Any]] = []

        let rawMessages = (chatBody["messages"] as? [[String: Any]]) ?? []
        for message in rawMessages {
            let role = (message["role"] as? String) ?? "user"
            if role == "system" {
                if let content = message["content"] as? String {
                    systemPrompt = content
                } else if let parts = message["content"] as? [[String: Any]] {
                    systemPrompt = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                continue
            }

            if role == "user" {
                claudeMessages.append([
                    "role": "user",
                    "content": anthropicUserContent(message["content"]),
                ])
            } else if role == "assistant" {
                var contentParts: [[String: Any]] = []
                if let content = message["content"] as? String, !content.isEmpty {
                    contentParts.append(["type": "text", "text": content])
                }
                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    for (index, toolCall) in toolCalls.enumerated() {
                        let fn = (toolCall["function"] as? [String: Any]) ?? [:]
                        var args: [String: Any] = [:]
                        if let argsString = fn["arguments"] as? String,
                           let parsed = try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any] {
                            args = parsed
                        }
                        contentParts.append([
                            "type": "tool_use",
                            "id": (toolCall["id"] as? String) ?? "toolu_opencodex_\(index)",
                            "name": fn["name"] as? String ?? "",
                            "input": args,
                        ])
                    }
                }
                claudeMessages.append([
                    "role": "assistant",
                    "content": contentParts.isEmpty ? "" : contentParts,
                ])
            } else if role == "tool" {
                let toolUseID = (message["tool_call_id"] as? String) ?? ""
                guard !toolUseID.isEmpty else { continue }
                claudeMessages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "content": anthropicToolResultContent(message["content"]),
                    ]],
                ])
            }
        }

        let tools: [[String: Any]] = ((chatBody["tools"] as? [[String: Any]]) ?? []).compactMap { tool in
            let fn = (tool["function"] as? [String: Any]) ?? tool
            guard let name = fn["name"] as? String, !name.isEmpty else { return nil }
            return [
                "name": name,
                "description": fn["description"] as? String ?? "",
                "input_schema": fn["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
            ]
        }

        var anthropicBody: [String: Any] = [
            "model": model,
            "messages": claudeMessages,
            "max_tokens": chatBody["max_tokens"] as? Int ?? 4096,
            "stream": chatBody["stream"] as? Bool ?? true,
        ]
        if !systemPrompt.isEmpty {
            anthropicBody["system"] = systemPrompt
        }
        if !tools.isEmpty {
            anthropicBody["tools"] = tools
        }
        return anthropicBody
    }

    /// Converts OpenAI content (string / parts) into Anthropic user content blocks.
    private func anthropicUserContent(_ content: Any?) -> Any {
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [[String: Any]] else {
            return content ?? ""
        }
        var blocks: [[String: Any]] = []
        for part in parts {
            let type = (part["type"] as? String) ?? ""
            if type == "text" || type == "input_text" {
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
            } else if type == "image_url" {
                let imageURL = (part["image_url"] as? String) ?? ((part["image_url"] as? [String: Any])?["url"] as? String) ?? ""
                guard !imageURL.isEmpty else { continue }
                if imageURL.hasPrefix("data:"), let comma = imageURL.firstIndex(of: ",") {
                    let header = String(imageURL[imageURL.index(imageURL.startIndex, offsetBy: 5)..<comma])
                    let mediaType = header.split(separator: ";").first.map(String.init) ?? "image/png"
                    let data = String(imageURL[imageURL.index(after: comma)...])
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]])
                } else {
                    blocks.append(["type": "image", "source": ["type": "url", "url": imageURL]])
                }
            }
        }
        return blocks.isEmpty ? "" : blocks
    }

    private func anthropicToolResultContent(_ content: Any?) -> Any {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else {
            return content ?? ""
        }
        var blocks: [[String: Any]] = []
        for part in parts {
            let type = (part["type"] as? String) ?? ""
            if type == "text" || type == "input_text" || type == "output_text" {
                if let text = part["text"] as? String {
                    blocks.append(["type": "text", "text": text])
                }
            } else if let text = part["text"] as? String {
                blocks.append(["type": "text", "text": text])
            }
        }
        return blocks.isEmpty ? "" : blocks
    }

    /// Converts a completed Anthropic Messages response into an OpenAI chat.completion.
    func convertAnthropicResponseToChatCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        var content = ""
        var toolCalls: [[String: Any]] = []
        var finishReason = "stop"

        if let contentBlocks = response["content"] as? [[String: Any]] {
            for block in contentBlocks {
                let type = (block["type"] as? String) ?? ""
                if type == "text" {
                    content += (block["text"] as? String) ?? ""
                } else if type == "tool_use" {
                    let args = (block["input"] as? [String: Any]) ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                    toolCalls.append([
                        "id": block["id"] as? String ?? "",
                        "type": "function",
                        "function": [
                            "name": block["name"] as? String ?? "",
                            "arguments": String(data: argsData, encoding: .utf8) ?? "{}",
                        ],
                    ])
                    finishReason = "tool_calls"
                }
            }
        }

        let stopReason = (response["stop_reason"] as? String) ?? "end_turn"
        if stopReason == "tool_use" { finishReason = "tool_calls" }

        var choice: [String: Any] = ["index": 0, "finish_reason": finishReason]
        if !toolCalls.isEmpty {
            choice["message"] = ["role": "assistant", "content": content, "tool_calls": toolCalls]
        } else {
            choice["message"] = ["role": "assistant", "content": content]
        }

        var result: [String: Any] = [
            "id": response["id"] as? String ?? UUID().uuidString,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": fallbackModel,
            "choices": [choice],
        ]
        if let usage = response["usage"] as? [String: Any] {
            result["usage"] = anthropicUsageToOpenAI(usage)
        }
        return result
    }

    private func anthropicUsageToOpenAI(_ usage: [String: Any]) -> [String: Any] {
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        return [
            "prompt_tokens": input,
            "completion_tokens": output,
            "total_tokens": input + output,
        ]
    }

    // MARK: - Google Gemini

    /// Converts an OpenAI chat payload into a Gemini generateContent request.
    func convertChatToGemini(_ chatBody: [String: Any]) -> [String: Any] {
        var systemInstruction: [String: Any]?
        var contents: [[String: Any]] = []

        let rawMessages = (chatBody["messages"] as? [[String: Any]]) ?? []
        for message in rawMessages {
            let role = (message["role"] as? String) ?? "user"
            if role == "system" {
                let text = geminiText(of: message["content"])
                if !text.isEmpty {
                    systemInstruction = ["parts": [["text": text]]]
                }
                continue
            }

            let geminiRole = role == "assistant" ? "model" : "user"
            var parts: [[String: Any]] = []
            if let content = message["content"] as? String {
                parts.append(["text": content])
            } else if let contentParts = message["content"] as? [[String: Any]] {
                for part in contentParts {
                    let type = (part["type"] as? String) ?? ""
                    if type == "text" || type == "input_text", let text = part["text"] as? String {
                        parts.append(["text": text])
                    } else if type == "image_url" {
                        let imageURL = (part["image_url"] as? String) ?? ((part["image_url"] as? [String: Any])?["url"] as? String) ?? ""
                        if imageURL.hasPrefix("data:"), let comma = imageURL.firstIndex(of: ",") {
                            let data = String(imageURL[imageURL.index(after: comma)...])
                            parts.append(["inline_data": ["mime_type": "image/png", "data": data]])
                        } else {
                            parts.append(["file_data": ["file_uri": imageURL, "mime_type": "image/png"]])
                        }
                    }
                }
            }

            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                var functionCalls: [[String: Any]] = []
                for toolCall in toolCalls {
                    let fn = (toolCall["function"] as? [String: Any]) ?? [:]
                    var args: [String: Any] = [:]
                    if let argsString = fn["arguments"] as? String,
                       let parsed = try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any] {
                        args = parsed
                    }
                    functionCalls.append([
                        "name": fn["name"] as? String ?? "",
                        "args": args,
                    ])
                }
                if !functionCalls.isEmpty {
                    parts.append(["functionCall": ["name": "", "args": [:]]])
                    // Replace placeholder with actual function calls.
                    parts.removeLast()
                    for call in functionCalls {
                        parts.append(["functionCall": call])
                    }
                }
            }

            if role == "tool" {
                let toolUseID = (message["tool_call_id"] as? String) ?? ""
                let text = geminiText(of: message["content"])
                parts.append(["functionResponse": ["name": toolUseID, "response": ["result": text]]])
            }

            if !parts.isEmpty {
                contents.append(["role": geminiRole, "parts": parts])
            }
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": chatBody["temperature"] ?? 0.7,
                "maxOutputTokens": chatBody["max_tokens"] ?? 4096,
            ],
        ]
        if let systemInstruction {
            body["systemInstruction"] = systemInstruction
        }

        let tools: [[String: Any]] = ((chatBody["tools"] as? [[String: Any]]) ?? []).compactMap { tool in
            let fn = (tool["function"] as? [String: Any]) ?? tool
            guard let name = fn["name"] as? String, !name.isEmpty else { return nil }
            return [
                "functionDeclarations": [[
                    "name": name,
                    "description": fn["description"] as? String ?? "",
                    "parameters": fn["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]],
                ]],
            ]
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        return body
    }

    private func geminiText(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Converts a completed Gemini response into an OpenAI chat.completion.
    func convertGeminiResponseToChatCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        var content = ""
        var toolCalls: [[String: Any]] = []
        var finishReason = "stop"

        if let candidates = response["candidates"] as? [[String: Any]], let first = candidates.first {
            if let contentBlock = first["content"] as? [String: Any],
               let parts = contentBlock["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        content += text
                    } else if let functionCall = part["functionCall"] as? [String: Any] {
                        let args = (functionCall["args"] as? [String: Any]) ?? [:]
                        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                        toolCalls.append([
                            "id": "call_\(UUID().uuidString.prefix(8))",
                            "type": "function",
                            "function": [
                                "name": functionCall["name"] as? String ?? "",
                                "arguments": String(data: argsData, encoding: .utf8) ?? "{}",
                            ],
                        ])
                        finishReason = "tool_calls"
                    }
                }
            }
            if let reason = first["finishReason"] as? String, reason == "STOP" || reason == "MAX_TOKENS" {
                finishReason = reason == "STOP" ? "stop" : "length"
            }
        }

        var choice: [String: Any] = ["index": 0, "finish_reason": finishReason]
        if !toolCalls.isEmpty {
            choice["message"] = ["role": "assistant", "content": content, "tool_calls": toolCalls]
        } else {
            choice["message"] = ["role": "assistant", "content": content]
        }

        var result: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": fallbackModel,
            "choices": [choice],
        ]
        if let usage = response["usageMetadata"] as? [String: Any] {
            let prompt = usage["promptTokenCount"] as? Int ?? 0
            let completion = usage["candidatesTokenCount"] as? Int ?? 0
            result["usage"] = [
                "prompt_tokens": prompt,
                "completion_tokens": completion,
                "total_tokens": prompt + completion,
            ]
        }
        return result
    }
}
