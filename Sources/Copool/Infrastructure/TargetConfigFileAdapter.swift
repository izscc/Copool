import Foundation

/// Marked-block target adapter for Cursor and opencode. Each binding owns
/// its config file, state directory, provider id and rollback receipt.
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
        return detectLocked()
    }

    /// 不加锁的 detect。NSLock 不可重入：任何已持锁的方法都必须走这里，
    /// 直接调 `detect()` 会自锁死。
    private func detectLocked() -> TargetConfigSnapshot? {
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
        // 只读一次盘：两次 detect() 之间文件可能被目标应用改写，
        // before 与 preservedUserLines 必须来自同一份快照。
        let before = detectLocked()
        return TargetConfigDiff(
            targetID: targetID,
            before: before,
            after: TargetConfigSnapshot(targetID: targetID, content: desired, modifiedAt: nil),
            preservedUserLines: TargetConfigFileAdapter.userOwnedLines(in: before?.content ?? "")
        )
    }

    /// Desired content for a loopback provider block, preserving everything
    /// outside the marked region.
    func desiredConfig(port: Int, baseURLTemplate: String) -> String {
        let current = detect()?.content ?? ""
        let stripped = TargetConfigFileAdapter.stripMarkedBlocks(
            current,
            blockNames: TargetConfigFileAdapter.managedBlockNames
        )
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
        # Managed by Copool vNext (binding \(targetID))
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
        // 只比托管块。目标应用会在写回时重排键、补默认值，用户也随时可能
        // 改块外的内容——全文比较会把这些正常改动判成"写入失败"，
        // 进而触发不必要的回滚。我们只对自己写的那几行负责。
        let expected = TargetConfigFileAdapter.markedBlocks(in: diff.after.content)
        guard !expected.isEmpty else { return true }
        return TargetConfigFileAdapter.markedBlocks(in: current) == expected
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
        let stripped = TargetConfigFileAdapter.stripMarkedBlocks(
            text,
            blockNames: TargetConfigFileAdapter.managedBlockNames
        )
        try stripped.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Marked block helpers

    /// 托管块的完整名字。标记行长这样：`# >>> copool-managed >>>`，
    /// 所以名字必须含 `copool-` 前缀——只写 `managed` 匹配不上任何东西。
    static let managedBlockNames = ["copool-managed", "copool-managed-provider"]

    private static func markers(for name: String) -> (start: String, end: String) {
        ("# >>> \(name) >>>", "# <<< \(name) <<<")
    }

    /// Removes copool-managed blocks (same contract as CodexModelsCacheService).
    static func stripMarkedBlocks(_ text: String, blockNames: [String]) -> String {
        var result = text
        for name in blockNames {
            let (start, end) = markers(for: name)
            while let startRange = result.range(of: start),
                  let endRange = result.range(of: end, range: startRange.upperBound..<result.endIndex) {
                result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            }
        }
        return result
    }

    /// 抽出各托管块的正文（含标记行），供 `verify` 做区间级比较。
    /// 缺失的块不进字典——"块不见了"与"块内容不同"都会让比较失败，这正是想要的。
    static func markedBlocks(in text: String, blockNames: [String] = managedBlockNames) -> [String: String] {
        var blocks: [String: String] = [:]
        for name in blockNames {
            let (start, end) = markers(for: name)
            guard let startRange = text.range(of: start),
                  let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
                continue
            }
            blocks[name] = String(text[startRange.lowerBound..<endRange.upperBound])
        }
        return blocks
    }

    static func userOwnedLines(in text: String) -> [String] {
        stripMarkedBlocks(text, blockNames: managedBlockNames)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
