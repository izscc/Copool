import Foundation
import SwiftUI

@MainActor
final class TargetConfigCoordinator: ObservableObject {
    private let adapters: [String: any TargetConfigManaging]
    private var plannedDiffs: [String: TargetConfigDiff] = [:]

    @Published private(set) var codexPlanSummary: String?
    @Published private(set) var targetPlanSummaries: [String: String] = [:]
    @Published private(set) var lastAppliedTargetID: String?
    @Published var notice: String?

    init(paths: FileSystemPaths) {
        let stateRoot = paths.applicationSupportDirectory.appendingPathComponent("targets", isDirectory: true)
        let codex = CodexTargetAdapter(paths: paths)
        let cursor = TargetJSONConfigAdapter(
            targetID: "cursor",
            configPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/copool.json"),
            stateRoot: stateRoot
        )
        let opencode = TargetJSONConfigAdapter(
            targetID: "opencode",
            configPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/copool.json"),
            stateRoot: stateRoot
        )
        self.adapters = ["codex": codex, "cursor": cursor, "opencode": opencode]
    }

    var codexManaged: Bool {
        adapters["codex"]?.detect()?.content.contains(">>> copool managed") == true
    }

    func planCodexApply(port: Int = 8787) {
        guard let adapter = adapters["codex"] as? CodexTargetAdapter else { return }
        let diff = adapter.plan(to: adapter.desiredConfig(port: port))
        plannedDiffs["codex"] = diff
        let summary = summary(for: diff)
        codexPlanSummary = summary
        targetPlanSummaries["codex"] = summary
    }

    func planTarget(_ targetID: String, port: Int) {
        guard let adapter = adapters[targetID] as? TargetJSONConfigAdapter else { return }
        let diff = adapter.plan(to: adapter.desiredConfig(port: port))
        plannedDiffs[targetID] = diff
        targetPlanSummaries[targetID] = summary(for: diff)
    }

    func applyCodexPlan(port: Int = 8787) {
        applyTarget("codex", port: port)
    }

    func applyTarget(_ targetID: String, port: Int) {
        guard let adapter = adapters[targetID] else {
            notice = "Unknown target: \(targetID)"
            return
        }
        if plannedDiffs[targetID] == nil {
            if targetID == "codex" { planCodexApply(port: port) }
            else { planTarget(targetID, port: port) }
        }
        guard let diff = plannedDiffs[targetID] else { return }
        do {
            try adapter.apply(diff)
            guard adapter.verify(diff) else {
                notice = "\(targetID) applied but verification failed — use Rollback."
                return
            }
            lastAppliedTargetID = targetID
            notice = "\(targetID) applied and verified: \(summary(for: diff))"
        } catch {
            notice = "\(targetID) apply failed: \(error.localizedDescription)"
        }
    }

    func rollbackCodex() {
        rollbackTarget("codex")
    }

    func rollbackTarget(_ targetID: String) {
        guard let adapter = adapters[targetID], let diff = plannedDiffs[targetID] else {
            notice = "No planned change for \(targetID)."
            return
        }
        do {
            try adapter.rollback(diff)
            plannedDiffs.removeValue(forKey: targetID)
            lastAppliedTargetID = nil
            notice = "\(targetID) rolled back."
        } catch {
            notice = "\(targetID) rollback failed: \(error.localizedDescription)"
        }
    }

    func uninstallTarget(_ targetID: String) {
        guard let adapter = adapters[targetID] else { return }
        do {
            try adapter.uninstall()
            plannedDiffs.removeValue(forKey: targetID)
            notice = "\(targetID) unmanaged configuration removed."
        } catch {
            notice = "\(targetID) uninstall failed: \(error.localizedDescription)"
        }
    }

    private func summary(for diff: TargetConfigDiff) -> String {
        let before = diff.before?.content.split(separator: "\n").count ?? 0
        let after = diff.after.content.split(separator: "\n").count
        return "lines \(before) → \(after); preserved \(diff.preservedUserLines.count) user field(s)"
    }
}
