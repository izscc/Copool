import Foundation

/// Target config adapter for the Codex target (config.toml + models cache).
///
/// Implements the `TargetConfigManaging` contract with the marked-block
/// strategy the app already uses (`# >>> copool managed >>>` …), plus the
/// backup/verify/rollback cycle Phase 4 requires (AC-007):
///   detect → plan(diff) → apply (backup + atomic write) → verify → rollback.
///
/// Rules:
///   - Only marked blocks and the managed provider table are rewritten;
///     user-owned lines are preserved verbatim.
///   - A managed scalar the user hand-edited (different value, unmarked) is
///     left alone, never overwritten.
///   - apply is atomic (tmp + rename) and writes a backup before touching the
///     file; rollback restores it.
final class CodexTargetAdapter: TargetConfigManaging, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let stateRoot: URL
    private let lock = NSLock()

    static let managedProviderID = "opencodex"

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.stateRoot = TargetStatePaths.directory(for: "codex", root: paths.applicationSupportDirectory.appendingPathComponent("targets", isDirectory: true))
    }

    // MARK: - TargetConfigManaging

    func detect() -> TargetConfigSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: paths.codexConfigPath.path),
              let text = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8) else {
            return nil
        }
        let modifiedAt = try? fileManager.attributesOfItem(atPath: paths.codexConfigPath.path)[.modificationDate] as? Date
        return TargetConfigSnapshot(targetID: "codex", content: text, modifiedAt: modifiedAt)
    }

    func plan(to desired: String) -> TargetConfigDiff {
        lock.lock()
        defer { lock.unlock() }
        let current = detect()
        let before = current
        let after = TargetConfigSnapshot(targetID: "codex", content: desired, modifiedAt: nil)
        return TargetConfigDiff(
            targetID: "codex",
            before: before,
            after: after,
            preservedUserLines: Self.userOwnedLines(in: current?.content ?? "")
        )
    }

    /// Builds the desired config.toml for the given proxy port, preserving
    /// everything outside the managed blocks.
    func desiredConfig(port: Int) -> String {
        let current = detect()?.content ?? ""
        let stripped = CodexModelsCacheService.stripManagedConfig(current)
        let provider = """
        # >>> copool managed provider >>>
        [model_providers.\(Self.managedProviderID)]
        name = "Copool"
        base_url = "http://127.0.0.1:\(port)/v1"
        wire_api = "responses"
        requires_openai_auth = true
        supports_websockets = false
        request_max_retries = 3
        stream_max_retries = 3
        stream_idle_timeout_ms = 600000
        # <<< copool managed provider <<<
        """
        return """
        # >>> copool managed >>>
        model_provider = "\(Self.managedProviderID)"
        # <<< copool managed <<<
        \(stripped)

        \(provider)
        """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func apply(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        let configPath = paths.codexConfigPath
        try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        // Backup the current file (or record absence).
        let backupPath = TargetStatePaths.configBackupPath(for: "codex", root: paths.applicationSupportDirectory.appendingPathComponent("targets", isDirectory: true))
        if fileManager.fileExists(atPath: configPath.path),
           let current = try? String(contentsOf: configPath, encoding: .utf8) {
            try current.write(to: backupPath, atomically: true, encoding: .utf8)
        } else if fileManager.fileExists(atPath: backupPath.path) {
            try? fileManager.removeItem(at: backupPath)
        }

        // Atomic write: tmp + rename.
        let tempURL = configPath.deletingLastPathComponent()
            .appendingPathComponent(".config.toml.tmp-\(UUID().uuidString)", isDirectory: false)
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
        guard let current = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8) else {
            return false
        }
        return current == diff.after.content
    }

    func rollback(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        let backupPath = TargetStatePaths.configBackupPath(for: "codex", root: paths.applicationSupportDirectory.appendingPathComponent("targets", isDirectory: true))
        guard fileManager.fileExists(atPath: backupPath.path) else {
            throw AppError.io("No backup to roll back to")
        }
        let backup = try String(contentsOf: backupPath, encoding: .utf8)
        try backup.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: backupPath)
    }

    /// Removes managed blocks entirely, restoring the config to its
    /// unmanaged state (uninstall / disable).
    func uninstall() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: paths.codexConfigPath.path) else { return }
        let text = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        let stripped = CodexModelsCacheService.stripManagedConfig(text)
        try stripped.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// Lines outside the managed blocks (the user's own configuration).
    static func userOwnedLines(in text: String) -> [String] {
        let stripped = CodexModelsCacheService.stripManagedConfig(text)
        return stripped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Stable fingerprint of a config for change detection.
    static func fingerprint(of text: String) -> String {
        ContentFingerprint.of(text)
    }
}
