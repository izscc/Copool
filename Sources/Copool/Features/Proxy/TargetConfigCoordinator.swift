import Foundation
import SwiftUI

/// Wires the target config adapters into the runtime UI (AC-101/AC-007):
/// read-only detect/plan, explicit user-confirmed apply, and rollback.
/// Never writes without an explicit user action.
@MainActor
final class TargetConfigCoordinator: ObservableObject {
    private let codexAdapter: CodexTargetAdapter
    private let genericAdapter: TargetConfigFileAdapter

    /// Last plan result (diff summary), so the UI can show what apply would
    /// write before the user confirms.
    @Published private(set) var codexPlanSummary: String?
    @Published private(set) var lastAppliedTargetID: String?
    @Published var notice: String?

    init(paths: FileSystemPaths) {
        self.codexAdapter = CodexTargetAdapter(paths: paths)
        self.genericAdapter = TargetConfigFileAdapter(
            targetID: "codex",
            configPath: paths.codexConfigPath,
            stateRoot: paths.applicationSupportDirectory.appendingPathComponent("targets", isDirectory: true),
            managedProviderID: CodexTargetAdapter.managedProviderID,
            providerBlockName: "model_providers"
        )
    }

    /// Whether the Codex config currently carries the managed block.
    var codexManaged: Bool {
        let content = codexAdapter.detect()?.content ?? ""
        return content.contains(">>> copool managed")
    }

    /// Read-only plan: computes what apply would write (port 8787 — the
    /// default local proxy port) and keeps the diff for the UI.
    func planCodexApply() {
        let desired = codexAdapter.desiredConfig(port: 8787)
        let diff = codexAdapter.plan(to: desired)
        let beforeLines = diff.before?.content.split(separator: "\n").count ?? 0
        let afterLines = diff.after.content.split(separator: "\n").count
        codexPlanSummary = "config.toml: \(beforeLines) → \(afterLines) lines; \(diff.preservedUserLines.count) user line(s) preserved"
    }

    /// Explicit user action: apply the planned diff, then verify.
    func applyCodexPlan() {
        guard let summary = codexPlanSummary ?? (codexPlanSummaryIfNeeded()) else {
            notice = "Nothing planned yet — run Plan first."
            return
        }
        let desired = codexAdapter.desiredConfig(port: 8787)
        let diff = codexAdapter.plan(to: desired)
        do {
            try codexAdapter.apply(diff)
            let verified = codexAdapter.verify(diff)
            lastAppliedTargetID = "codex"
            notice = verified
                ? "Applied & verified: \(summary)"
                : "Applied but verification failed — use Rollback."
        } catch {
            notice = "Apply failed: \(error.localizedDescription)"
        }
    }

    /// Restores the pre-apply snapshot for the last applied diff.
    func rollbackCodex() {
        let desired = codexAdapter.desiredConfig(port: 8787)
        let diff = codexAdapter.plan(to: desired)
        do {
            try codexAdapter.rollback(diff)
            lastAppliedTargetID = nil
            notice = "Rolled back to the pre-apply config."
        } catch {
            notice = "Rollback failed: \(error.localizedDescription)"
        }
    }

    private func codexPlanSummaryIfNeeded() -> String? {
        planCodexApply()
        return codexPlanSummary
    }
}
