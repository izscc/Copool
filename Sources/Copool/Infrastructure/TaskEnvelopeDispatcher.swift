import Foundation

/// Delegates user-confirmed `TaskEnvelope`s to the trusted executor
/// (AC-202). The execution boundary contract (AC-104) is: the dispatcher
/// never runs system commands itself — it forwards the confirmed intent to
/// the trusted Codex agent channel and records the delegation trail.
///
/// Flow: pending → confirm() → executing → completed (or failed). Rejected
/// envelopes are never delegated.
final class TaskEnvelopeDispatcher: @unchecked Sendable {
    private let trailURL: URL
    private let agentRouteRepository: AgentProfileRepository?
    private let io = NSLock()
    private var envelopes: [String: TaskEnvelope] = [:]

    init(trailURL: URL, agentRouteRepository: AgentProfileRepository? = nil) {
        self.trailURL = trailURL
        self.agentRouteRepository = agentRouteRepository
    }

    /// Confirms a pending envelope (user action) and delegates it to the
    /// trusted executor. Returns the envelope in `.executing` state, or the
    /// unmodified envelope when it is not pending.
    func confirmAndDelegate(_ envelope: TaskEnvelope) -> TaskEnvelope {
        io.lock()
        defer { io.unlock() }
        guard envelope.status == .pending else { return envelope }
        var confirmed = envelope
        confirmed.confirm()
        confirmed.status = .executing
        envelopes[confirmed.id] = confirmed
        appendTrail(confirmed)
        delegate(confirmed)
        return confirmed
    }

    /// Marks a delegated envelope completed (called by the executor channel
    /// when the forwarded task finishes).
    func complete(_ envelopeID: String) {
        io.lock()
        defer { io.unlock() }
        guard var envelope = envelopes[envelopeID], envelope.status == .executing else { return }
        envelope.status = .completed
        envelopes[envelopeID] = envelope
        appendTrail(envelope)
    }

    func fail(_ envelopeID: String, detail: String) {
        io.lock()
        defer { io.unlock() }
        // Only executing envelopes may fail (review: a pending envelope must
        // not skip the confirmation gate).
        guard var envelope = envelopes[envelopeID], envelope.status == .executing else { return }
        envelope.status = .failed(detail)
        envelopes[envelopeID] = envelope
        appendTrail(envelope)
    }

    // MARK: - Delegation

    /// Forwards the confirmed envelope to the trusted agent channel: appends
    /// a route event so the activity feed shows the delegation, and persists
    /// the envelope trail for audit.
    private func delegate(_ envelope: TaskEnvelope) {
        guard let agentRouteRepository else { return }
        let event = AgentRouteEvent(
            at: Int64(Date().timeIntervalSince1970),
            taskID: envelope.id,
            sessionName: envelope.sessionID,
            profileID: nil,
            profileName: "delegated-\(envelope.kind.rawValue)",
            model: nil,
            reasoningEffort: nil,
            resolved: true,
            reason: "TaskEnvelope confirmed by user and delegated to trusted executor (AC-202)"
        )
        _ = try? agentRouteRepository.appendRouteEvent(event)
    }

    private func appendTrail(_ envelope: TaskEnvelope) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let line = try encoder.encode(envelope)
            let fm = FileManager.default
            if !fm.fileExists(atPath: trailURL.path) {
                fm.createFile(atPath: trailURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: trailURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            // Best-effort audit trail.
        }
    }
}
