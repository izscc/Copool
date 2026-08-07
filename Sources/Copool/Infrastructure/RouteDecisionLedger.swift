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

    /// 回填一条 trace 的请求结局（FR-RTE-05：耗时与结果两列）。
    ///
    /// 为什么要改已落盘的行，而不是再 append 一条完成记录：路由 tab 是一份
    /// "每条请求一行"的清单，追加会让同一个请求出现两行——用户看到的请求数
    /// 是真实数量的两倍，而且两行的模型名一样、时间差几百毫秒，没法分辨哪行
    /// 才是结论。
    ///
    /// 读改写整份文件在这里是可以接受的：文件本来就封顶 500 行，`trimIfNeeded`
    /// 也已经在做同样的事。best-effort，失败不影响请求。
    func complete(
        requestID: String,
        durationMS: Int,
        outcome: RouteDecisionTrace.Outcome,
        httpStatus: Int? = nil,
        fallbackAttempts: [String] = [],
        failureChain: [String] = []
    ) {
        io.lock()
        defer { io.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var lines = data.split(separator: UInt8(0x0A)).map { Data($0) }
        // 从后往前找：同一个 requestID 理论上只有一条，但真出现重复时
        // 最新的那条才是当前请求。
        guard let index = lines.lastIndex(where: { line in
            guard let trace = try? decoder.decode(RouteDecisionTrace.self, from: line) else { return false }
            return trace.requestID == requestID
        }) else { return }

        guard var trace = try? decoder.decode(RouteDecisionTrace.self, from: lines[index]) else { return }
        trace.durationMS = durationMS
        trace.outcome = outcome
        trace.httpStatus = httpStatus
        if !fallbackAttempts.isEmpty { trace.fallbackAttempts = fallbackAttempts }
        if !failureChain.isEmpty { trace.failureChain = failureChain }
        guard let encoded = try? encoder.encode(trace) else { return }
        lines[index] = encoded
        let joined = lines.joined(separator: Data("\n".utf8))
        try? Data(joined + Data("\n".utf8)).write(to: fileURL, options: .atomic)
    }

    /// Latest decisions, newest first.
    func recent(limit: Int = 50) -> [RouteDecisionTrace] {
        io.lock()
        defer { io.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: 0x0A)
        let decoder = JSONDecoder()
        var traces: [RouteDecisionTrace] = []
        let boundedLimit = min(max(limit, 0), maxEntries)
        for line in lines.suffix(boundedLimit) {
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
