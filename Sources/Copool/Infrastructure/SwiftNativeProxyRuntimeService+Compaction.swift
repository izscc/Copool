import Foundation

/// Routed compaction support (codex-router's `kcr1:` payload, adapted).
///
/// Codex compresses long sessions through `/responses/compact` (v1) or a
/// trailing `compaction_trigger` input item (v2). External chat providers
/// cannot create OpenAI's opaque encrypted compaction payload, so the proxy
/// asks the routed model for a continuation summary and wraps it in a
/// router-owned `kcr1:` payload. On replay that payload is converted back to
/// a plain continuation message.
extension SwiftNativeProxyRuntimeService {
    static let compactionPrefix = "kcr1:"
    static let summaryPrefix = "<!-- COMPACTION SUMMARY (kcr1) -->"
    static let compactPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another language model that will resume the task.

    Focus on the current state of the task, decisions made, and all important information needed to continue. Include:
    - Current task and progress
    - Key decisions and their rationale
    - Important technical details, file paths, and code structure
    - Any constraints or requirements discovered
    - Next steps to take

    Be thorough but concise. Do not include filler.
    """

    // MARK: - Detection

    /// Whether this responses request is a compaction, and which version.
    static func isCompactionRequest(path: String, object: [String: Any]) -> (v1: Bool, v2: Bool) {
        let v1 = path.hasSuffix("/responses/compact") || path.hasSuffix("/v1/responses/compact")
        let v2: Bool = {
            guard let input = object["input"] as? [Any],
                  let last = input.last as? [String: Any] else {
                return false
            }
            return (last["type"] as? String) == "compaction_trigger"
        }()
        return (v1, v2)
    }

    // MARK: - Handling

    func handleCompactionRequest(
        route: ThirdPartyRoute,
        object: [String: Any],
        v1: Bool,
        v2: Bool
    ) async -> HTTPResponse {
        let result = await summarizeCompaction(route: route, object: object)
        guard let summary = result.summary else {
            let status = result.statusCode ?? 502
            let message = result.errorMessage ?? "Compaction failed"
            return jsonError(statusCode: status, message: message)
        }

        if v2 {
            let item: [String: Any] = [
                "type": "compaction",
                "id": "cmp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "encrypted_content": Self.encodeSummary(summary),
            ]
            let wantsStream = (object["stream"] as? Bool) ?? true
            if wantsStream {
                return Self.compactionSSEResponse(model: (object["model"] as? String) ?? route.clientModelID, item: item)
            }
            let snapshot = Self.compactionSnapshot(model: (object["model"] as? String) ?? route.clientModelID, item: item)
            return HTTPResponse.json(statusCode: 200, object: snapshot)
        }

        // v1: return the compacted input (recent user messages + summary).
        let output = Self.compactOutput(input: object["input"], summary: summary)
        return HTTPResponse.json(statusCode: 200, object: ["output": output])
    }

    // MARK: - Summary generation

    private struct CompactionSummaryResult {
        var summary: String?
        var statusCode: Int?
        var errorMessage: String?
    }

    /// Asks the routed model for a continuation summary (non-streaming, no
    /// tools), mirroring codex-router's `summarize`.
    private func summarizeCompaction(route: ThirdPartyRoute, object: [String: Any]) async -> CompactionSummaryResult {
        // Reuse the chat translation so any provider protocol (chat,
        // anthropic, google) gets its native shape.
        var chat = convertResponsesRequestToChat(object)
        var messages = (chat["messages"] as? [[String: Any]]) ?? []
        messages.append(["role": "user", "content": Self.compactPrompt])
        chat["messages"] = messages
        chat["stream"] = false
        chat["tools"] = NSNull()
        chat["tool_choice"] = "none"
        chat.removeValue(forKey: "previous_response_id")

        do {
            let response: UpstreamResponse
            if route.protocolKind == .google {
                // Antigravity's internal CloudCode endpoint only answers the
                // streaming surface; aggregate the SSE text instead.
                chat["stream"] = true
                var upstream = try await openThirdPartyStreamingRequest(
                    route: route,
                    payload: chat,
                    downstreamHeaders: [:]
                )
                if upstream.statusCode == 401 || upstream.statusCode == 403,
                   let refreshed = await refreshProviderTokenIfNeeded(route: route) {
                    var discarded = 0
                    for try await _ in upstream.bytes {
                        discarded += 1
                        if discarded > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes { break }
                    }
                    upstream = try await openThirdPartyStreamingRequest(
                        route: route,
                        payload: chat,
                        downstreamHeaders: [:],
                        apiKeyOverride: refreshed
                    )
                }
                guard upstream.statusCode >= 200 && upstream.statusCode < 300 else {
                    var buffered = Data()
                    for try await byte in upstream.bytes {
                        buffered.append(byte)
                        if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseDecodedBytes { break }
                    }
                    let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                    return CompactionSummaryResult(
                        summary: nil,
                        statusCode: upstream.statusCode,
                        errorMessage: truncateForError(bodyText, maxLength: 120)
                    )
                }
                let text = await collectGeminiStreamText(upstream)
                guard !text.isEmpty else {
                    return CompactionSummaryResult(
                        summary: nil,
                        statusCode: 502,
                        errorMessage: "Compact response was empty"
                    )
                }
                return CompactionSummaryResult(summary: text)
            }

            response = try await sendThirdPartyRequest(
                route: route,
                payload: chat,
                downstreamHeaders: [:]
            )
            guard response.statusCode >= 200 && response.statusCode < 300 else {
                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                return CompactionSummaryResult(
                    summary: nil,
                    statusCode: response.statusCode,
                    errorMessage: truncateForError(bodyText, maxLength: 120)
                )
            }
            let text = Self.extractResponseText(from: response.body)
            guard !text.isEmpty else {
                return CompactionSummaryResult(
                    summary: nil,
                    statusCode: 502,
                    errorMessage: "Compact response was empty"
                )
            }
            return CompactionSummaryResult(summary: text)
        } catch {
            return CompactionSummaryResult(summary: nil, statusCode: 502, errorMessage: error.localizedDescription)
        }
    }

    /// Pulls text out of a chat completion or Responses object.
    static func extractResponseText(from body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        if let outputText = object["output_text"] as? String {
            return outputText
        }
        var texts: [String] = []
        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let type = part["type"] as? String,
                       ["output_text", "text"].contains(type),
                       let text = part["text"] as? String {
                        texts.append(text)
                    }
                }
            }
        }
        if let choices = object["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            texts.append(content)
        }
        return texts.joined(separator: "\n")
    }

    // MARK: - Payload encode/decode

    static func encodeSummary(_ summary: String) -> String {
        compactionPrefix + Data(summary.utf8).base64EncodedString()
    }

    static func decodeSummary(_ value: String?) -> String? {
        guard let value, value.hasPrefix(compactionPrefix) else { return nil }
        let base64 = String(value.dropFirst(compactionPrefix.count))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Converts a `kcr1:` compaction item back into a plain message item.
    static func replayCompactionItem(_ item: [String: Any]) -> [String: Any]? {
        guard let encrypted = item["encrypted_content"] as? String else { return nil }
        let summary = decodeSummary(encrypted)
        let text = summary.map { "\(summaryPrefix)\n\n\($0)" }
            ?? "[Earlier conversation history was compacted in an unreadable format.]"
        return ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]
    }

    // MARK: - v1 output

    /// Aggregates the text of a Gemini SSE stream (nested `response` shape for
    /// Antigravity, top-level for the public API).
    private func collectGeminiStreamText(_ upstream: UpstreamStreamingResponse) async -> String {
        var text = ""
        let decoder = SSEStreamDecoder()
        do {
            for try await byte in upstream.bytes {
                let events = decoder.push(data: Data([byte]), isFinal: false)
                for event in events where event.data != "[DONE]" {
                    guard let payloadData = event.data.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                        continue
                    }
                    let parsed = (root["response"] as? [String: Any]) ?? root
                    guard let candidates = parsed["candidates"] as? [[String: Any]],
                          let first = candidates.first,
                          let contentBlock = first["content"] as? [String: Any],
                          let parts = contentBlock["parts"] as? [[String: Any]] else {
                        continue
                    }
                    for part in parts {
                        if let partText = part["text"] as? String {
                            text += partText
                        }
                    }
                }
            }
            // Flush any trailing event.
            let tail = decoder.push(data: Data(), isFinal: true)
            for event in tail where event.data != "[DONE]" {
                guard let payloadData = event.data.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    continue
                }
                let parsed = (root["response"] as? [String: Any]) ?? root
                guard let candidates = parsed["candidates"] as? [[String: Any]],
                      let first = candidates.first,
                      let contentBlock = first["content"] as? [String: Any],
                      let parts = contentBlock["parts"] as? [[String: Any]] else {
                    continue
                }
                for part in parts {
                    if let partText = part["text"] as? String {
                        text += partText
                    }
                }
            }
        } catch {
            return text
        }
        return text
    }

    /// Keeps the most recent user messages within an 80k character budget and
    /// appends the summary as the final message (codex-router `compactOutput`).
    static func compactOutput(input: Any?, summary: String) -> [[String: Any]] {
        let budget = 80_000
        let messages = extractUserMessages(input)
        var selected: [String] = []
        var remaining = budget
        for value in messages.reversed() {
            if remaining <= 0 { break }
            if value.count <= remaining {
                selected.append(value)
                remaining -= value.count
            } else {
                selected.append(String(value.suffix(remaining)))
                remaining = 0
            }
        }
        selected.reverse()
        var output: [[String: Any]] = selected.map {
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": $0]]]
        }
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(no summary available)"
            : "\(summaryPrefix)\n\(summary)"
        output.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": summaryText]]])
        return output
    }

    private static func extractUserMessages(_ input: Any?) -> [String] {
        guard let input = input as? [Any] else { return [] }
        var texts: [String] = []
        for item in input {
            guard let item = item as? [String: Any],
                  (item["type"] as? String) == "message" else { continue }
            let role = (item["role"] as? String) ?? "user"
            guard role == "user" else { continue }
            if let content = item["content"] as? String {
                texts.append(content)
            } else if let parts = item["content"] as? [[String: Any]] {
                var text = ""
                for part in parts {
                    if (part["type"] as? String) == "input_text",
                       let partText = part["text"] as? String {
                        text += partText
                    }
                }
                if !text.isEmpty { texts.append(text) }
            }
        }
        return texts
    }

    // MARK: - Responses shapes

    static func compactionSnapshot(model: String, item: [String: Any]) -> [String: Any] {
        [
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": model,
            "output": [item],
            "usage": NSNull(),
        ]
    }

    static func compactionSSEResponse(model: String, item: [String: Any]) -> HTTPResponse {
        let created = [
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "in_progress",
            "model": model,
            "output": [],
        ] as [String: Any]
        var completed = created
        completed["status"] = "completed"
        completed["output"] = [item]

        var events = ""
        let lines: [(String, [String: Any])] = [
            ("response.created", ["response": created]),
            ("response.output_item.done", ["output_index": 0, "item": item]),
            ("response.completed", ["response": completed]),
        ]
        for (index, pair) in lines.enumerated() {
            let (type, data) = pair
            var payload = data
            payload["type"] = type
            payload["sequence_number"] = index
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}"
            events += "event: \(type)\ndata: \(json)\n\n"
        }
        events += "data: [DONE]\n\n"
        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache",
            ],
            body: Data(events.utf8)
        )
    }
}
