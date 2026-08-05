import Foundation

/// Generic marked-block target config adapter for Beta target bindings
/// (Cursor, opencode). Each binding is fully isolated: its own state
/// directory, its own config file, its own managed provider id, and the same
/// detect/plan/apply/verify/rollback contract as the Codex adapter.
///
/// Beta scope: config management only — no process control, no listener
/// wiring yet. The binding registers its own TargetBinding so nothing is
/// shared implicitly (AC-008).
final class TargetConfigFileAdapter: TargetConfigManaging, @unchecked Sendable {
    let targetID: String
    private let configPath: URL
    private let stateDirectory: URL
    private let managedProviderID: String
    private let providerBlockName: String
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        targetID: String,
        configPath: URL,
        stateRoot: URL,
        managedProviderID: String,
        providerBlockName: String,
        fileManager: FileManager = .default
    ) {
        self.targetID = targetID
        self.configPath = configPath
        self.stateDirectory = stateRoot.appendingPathComponent(targetID, isDirectory: true)
        self.managedProviderID = managedProviderID
        self.providerBlockName = providerBlockName
        self.fileManager = fileManager
    }

    // MARK: - TargetConfigManaging

    func detect() -> TargetConfigSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: configPath.path),
              let text = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }
        let modifiedAt = try? fileManager.attributesOfItem(atPath: configPath.path)[.modificationDate] as? Date
        return TargetConfigSnapshot(targetID: targetID, content: text, modifiedAt: modifiedAt)
    }

    func plan(to desired: String) -> TargetConfigDiff {
        lock.lock()
        defer { lock.unlock() }
        return TargetConfigDiff(
            targetID: targetID,
            before: detect(),
            after: TargetConfigSnapshot(targetID: targetID, content: desired, modifiedAt: nil),
            preservedUserLines: TargetConfigFileAdapter.userOwnedLines(in: detect()?.content ?? "")
        )
    }

    /// Desired content for a loopback provider block, preserving everything
    /// outside the marked region.
    func desiredConfig(port: Int, baseURLTemplate: String) -> String {
        let current = detect()?.content ?? ""
        let stripped = TargetConfigFileAdapter.stripMarkedBlocks(current, blockNames: ["managed", "managed-provider"])
        let provider = String(
            format: """
            # >>> copool-managed-provider >>>
            [%@]
            name = "%@"
            base_url = "%@"
            # <<< copool-managed-provider <<<
            """,
            managedProviderID,
            providerBlockName,
            String(format: baseURLTemplate, port)
        )
        return """
        # >>> copool-managed >>>
        # Managed by Copool vNext (binding %@)
        # <<< copool-managed <<<
        \(stripped)

        \(provider)
        """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func apply(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let backupPath = stateDirectory.appendingPathComponent("config-backup")
        if fileManager.fileExists(atPath: configPath.path),
           let current = try? String(contentsOf: configPath, encoding: .utf8) {
            try current.write(to: backupPath, atomically: true, encoding: .utf8)
        } else if fileManager.fileExists(atPath: backupPath.path) {
            try? fileManager.removeItem(at: backupPath)
        }
        let tempURL = configPath.deletingLastPathComponent()
            .appendingPathComponent(".\(configPath.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        try diff.after.content.write(to: tempURL, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: configPath.path) {
            _ = try fileManager.replaceItemAt(configPath, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: configPath)
        }
    }

    func verify(_ diff: TargetConfigDiff) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
        return current == diff.after.content
    }

    func rollback(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        let backupPath = stateDirectory.appendingPathComponent("config-backup")
        guard fileManager.fileExists(atPath: backupPath.path) else {
            throw AppError.io("No backup to roll back to for target \(targetID)")
        }
        let backup = try String(contentsOf: backupPath, encoding: .utf8)
        try backup.write(to: configPath, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: backupPath)
    }

    func uninstall() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: configPath.path) else { return }
        let text = try String(contentsOf: configPath, encoding: .utf8)
        let stripped = TargetConfigFileAdapter.stripMarkedBlocks(text, blockNames: ["managed", "managed-provider"])
        try stripped.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Marked block helpers

    /// Removes copool-managed blocks (same contract as CodexModelsCacheService).
    static func stripMarkedBlocks(_ text: String, blockNames: [String]) -> String {
        var result = text
        for name in blockNames {
            let start = "# >>> \(name) >>>"
            let end = "# <<< \(name) <<<"
            while let startRange = result.range(of: start),
                  let endRange = result.range(of: end, range: startRange.upperBound..<result.endIndex) {
                result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            }
        }
        return result
    }

    static func userOwnedLines(in text: String) -> [String] {
        stripMarkedBlocks(text, blockNames: ["managed", "managed-provider"])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
