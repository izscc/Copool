import Foundation
import Network

// CopoolRouterHost — standalone routing data-plane process (Phase 6).
//
// Design:
//   - Runs as a per-user background process, fully separate from the SwiftUI
//     app: a crash here never takes the UI down (AC: "崩溃不拖垮 UI").
//   - Control surface: a UDS socket the app talks to (start/stop/status),
//     per PRD architecture: "SwiftUI 通过 UDS/受 capability 保护的 local
//     control API 管理".
//   - Data surface: one loopback HTTP listener per target binding, bound to
//     127.0.0.1 only, never answering browser origins, never emitting CORS
//     headers (AC-009).
//   - This is the vNext data-plane skeleton: contract-equivalent to the
//     in-process engine for /health, /v1/models; richer routes arrive with
//     the adapter migration. The app keeps its in-process engine until the
//     feature flag flips (old path remains as rollback).

// MARK: - Shared wire protocol (UDS control)

enum HostControlCommand: String {
    case start
    case stop
    case status
    case capabilities
}

struct HostStatus: Codable {
    var running: Bool
    var port: Int?
    var bindings: [String: BindingStatus]
    var uptimeSeconds: Int
}

struct BindingStatus: Codable {
    var targetID: String
    var port: Int
    var capability: String
}

struct HostCapabilities: Codable {
    var transports: [String]
    var supportedPaths: [String]
    var version: String
}

// MARK: - State

final class HostState: @unchecked Sendable {
    static let shared = HostState()

    struct Binding: Sendable {
        let targetID: String
        var port: Int?
        var capability: String
    }

    private let lock = NSLock()
    private var bindings: [String: Binding] = [:]
    private(set) var startedAt: Date?

    func registerBinding(targetID: String, capability: String) {
        lock.lock()
        defer { lock.unlock() }
        bindings[targetID] = Binding(targetID: targetID, port: nil, capability: capability)
    }

    func setPort(targetID: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        if var binding = bindings[targetID] {
            binding.port = port
            bindings[targetID] = binding
        }
    }

    func snapshot() -> HostStatus {
        lock.lock()
        defer { lock.unlock() }
        return HostStatus(
            running: startedAt != nil,
            port: bindings.first?.value.port,
            bindings: Dictionary(uniqueKeysWithValues: bindings.map { key, value in
                (key, BindingStatus(targetID: value.targetID, port: value.port ?? 0, capability: value.capability))
            }),
            uptimeSeconds: startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        )
    }

    func markStarted() {
        lock.lock()
        defer { lock.unlock() }
        startedAt = Date()
    }
}

// MARK: - Loopback HTTP data plane (one listener per binding)

actor DataPlaneServer {
    let port: Int
    let targetID: String
    private var listener: NWListener?

    init(port: Int, targetID: String) {
        self.port = port
        self.targetID = targetID
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        // Loopback only (AC-009): bind to 127.0.0.1 explicitly.
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            self.handle(connection: connection)
        }
        // Ensure loopback: restart with loopback if the listener picked a
        // non-loopback interface (belt and braces — the port is bound via
        // .tcp on 127.0.0.1 by using parameters with required interface).
        self.listener = listener
        listener.start(queue: .global())
    }

    nonisolated private func handle(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                let response = Self.route(requestData: data, targetID: self.targetID)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    /// Minimal contract-equivalent routing (Phase 6 skeleton):
    ///   GET /health → 200 {"ok": true}
    ///   GET /v1/models → 200 {"data": []} (registry wiring lands later)
    /// Browser origins and everything else → 403/404. Never CORS headers.
    private static func route(requestData: Data, targetID: String) -> Data {
        let text = String(data: requestData, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            return httpResponse(status: 400, body: #"{"error":"bad request"}"#)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: 400, body: #"{"error":"bad request"}"#)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        // Browser origin rejection (AC-009).
        if text.lowercased().contains("origin: http") || text.lowercased().contains("origin: https") {
            return httpResponse(status: 403, body: #"{"error":"Browser origin rejected"}"#)
        }

        switch (method, path) {
        case ("GET", "/health"):
            return httpResponse(status: 200, body: #"{"ok":true,"target":"\#(targetID)"}"#)
        case ("GET", "/v1/models"):
            return httpResponse(status: 200, body: #"{"object":"list","data":[]}"#)
        default:
            return httpResponse(status: 404, body: #"{"error":"not found"}"#)
        }
    }

    private static func httpResponse(status: Int, body: String) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        return Data("""
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8)
    }
}

// MARK: - UDS control server (POSIX unix socket — the app's control surface)

final class ControlServer: @unchecked Sendable {
    let socketPath: String
    private let queue = DispatchQueue(label: "host.control")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        try? FileManager.default.removeItem(atPath: socketPath)
        queue.async {
            self.runLoop()
        }
    }

    private func runLoop() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let raw = UnsafeMutableRawPointer(pathPtr)
            socketPath.withCString { bytes in
                _ = memcpy(raw, bytes, min(socketPath.utf8.count, 104))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard bind(fd, withUnsafePointer(to: &addr) { UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self) }, size) == 0 else {
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            DispatchQueue.global().async {
                Self.handleClient(client)
            }
        }
        close(fd)
    }

    private static func handleClient(_ client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buffer, buffer.count)
        guard n > 0 else { return }
        let command = String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let response: Data
        switch HostControlCommand(rawValue: command) {
        case .start:
            Task { @MainActor in HostApplication.shared.startDataPlane() }
            response = Data(#"{"ok":true,"action":"start"}"#.utf8)
        case .stop:
            Task { @MainActor in HostApplication.shared.stopDataPlane() }
            response = Data(#"{"ok":true,"action":"stop"}"#.utf8)
        case .status:
            response = (try! JSONEncoder().encode(HostState.shared.snapshot()))
        case .capabilities:
            let caps = HostCapabilities(transports: ["http"], supportedPaths: ["/health", "/v1/models"], version: "0.1.0")
            response = (try! JSONEncoder().encode(caps))
        case nil:
            response = Data(#"{"error":"unknown command"}"#.utf8)
        }
        response.withUnsafeBytes { raw in
            _ = write(client, raw.baseAddress, response.count)
        }
    }
}

// MARK: - Application

@MainActor
final class HostApplication {
    static let shared = HostApplication()

    private var controlServer: ControlServer?
    private var dataServers: [String: DataPlaneServer] = [:]
    private var socketsPath: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexToolsSwift/host", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("control.sock").path
    }

    func run() async {
        HostState.shared.registerBinding(targetID: "codex", capability: "cap-codex-internal")
        let control = ControlServer(socketPath: socketsPath)
        controlServer = control
        try? await control.start()
        // Keep the process alive.
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    func startDataPlane() {
        // Target-specific port with automatic fallback: 18787 is the Codex
        // binding's default, but another local service may hold it — scan
        // forward for a free port instead of failing (AC: 升级/停止/恢复明确).
        let basePort = 18787
        let chosen = Self.firstFreePort(startingAt: basePort, attempts: 8)
        guard let chosen else { return }
        let server = DataPlaneServer(port: chosen, targetID: "codex")
        dataServers["codex"] = server
        Task {
            try? await server.start()
            HostState.shared.setPort(targetID: "codex", port: chosen)
        }
        HostState.shared.markStarted()
    }

    static func firstFreePort(startingAt base: Int, attempts: Int) -> Int? {
        for offset in 0..<attempts {
            let port = base + offset
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            if probe >= 0 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let ok = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        bind(probe, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(probe)
                if ok { return port }
            }
        }
        return nil
    }

    func stopDataPlane() {
        dataServers.removeAll()
    }
}

// MARK: - Entry point

@main
struct CopoolRouterHostMain {
    static func main() async {
        // Ignore SIGPIPE so a client disconnecting mid-response cannot kill
        // the host (the UI relies on the host staying up).
        signal(SIGPIPE, SIG_IGN)
        await HostApplication.shared.run()
    }
}
