import Foundation

/// Tail of the in-process proxy log for the Logs sub-tab.
///
/// The app's proxy writes diagnostics to stdout/stderr; in dev deployments
/// that lands in `/tmp/icopool.log`. We scan a few known locations and return
/// the last N lines. Best-effort: an empty result just shows the empty note.
enum ProxyProcessLogTail {
    static func recentLines(limit: Int = 60) -> [String] {
        let candidates = [
            URL(fileURLWithPath: "/tmp/icopool.log"),
            URL(fileURLWithPath: "/tmp/copool.log"),
        ]
        for url in candidates {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = data.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { continue }
            return Array(lines.suffix(limit))
        }
        return []
    }
}
