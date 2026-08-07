import Foundation

/// `consent-log.jsonl` 的只追加实现（FR-IDT-06 / SEC-08）。
///
/// 为什么是 jsonl 而不是一个 JSON 数组：追加一行不需要先读全量再整份重写，
/// 中途崩溃最多丢最后一行，已落地的同意记录不会被一次失败的写入破坏。
///
/// 写失败**抛错**，调用方必须因此中止读取第三方登录态的动作——
/// 记不下同意就等于没有同意。
final class ConsentAuditFileLog: ConsentAuditLog, @unchecked Sendable {
    private let path: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func append(_ record: ConsentRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)

        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: path, options: .atomic)
            Self.setPrivatePermissions(at: path)
        }
    }

    /// 解析失败的行**跳过而不是抛错**：一条坏行不该让整份审计历史读不出来。
    /// 这与种子加载的取舍相反——种子坏了是构建问题，必须炸；审计日志坏一行
    /// 是磁盘意外，剩下的记录仍有价值。
    func records() -> [ConsentRecord] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ConsentRecord.self, from: lineData)
            }
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
