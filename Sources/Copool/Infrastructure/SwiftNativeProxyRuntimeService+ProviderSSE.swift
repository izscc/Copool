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
        /// Anthropic content-block 序号 → OpenAI tool_call 序号（FR-PRO-06）。
        ///
        /// 两者**不是同一个编号空间**：Anthropic 的 `index` 数的是所有内容块
        /// （text、thinking、tool_use 混在一起连续编号），OpenAI 的
        /// `tool_calls[].index` 只数工具调用。一条"先说一句话再调工具"的回复
        /// 里，tool_use 的 block index 是 1 而 tool_call index 是 0。
        ///
        /// 不做这层映射的后果很隐蔽：`content_block_start` 用 tool_call 序号
        /// 发出 name 和 id，`input_json_delta` 用 block 序号发出 arguments，
        /// 下游按 index 累积，于是得到一个有名字没参数的工具调用、外加一个
        /// 有参数没名字的幽灵调用。两个都调不起来，而且报错信息不会指向这里。
        var toolCallIndexByBlockIndex: [Int: Int] = [:]
        /// 各 tool_call 的参数片段累积。Anthropic 把一个 JSON 对象拆成任意
        /// 多个 `partial_json` 片段，单个片段几乎必然不是合法 JSON
        /// （`{"pa` 这种），**拼完再解析**是唯一正确的做法。
        var toolArgumentsByCallIndex: [Int: String] = [:]
        /// 已经发出 `content_block_start` 的 thinking 块序号，用于在下游不
        /// 支持推理内容时整块丢弃而不是折进 content。
        var thinkingBlockIndexes: Set<Int> = []
    }

    /// Parses one Anthropic SSE event into chat.completion.chunk dictionaries.
    ///
    /// - Parameter emitsReasoning: 目标协议是否支持独立的推理字段。为 false
    ///   时 thinking 内容**整块丢弃**，绝不折进 `content`——把思维链混进正文
    ///   会污染用户可见输出，而且下游没有任何办法把它再分离出来。
    func translateAnthropicSSEEvent(
        _ event: SSEEvent,
        state: AnthropicStreamState,
        emitsReasoning: Bool = true
    ) -> [[String: Any]] {
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
                    // 记下这个 block 属于哪个 tool_call，供后续
                    // input_json_delta 查表。
                    state.toolCallIndexByBlockIndex[index] = callIndex
                    state.toolArgumentsByCallIndex[callIndex] = ""
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
                    state.thinkingBlockIndexes.insert(index)
                    guard emitsReasoning else { return [] }
                    let seed = block["thinking"] as? String ?? ""
                    guard !seed.isEmpty else { return [] }
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": ["reasoning_content": seed],
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
                    let blockIndex = (parsed["index"] as? Int) ?? 0
                    // 查表拿 tool_call 序号。查不到说明上游发了一个我们没见过
                    // content_block_start 的块——按 block 序号原样透传是唯一
                    // 还能自洽的兜底。
                    let callIndex = state.toolCallIndexByBlockIndex[blockIndex] ?? blockIndex
                    let fragment = delta["partial_json"] as? String ?? ""
                    state.toolArgumentsByCallIndex[callIndex, default: ""] += fragment
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": [
                                "tool_calls": [[
                                    "index": callIndex,
                                    "function": ["arguments": fragment],
                                ]],
                            ],
                        ]],
                    ]]
                } else if deltaType == "thinking_delta" {
                    guard emitsReasoning else { return [] }
                    return [[
                        "choices": [[
                            "index": 0,
                            "delta": ["reasoning_content": delta["thinking"] as? String ?? ""],
                        ]],
                    ]]
                } else if deltaType == "signature_delta" {
                    // extended thinking 的签名，对 OpenAI 形状没有对应字段，
                    // 也不该出现在用户可见输出里。丢弃。
                    return []
                }
            }
            return []
        case "message_delta":
            if let usage = parsed["usage"] as? [String: Any] {
                state.usage = usage
            }
            let stopReason = ((parsed["delta"] as? [String: Any])?["stop_reason"] as? String) ?? "end_turn"
            let finishReason = Self.openAIFinishReason(forAnthropicStopReason: stopReason)
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

    /// Anthropic `stop_reason` → OpenAI `finish_reason`（FR-PRO-06）。
    ///
    /// `max_tokens` 必须映射成 `length` 而不是 `stop`：客户端靠这个区分
    /// "模型说完了"和"被截断了"，映射错会让被截断的回复看起来是完整的。
    nonisolated static func openAIFinishReason(forAnthropicStopReason stopReason: String) -> String {
        switch stopReason {
        case "tool_use": return "tool_calls"
        case "max_tokens": return "length"
        case "refusal": return "content_filter"
        default: return "stop"
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
              let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return []
        }

        // Antigravity's internal CloudCode endpoint nests the Gemini payload
        // under `response` (alongside traceId/metadata); the public
        // generativelanguage API returns it at the top level.
        let parsed = (root["response"] as? [String: Any]) ?? root

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
                let callID = "call_\(UUID().uuidString.prefix(8))"
                if let signature = (part["thoughtSignature"] as? String)
                    ?? (part["thought_signature"] as? String)
                    ?? (contentBlock["thoughtSignature"] as? String) {
                    rememberGeminiThoughtSignature(signature, forCallID: callID)
                }
                chunks.append([
                    "choices": [[
                        "index": 0,
                        "delta": [
                            "tool_calls": [[
                                "index": index,
                                "id": callID,
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

extension SwiftNativeProxyRuntimeService {
    /// opencodex's fallback signature, accepted by Gemini when the original is
    /// unavailable (e.g. a conversation resumed after a proxy restart).
    static let defaultGeminiThoughtSignature = "EocDCoQDARFNMg/wQatFS7RFDS/KgCjQ6PF5Ftu7blOIEB1GIMFDxWS15lf54PftREjCt22MZCJUvG8TJlo7t2Zxd7PI6ZaJUykSf/mgzo++cO8oirHVi7QETe5HrdvR9Y7aH09xNADrqwtADWS/Jr/JRKNWGEFlbBf0hRhp/U/WzJQsek8Dg/wHPeWV7VEESUz9SRVTVkN4NuPAmhtQvW5ekCQjrcQagIaYhd/dFIrz5We5WZYXlLefPT4FHI/5AP7dwWhv8ZK8uYwdJ1twAzsjF7HgVc5mJhtlTjY2blQb7jkfnw5oAKX7Stl6JuZNMQ0yiB3RrpLCcIxb377FjKpeKxob37SHwzfr1qFQsaVJe1m2SySbQqmoYzDRx956QPT0dgoztsSPrrqSFutXGOcGkEc9xj198GPhn5R2JfiGBb6rjGVgFjGlr9dhzZOWSrNzwlkpKJTSA5OcXDmsJMRfWRMhovJMaYTITR2UwEzNc75nKHL/Xh/Rsh4/+IRQSagYbV1luM8yYA=="

    /// Retains the signature for a tool call, bounded so a long-lived proxy
    /// cannot grow the map without limit.
    func rememberGeminiThoughtSignature(_ signature: String, forCallID callID: String) {
        if geminiThoughtSignatures.count > 500 {
            geminiThoughtSignatures.removeAll(keepingCapacity: true)
        }
        geminiThoughtSignatures[callID] = signature
    }
}
