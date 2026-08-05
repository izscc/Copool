import Foundation

/// Resolves Codex thread ids to human-readable session names from
/// `~/.codex/session_index.jsonl` (codex-router's `codex-session-names`,
/// adapted).
///
/// The index is rewritten by Codex whenever a session is renamed, so the
/// resolver caches by file modification date and reloads lazily.
struct CodexSessionResolver: Sendable {
    let indexPath: URL

    init(
        indexPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    ) {
        self.indexPath = indexPath
    }

    private final class State: @unchecked Sendable {
        static let shared = State()
        let lock = NSLock()
        var cachedPath: String?
        var cachedModifiedAt: Date?
        var namesByThreadID: [String: String] = [:]
    }

    /// Returns the session name for a thread id, or nil when unknown.
    func sessionName(threadID: String) -> String? {
        guard !threadID.isEmpty else { return nil }
        let state = State.shared
        state.lock.lock()
        defer { state.lock.unlock() }

        let modifiedAt = try? FileManager.default.attributesOfItem(atPath: indexPath.path)[.modificationDate] as? Date
        if state.cachedPath == indexPath.path && state.cachedModifiedAt == modifiedAt,
           !state.namesByThreadID.isEmpty {
            return state.namesByThreadID[threadID]
        }

        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: indexPath) {
            for line in String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline) ?? [] {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? String,
                      let name = object["thread_name"] as? String,
                      !id.isEmpty, !name.isEmpty else {
                    continue
                }
                names[id] = name
            }
        }
        state.cachedPath = indexPath.path
        state.cachedModifiedAt = modifiedAt
        state.namesByThreadID = names
        return names[threadID]
    }

    /// The thread-id uuid embedded in a header value, if any.
    static func threadID(in headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        // UUID v7 style: 8-4-4-4-12 hex, case-insensitive.
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: headerValue, range: NSRange(headerValue.startIndex..., in: headerValue)),
              let range = Range(match.range, in: headerValue) else {
            return nil
        }
        return String(headerValue[range])
    }
}
