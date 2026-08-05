import Foundation

/// One completed third-party model call, appended to a JSONL ledger.
///
/// Mirrors codex-router's `usage-events.jsonl`: minimal facts only — never
/// prompts, responses, or credentials — so the ledger can power trend charts
/// without being a privacy liability.
struct UsageEvent: Codable, Equatable, Sendable {
    var meteringVersion: Int
    var at: Int64
    var model: String
    var providerID: String
    var providerName: String
    var status: Int
    var durationMs: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?

    init(
        model: String,
        providerID: String,
        providerName: String,
        status: Int,
        durationMs: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        at: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.meteringVersion = 1
        self.at = at
        self.model = String(model.prefix(160))
        self.providerID = providerID
        self.providerName = String(providerName.prefix(160))
        self.status = status
        self.durationMs = max(0, durationMs)
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// Daily token/request aggregation of the usage ledger for trend charts.
struct DailyUsageAggregate: Codable, Equatable, Sendable, Identifiable {
    /// Local calendar day, `yyyy-MM-dd`.
    var day: String
    var providerID: String
    var requests: Int
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int

    var id: String { "\(day)|\(providerID)" }
}

/// Appends usage events to a JSONL file and aggregates them by day.
///
/// Thread-safe; appends are atomic per line. Old events are pruned lazily on
/// write (keeps the last 90 days, mirroring codex-router's aggregation).
final class UsageEventLedger: @unchecked Sendable {
    private let path: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func record(_ event: UsageEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: path.path) {
                fileManager.createFile(atPath: path.path, contents: nil)
                Self.setPrivatePermissions(at: path)
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(line)\n".utf8))
            pruneLocked()
        } catch {
            // Usage telemetry must never interrupt or fail a model request.
        }
    }

    /// Events newer than `sinceDays`, newest first.
    func recentEvents(sinceDays: Int = 7, limit: Int = 5_000) -> [UsageEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: path) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Double(sinceDays * 86_400)
        let lines = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .reversed()
            .prefix(limit) ?? []
        return lines.compactMap { line in
            guard let event = try? JSONDecoder().decode(UsageEvent.self, from: Data(line.utf8)),
                  Double(event.at) >= cutoff else {
                return nil
            }
            return event
        }
    }

    /// Daily aggregates for the last `days` days, per provider.
    func dailyAggregates(days: Int = 7) -> [DailyUsageAggregate] {
        let events = recentEvents(sinceDays: days, limit: 20_000)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        var byDayProvider: [String: DailyUsageAggregate] = [:]
        for event in events {
            let day = formatter.string(from: Date(timeIntervalSince1970: Double(event.at)))
            let key = "\(day)|\(event.providerID)"
            var aggregate = byDayProvider[key] ?? DailyUsageAggregate(
                day: day,
                providerID: event.providerID,
                requests: 0,
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0
            )
            aggregate.requests += 1
            aggregate.inputTokens += event.inputTokens ?? 0
            aggregate.outputTokens += event.outputTokens ?? 0
            aggregate.totalTokens += event.totalTokens ?? 0
            byDayProvider[key] = aggregate
        }
        return byDayProvider.values.sorted { $0.day > $1.day }
    }

    private func pruneLocked() {
        guard let data = try? Data(contentsOf: path) else { return }
        let cutoff = Date().timeIntervalSince1970 - 90 * 86_400
        let lines = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline) ?? []
        let kept = lines.filter { line in
            guard let event = try? JSONDecoder().decode(UsageEvent.self, from: Data(line.utf8)) else {
                return false
            }
            return Double(event.at) >= cutoff
        }
        guard kept.count < lines.count else { return }
        let text = kept.map(String.init).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? text.write(to: path, atomically: true, encoding: .utf8)
        Self.setPrivatePermissions(at: path)
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
