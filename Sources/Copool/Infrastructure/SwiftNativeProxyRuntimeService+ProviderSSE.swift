import Foundation

/// Streaming decoders for Anthropic / Google SSE responses, translating into
/// OpenAI chat.completion.chunk shapes so the existing client pipeline works.
extension SwiftNativeProxyRuntimeService {
    // MARK: - Anthropic SSE

    /// Mutable stream state shared with the streaming task (serial access).
    final class AnthropicStreamState: @unchecked Sendable {
        var blockIndex = 0
        var toolCallIndex = 0
        var toolNameByIndex: [Int: String] = [:]
        var toolIDByIndex: [Int: String] = [:]
        var usage: [String: Any]?
    }

    /// Parses one Anthropic SSE event into chat.completion.chunk dictionaries.
    func translateAnthropicSSEEvent(_ event: SSEEvent, state: AnthropicStreamState) -> [[String: Any]] {
        guard event.data != "[DONE]",
              let payloadData = event.data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return []
        }

        let type = (parsed["type"] as? String) ?? ""
        switch type {
        case "message_start":
            if let message = parsed["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                state.usage = usage
            }
            return []
        case "content_block_start":
            let index = (parsed["index"] as? Int) ?? state.blockIndex
            state.blockIndex = index
            if let block = parsed["content_block"] as? [String: Any] {
                let blockType = (block["type"] as? String) ?? ""
                if blockType == "tool_use" {
                    let callIndex = state.toolCallIndex
                    state.toolCallIndex += 1
                    state.toolNameByIndex[callIndex] = block["name"] as? String
                    state.toolIDByIndex[callIndex] = block["id"] as? String
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": [
                                "tool_calls": [[
                                    "index": callIndex,
                                    "id": block["id"] as? String ?? "",
                                    "type": "function",
                                    "function": ["name": block["name"] as? String ?? "", "arguments": ""],
                                ]],
                            ],
                        ]],
                    ]]
                } else if blockType == "thinking" {
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": ["reasoning_content": block["thinking"] as? String ?? ""],
                        ]],
                    ]]
                }
            }
            return []
        case "content_block_delta":
            if let delta = parsed["delta"] as? [String: Any] {
                let deltaType = (delta["type"] as? String) ?? ""
                if deltaType == "text_delta" {
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": ["content": delta["text"] as? String ?? ""],
                        ]],
                    ]]
                } else if deltaType == "input_json_delta" {
                    let index = (parsed["index"] as? Int) ?? 0
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": [
                                "tool_calls": [[
                                    "index": index,
                                    "function": ["arguments": delta["partial_json"] as? String ?? ""],
                                ]],
                            ],
                        ]],
                    ]]
                } else if deltaType == "thinking_delta" {
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": ["reasoning_content": delta["thinking"] as? String ?? ""],
                        ]],
                    ]]
                }
            }
            return []
        case "message_delta":
            if let usage = parsed["usage"] as? [String: Any] {
                state.usage = usage
            }
            let stopReason = ((parsed["delta"] as? [String: Any])?["stop_reason"] as? String) ?? "end_turn"
            let finishReason = stopReason == "tool_use" ? "tool_calls" : "stop"
            return [[
                "choices": [[
                    "index": 0,
                    "delta": [:] as [String: Any],
                    "finish_reason": finishReason,
                ]],
            ]]
        case "message_stop":
            return []
        case "error":
            return []
        default:
            return []
        }
    }

    /// Builds the final OpenAI usage object from accumulated Anthropic usage.
    func anthropicStreamUsage(_ state: AnthropicStreamState) -> [String: Any]? {
        guard let usage = state.usage else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        return [
            "prompt_tokens": input,
            "completion_tokens": output,
            "total_tokens": input + output,
        ]
    }

    // MARK: - Google Gemini SSE

    /// Mutable stream state shared with the streaming task (serial access).
    final class GeminiStreamState: @unchecked Sendable {
        var usage: [String: Any]?
        var functionCallIndex = 0
    }

    /// Parses one Gemini SSE `data:` payload into chat.completion.chunk dicts.
    func translateGeminiSSEChunk(_ data: String, state: GeminiStreamState) -> [[String: Any]] {
        guard data != "[DONE]",
              let payloadData = data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return []
        }

        if let usage = parsed["usageMetadata"] as? [String: Any] {
            state.usage = usage
        }

        guard let candidates = parsed["candidates"] as? [[String: Any]], let first = candidates.first,
              let contentBlock = first["content"] as? [String: Any],
              let parts = contentBlock["parts"] as? [[String: Any]] else {
            return []
        }

        var chunks: [[String: Any]] = []
        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                chunks.append([
                    "choices": [[
                        "index": 0,
                        "delta": ["content": text],
                    ]],
                ])
            } else if let functionCall = part["functionCall"] as? [String: Any] {
                let index = state.functionCallIndex
                state.functionCallIndex += 1
                let args = (functionCall["args"] as? [String: Any]) ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                chunks.append([
                    "choices": [[
                        "index": 0,
                        "delta": [
                            "tool_calls": [[
                                "index": index,
                                "id": "call_\(UUID().uuidString.prefix(8))",
                                "type": "function",
                                "function": [
                                    "name": functionCall["name"] as? String ?? "",
                                    "arguments": String(data: argsData, encoding: .utf8) ?? "{}",
                                ],
                            ]],
                        ],
                    ]],
                ])
            }
        }
        return chunks
    }

    /// Builds the final OpenAI usage object from accumulated Gemini usage.
    func geminiStreamUsage(_ state: GeminiStreamState) -> [String: Any]? {
        guard let usage = state.usage else { return nil }
        let prompt = usage["promptTokenCount"] as? Int ?? 0
        let completion = usage["candidatesTokenCount"] as? Int ?? 0
        return [
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": prompt + completion,
        ]
    }
}
