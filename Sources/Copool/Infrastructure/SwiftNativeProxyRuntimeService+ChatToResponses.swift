import Foundation

/// Accumulates chat-completions stream deltas so they can be replayed as
/// Responses API events.
final class ChatToResponsesStreamState {
    let responseID: String
    let messageItemID: String
    var createdEmitted = false
    var messageItemOpened = false
    var model: String?
    var text = ""
    /// Tool calls keyed by the `choices[].delta.tool_calls[].index` they
    /// stream under; arguments arrive in fragments.
    var toolCalls: [Int: (callID: String, name: String, arguments: String)] = [:]
    var usage: [String: Any]?

    init() {
        responseID = "resp_" + ChatToResponsesStreamState.randomSuffix()
        messageItemID = "msg_" + ChatToResponsesStreamState.randomSuffix()
    }

    private static func randomSuffix() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

extension SwiftNativeProxyRuntimeService {
    /// Translates one chat-completions chunk into Responses API events.
    ///
    /// Codex only speaks the Responses API, but every non-`responses` provider
    /// adapter normalises upstream output into chat chunks. Without this final
    /// hop Codex receives `chat.completion.chunk` payloads it cannot parse and
    /// the turn fails with an idle-timeout waiting for SSE.
    func responsesEvents(
        forChatChunk chunk: [String: Any],
        state: ChatToResponsesStreamState,
        fallbackModel: String
    ) -> [Data] {
        var events: [Data] = []

        if let usage = chunk["usage"] as? [String: Any] {
            state.usage = usage
        }

        if !state.createdEmitted {
            state.createdEmitted = true
            events.append(responsesEvent("response.created", [
                "type": "response.created",
                "response": inProgressResponse(state: state, fallbackModel: fallbackModel),
            ]))
        }

        guard let choices = chunk["choices"] as? [Any],
              let choice = choices.first as? [String: Any],
              let delta = choice["delta"] as? [String: Any] else {
            return events
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            if !state.messageItemOpened {
                state.messageItemOpened = true
                // Codex rejects text deltas that arrive before the item they
                // belong to ("OutputTextDelta without active item").
                events.append(responsesEvent("response.output_item.added", [
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": [
                        "type": "message",
                        "id": state.messageItemID,
                        "role": "assistant",
                        "status": "in_progress",
                        "content": [],
                    ],
                ]))
                events.append(responsesEvent("response.content_part.added", [
                    "type": "response.content_part.added",
                    "item_id": state.messageItemID,
                    "output_index": 0,
                    "content_index": 0,
                    "part": ["type": "output_text", "text": "", "annotations": []],
                ]))
            }
            state.text += content
            events.append(responsesEvent("response.output_text.delta", [
                "type": "response.output_text.delta",
                "item_id": state.messageItemID,
                "output_index": 0,
                "content_index": 0,
                "delta": content,
            ]))
        }

        for rawToolCall in (delta["tool_calls"] as? [Any] ?? []) {
            guard let toolCall = rawToolCall as? [String: Any] else { continue }
            let index = (toolCall["index"] as? Int) ?? 0
            var entry = state.toolCalls[index] ?? (callID: "", name: "", arguments: "")
            if let callID = toolCall["id"] as? String, !callID.isEmpty {
                entry.callID = callID
            }
            if let function = toolCall["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    entry.name = name
                }
                if let arguments = function["arguments"] as? String {
                    entry.arguments += arguments
                }
            }
            state.toolCalls[index] = entry
        }

        return events
    }

    /// Emits the terminal Responses events for an accumulated chat stream.
    func responsesFinalEvents(
        state: ChatToResponsesStreamState,
        fallbackModel: String
    ) -> [Data] {
        var events: [Data] = []

        if !state.createdEmitted {
            state.createdEmitted = true
            events.append(responsesEvent("response.created", [
                "type": "response.created",
                "response": inProgressResponse(state: state, fallbackModel: fallbackModel),
            ]))
        }

        var output: [[String: Any]] = []
        var outputIndex = 0

        if !state.text.isEmpty {
            events.append(responsesEvent("response.output_text.done", [
                "type": "response.output_text.done",
                "item_id": state.messageItemID,
                "output_index": 0,
                "content_index": 0,
                "text": state.text,
            ]))
            let item: [String: Any] = [
                "type": "message",
                "id": state.messageItemID,
                "role": "assistant",
                "status": "completed",
                "content": [[
                    "type": "output_text",
                    "text": state.text,
                    "annotations": [],
                ]],
            ]
            events.append(responsesEvent("response.output_item.done", [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": item,
            ]))
            output.append(item)
            outputIndex += 1
        }

        for index in state.toolCalls.keys.sorted() {
            guard let call = state.toolCalls[index], !call.name.isEmpty else { continue }
            let callID = call.callID.isEmpty ? "call_\(state.responseID)_\(index)" : call.callID
            let item: [String: Any] = [
                "type": "function_call",
                "id": "fc_\(callID)",
                "call_id": callID,
                "name": call.name,
                "arguments": call.arguments.isEmpty ? "{}" : call.arguments,
                "status": "completed",
            ]
            events.append(responsesEvent("response.output_item.done", [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": item,
            ]))
            output.append(item)
            outputIndex += 1
        }

        var response = inProgressResponse(state: state, fallbackModel: fallbackModel)
        response["status"] = "completed"
        response["output"] = output
        response["usage"] = responsesUsage(from: state.usage)
        events.append(responsesEvent("response.completed", [
            "type": "response.completed",
            "response": response,
        ]))

        return events
    }

    private func inProgressResponse(
        state: ChatToResponsesStreamState,
        fallbackModel: String
    ) -> [String: Any] {
        [
            "id": state.responseID,
            "object": "response",
            "created_at": dateProvider.unixSecondsNow(),
            "status": "in_progress",
            "model": state.model ?? fallbackModel,
            "output": [],
        ]
    }

    /// Maps chat `usage` onto the Responses token names, defaulting to zero so
    /// Codex's token accounting always has a value to read.
    private func responsesUsage(from usage: [String: Any]?) -> [String: Any] {
        let input = (usage?["prompt_tokens"] as? Int) ?? (usage?["input_tokens"] as? Int) ?? 0
        let output = (usage?["completion_tokens"] as? Int) ?? (usage?["output_tokens"] as? Int) ?? 0
        return [
            "input_tokens": input,
            "input_tokens_details": ["cached_tokens": 0],
            "output_tokens": output,
            "output_tokens_details": ["reasoning_tokens": 0],
            "total_tokens": input + output,
        ]
    }

    private func responsesEvent(_ name: String, _ object: [String: Any]) -> Data {
        serializeSSEEvent(event: name, data: jsonString(object))
    }
}
