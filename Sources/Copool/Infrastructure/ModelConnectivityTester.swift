import Foundation

/// Result of probing one model end to end.
struct ModelTestResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case ok
        /// Reached the provider, which refused. `detail` is its own wording.
        case rejected(detail: String)
        /// Never reached the provider.
        case unreachable(detail: String)
    }

    var outcome: Outcome
    var at: Int64

    var isOK: Bool {
        if case .ok = outcome { return true }
        return false
    }

    var detail: String? {
        switch outcome {
        case .ok: return nil
        case .rejected(let detail), .unreachable(let detail): return detail
        }
    }
}

/// Checks whether a model actually answers, by sending a real turn through
/// the local proxy.
///
/// Probing the provider directly from here would re-implement the four
/// protocol adapters, the Antigravity User-Agent rule and the token refresh
/// that already live in the proxy — and would then be testing something other
/// than the path Codex uses. Going through the proxy tests the real thing.
struct ModelConnectivityTester: Sendable {
    private let session: URLSession
    private let paths: FileSystemPaths

    init(paths: FileSystemPaths, session: URLSession = .shared) {
        self.paths = paths
        self.session = session
    }

    func test(modelID: String) async -> ModelTestResult {
        let now = Int64(Date().timeIntervalSince1970)
        guard let baseURL = await resolveProxyBaseURL() else {
            return ModelTestResult(
                outcome: .unreachable(detail: L10n.tr("providers.model_test.proxy_down")),
                at: now
            )
        }
        guard let url = URL(string: "\(baseURL)/responses") else {
            return ModelTestResult(
                outcome: .unreachable(detail: L10n.tr("providers.model_test.proxy_down")),
                at: now
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = proxyAPIKey() {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        // Smallest turn that still exercises auth, routing and translation.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "stream": true,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Reply with the single word: ok"]],
            ]],
        ])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(status) else {
                return ModelTestResult(
                    outcome: .rejected(detail: Self.summarize(text, status: status)),
                    at: now
                )
            }
            // The proxy answers 200 and then reports upstream failures inside
            // the stream, so a status code alone is not proof of success.
            if text.contains("\"type\":\"response.completed\"") {
                return ModelTestResult(outcome: .ok, at: now)
            }
            return ModelTestResult(
                outcome: .rejected(detail: Self.summarize(text, status: status)),
                at: now
            )
        } catch {
            return ModelTestResult(outcome: .unreachable(detail: error.localizedDescription), at: now)
        }
    }

    /// Pulls the provider's own error text out of the proxy envelope so the
    /// user sees "quota exhausted" rather than "502".
    static func summarize(_ body: String, status: Int) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
                .prefix(200)
                .description
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "HTTP \(status)" }
        return "HTTP \(status): \(trimmed.prefix(160))"
    }

    private func proxyAPIKey() -> String? {
        guard let key = try? String(contentsOf: paths.proxyDaemonKeyPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Finds the running proxy.
    ///
    /// The managed block Copool writes into config.toml records the port it
    /// actually bound, which matters because the proxy falls back past 8787
    /// when that port is taken.
    private func resolveProxyBaseURL() async -> String? {
        if let recorded = recordedProxyBaseURL(), await isHealthy(recorded) {
            return recorded
        }
        for port in 8787...8797 {
            let candidate = "http://127.0.0.1:\(port)/v1"
            if await isHealthy(candidate) { return candidate }
        }
        return nil
    }

    private func recordedProxyBaseURL() -> String? {
        guard let text = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("base_url"), trimmed.contains("127.0.0.1") else { continue }
            guard let start = trimmed.firstIndex(of: "\""),
                  let end = trimmed.lastIndex(of: "\""), start < end else { continue }
            return String(trimmed[trimmed.index(after: start)..<end])
        }
        return nil
    }

    private func isHealthy(_ baseURL: String) async -> Bool {
        guard let root = baseURL.hasSuffix("/v1")
            ? String(baseURL.dropLast(3))
            : baseURL as String?,
            let url = URL(string: "\(root)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
