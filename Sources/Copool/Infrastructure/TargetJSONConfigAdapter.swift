import Foundation

final class TargetJSONConfigAdapter: TargetConfigManaging, @unchecked Sendable {
    let targetID: String
    private let configPath: URL
    private let stateDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(targetID: String, configPath: URL, stateRoot: URL, fileManager: FileManager = .default) {
        self.targetID = targetID
        self.configPath = configPath
        self.stateDirectory = stateRoot.appendingPathComponent(targetID, isDirectory: true)
        self.fileManager = fileManager
    }

    func detect() -> TargetConfigSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        let modifiedAt = try? fileManager.attributesOfItem(atPath: configPath.path)[.modificationDate] as? Date
        return TargetConfigSnapshot(targetID: targetID, content: text, modifiedAt: modifiedAt)
    }

    func plan(to desired: String) -> TargetConfigDiff {
        lock.lock()
        defer { lock.unlock() }
        let before = detect()
        let preserved = before.flatMap { try? JSONSerialization.jsonObject(with: Data($0.content.utf8)) as? [String: Any] }
            .map { Array($0.keys).sorted() } ?? []
        return TargetConfigDiff(
            targetID: targetID,
            before: before,
            after: TargetConfigSnapshot(targetID: targetID, content: desired, modifiedAt: nil),
            preservedUserLines: preserved
        )
    }

    func desiredConfig(port: Int) -> String {
        var object: [String: Any] = [:]
        if let current = detect()?.content,
           let decoded = try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any] {
            object = decoded
        }
        object["copool"] = [
            "managed": true,
            "target": targetID,
            "base_url": "http://127.0.0.1:\(port)/v1",
            "provider": "opencodex"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    func apply(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let backupPath = stateDirectory.appendingPathComponent("config-backup.json")
        if let before = diff.before?.content {
            try before.write(to: backupPath, atomically: true, encoding: .utf8)
        } else {
            try? fileManager.removeItem(at: backupPath)
        }
        try atomicWrite(diff.after.content, to: configPath)
    }

    func verify(_ diff: TargetConfigDiff) -> Bool {
        (try? String(contentsOf: configPath, encoding: .utf8)) == diff.after.content
    }

    func rollback(_ diff: TargetConfigDiff) throws {
        lock.lock()
        defer { lock.unlock() }
        let backupPath = stateDirectory.appendingPathComponent("config-backup.json")
        if let before = diff.before?.content {
            guard fileManager.fileExists(atPath: backupPath.path) else {
                throw AppError.io("No backup to roll back to for target \(targetID)")
            }
            try atomicWrite(before, to: configPath)
        } else {
            try? fileManager.removeItem(at: configPath)
        }
        try? fileManager.removeItem(at: backupPath)
    }

    func uninstall() throws {
        guard let current = detect()?.content,
              var object = try JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any] else { return }
        object.removeValue(forKey: "copool")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(String(decoding: data, as: UTF8.self) + "\n", to: configPath)
    }

    private func atomicWrite(_ text: String, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
