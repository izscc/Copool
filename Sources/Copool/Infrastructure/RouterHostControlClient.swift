import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal authenticated client for CopoolRouterHost's per-user UDS control
/// surface. The capability is read from a 0600 file and never logged.
struct RouterHostControlClient: Sendable {
    struct Status: Codable, Equatable, Sendable {
        var running: Bool
        var port: Int?
        var bindings: [String: Binding]
        var uptimeSeconds: Int
    }

    struct Binding: Codable, Equatable, Sendable {
        var targetID: String
        var port: Int
        var capability: String
    }

    struct Capabilities: Codable, Equatable, Sendable {
        var transports: [String]
        var supportedPaths: [String]
        var version: String
    }

    let root: URL
    let socketPath: URL
    let capabilityPath: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexToolsSwift/host", isDirectory: true)) {
        self.root = root
        self.socketPath = root.appendingPathComponent("control.sock")
        self.capabilityPath = root.appendingPathComponent("internal-capability")
    }

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COPOOL_ROUTER_HOST"] != "0"
    }

    func start() throws -> Status {
        try decodeStatus(send(.start))
    }

    func stop() throws -> Status {
        try decodeStatus(send(.stop))
    }

    func status() throws -> Status {
        try decodeStatus(send(.status))
    }

    func capabilities() throws -> Capabilities {
        try JSONDecoder().decode(Capabilities.self, from: send(.capabilities))
    }

    func shutdown() throws {
        _ = try send(.shutdown)
    }

    @discardableResult
    func ensureRunning() throws -> Status {
        let current = try? status()
        if let current, current.running { return current }
        return try start()
    }

    private enum Command: String {
        case start
        case stop
        case status
        case capabilities
        case shutdown
    }

    private func send(_ command: Command) throws -> Data {
        guard let capability = try? String(contentsOf: capabilityPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !capability.isEmpty else {
            throw AppError.fileNotFound("RouterHost capability is unavailable")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError.io("RouterHost control socket could not be created") }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            let raw = UnsafeMutableRawPointer(pathPointer)
            socketPath.path.withCString { bytes in
                _ = memcpy(raw, bytes, min(socketPath.path.utf8.count, 104))
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, addressLength) == 0
            }
        }
        guard connected else { throw AppError.network("RouterHost control socket is unavailable") }

        let request = Data("\(capability)\n\(command.rawValue)".utf8)
        let written = request.withUnsafeBytes { raw in
            write(descriptor, raw.baseAddress, request.count)
        }
        guard written == request.count else { throw AppError.network("RouterHost control request failed") }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer[0..<count])
            if count < buffer.count { break }
        }
        guard !result.isEmpty,
              !String(decoding: result, as: UTF8.self).contains("\"error\"") else {
            throw AppError.unauthorized("RouterHost control request was rejected")
        }
        return result
    }

    private func decodeStatus(_ data: Data) throws -> Status {
        try JSONDecoder().decode(Status.self, from: data)
    }
}
