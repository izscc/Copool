import Foundation

/// Append-only ledger of route decisions (AC-012: explainable routing).
///
/// Each auto route decision is appended as one JSON line so the user (or the
/// Doctor) can audit why a request went to a specific provider: hard-filter
/// rejections, scores, and the final selection are all preserved. Keeps the
/// last 500 decisions; never contains secrets (traces only reference opaque
/// provider/instance ids and model ids).
final class RouteDecisionLedger: @unchecked Sendable {
    private let fileURL: URL
    private let io = NSLock()
    private let maxEntries = 500

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends a decision trace. Best-effort: failures are swallowed so
    /// routing is never blocked by audit logging.
    func append(_ trace: RouteDecisionTrace) {
        io.lock()
        defer { io.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let line = try encoder.encode(trace)
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data("\n".utf8))
            try trimIfNeeded()
        } catch {
            // Best-effort only.
        }
    }

    /// Latest decisions, newest first.
    func recent(limit: Int = 50) -> [RouteDecisionTrace] {
        io.lock()
        defer { io.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: 0x0A)
        let decoder = JSONDecoder()
        var traces: [RouteDecisionTrace] = []
        for line in lines.suffix(max(limit, maxEntries)) {
            if let trace = try? decoder.decode(RouteDecisionTrace.self, from: Data(line)) {
                traces.append(trace)
            }
        }
        return traces.reversed()
    }

    private func trimIfNeeded() throws {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > maxEntries else { return }
        let trimmed = lines.suffix(maxEntries).joined(separator: Data("\n".utf8))
        try Data(trimmed + Data("\n".utf8)).write(to: fileURL, options: .atomic)
    }
}
