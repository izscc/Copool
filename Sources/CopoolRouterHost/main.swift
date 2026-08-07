import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// CopoolRouterHost is a per-user control/data-plane process. Secrets are not
// loaded from provider files; the host owns only opaque capabilities and can
// optionally forward traffic to an already-running in-process router.

enum HostControlCommand: String {
    case start
    case stop
    case status
    case capabilities
    case shutdown
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

struct RegistryCatalogEntry: Decodable {
    var providerInstanceID: String
    var backendModelID: String
    var displayName: String?
    var aliases: [String]?
    var visibility: String?
}

struct RegistryDocument: Decodable {
    var catalog: [RegistryCatalogEntry]
}

final class HostState: @unchecked Sendable {
    static let shared = HostState()

    struct Binding: Sendable {
        let targetID: String
        var port: Int?
        var capability: String
    }

    private let lock = NSLock()
    private var bindings: [String: Binding] = [:]
    private var startedAt: Date?

    func registerBinding(targetID: String, capability: String) {
        lock.lock()
        defer { lock.unlock() }
        bindings[targetID] = Binding(targetID: targetID, port: nil, capability: capability)
    }

    func setPort(targetID: String, port: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard var binding = bindings[targetID] else { return }
        binding.port = port
        bindings[targetID] = binding
    }

    func markStarted() {
        lock.lock()
        startedAt = Date()
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        startedAt = nil
        for targetID in bindings.keys {
            bindings[targetID]?.port = nil
        }
        lock.unlock()
    }

    func snapshot() -> HostStatus {
        lock.lock()
        defer { lock.unlock() }
        return HostStatus(
            running: startedAt != nil,
            port: bindings.values.compactMap(\.port).first,
            bindings: Dictionary(uniqueKeysWithValues: bindings.map { key, value in
                (key, BindingStatus(targetID: value.targetID, port: value.port ?? 0, capability: value.capability))
            }),
            uptimeSeconds: startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        )
    }
}

enum HostResponseBody {
    case data(Data)
    case stream(AsyncThrowingStream<Data, Error>)
}

struct HostResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: HostResponseBody
}

actor DataPlaneServer {
    let port: Int
    let targetID: String
    private let callerCapability: String
    private let registryPath: URL
    private let upstreamBaseURL: URL?
    private let upstreamAuthorization: String?
    private var listener: NWListener?

    init(
        port: Int,
        targetID: String,
        callerCapability: String,
        registryPath: URL,
        upstreamBaseURL: URL? = nil,
        upstreamAuthorization: String? = nil
    ) {
        self.port = port
        self.targetID = targetID
        self.callerCapability = callerCapability
        self.registryPath = registryPath
        self.upstreamBaseURL = upstreamBaseURL
        self.upstreamAuthorization = upstreamAuthorization
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "CopoolRouterHost", code: 1)
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { [weak self] in
                await self?.handle(connection: connection)
            }
        }
        self.listener = listener
        listener.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
                guard let self, let data, !data.isEmpty, error == nil else {
                    connection.cancel()
                    continuation.resume()
                    return
                }
                Task {
                    let response = await self.route(requestData: data)
                    await self.send(response: response, on: connection)
                    connection.cancel()
                    continuation.resume()
                }
            }
        }
    }

    private func send(response: HostResponse, on connection: NWConnection) async {
        do {
            switch response.body {
            case .data(let body):
                try await send(Self.httpResponse(status: response.statusCode, headers: response.headers, body: body), on: connection)
            case .stream(let stream):
                let header = Self.httpHeader(status: response.statusCode, headers: response.headers.merging(["Transfer-Encoding": "chunked"]) { current, _ in current })
                try await send(header, on: connection)
                for try await chunk in stream where !chunk.isEmpty {
                    try await send(Self.chunk(chunk), on: connection)
                }
                try await send(Data("0\r\n\r\n".utf8), on: connection)
            }
        } catch { }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func route(requestData: Data) async -> HostResponse {
        guard let request = HTTPRequest.parse(requestData) else {
            return Self.response(status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
        }
        if request.headers.keys.contains(where: { $0.lowercased() == "origin" }) {
            return Self.response(status: 403, body: Data(#"{"error":"Browser origin rejected"}"#.utf8))
        }
        if request.path != "/health" {
            guard request.headers["x-copool-caller-capability"] == callerCapability else {
                return Self.response(status: 401, body: Data(#"{"error":"caller capability required"}"#.utf8))
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return Self.response(status: 200, body: Data(#"{"ok":true,"target":"\#(targetID)"}"#.utf8))
        case ("GET", "/v1/models"):
            return Self.response(status: 200, body: modelsBody())
        case ("POST", "/v1/responses"), ("POST", "/v1/chat/completions"):
            guard let upstreamBaseURL else {
                return Self.response(status: 503, body: Data(#"{"error":"router data plane is not connected"}"#.utf8))
            }
            return await forward(request: request, upstreamBaseURL: upstreamBaseURL)
        default:
            return Self.response(status: 404, body: Data(#"{"error":"not found"}"#.utf8))
        }
    }

    private func modelsBody() -> Data {
        guard let data = try? Data(contentsOf: registryPath),
              let document = try? JSONDecoder().decode(RegistryDocument.self, from: data) else {
            return Data(#"{"object":"list","data":[]}"#.utf8)
        }
        let models = document.catalog
            .filter { ($0.visibility ?? "visible") != "hidden" }
            .map { entry in
                [
                    "id": entry.backendModelID,
                    "object": "model",
                    "owned_by": entry.providerInstanceID,
                    "display_name": entry.displayName ?? entry.backendModelID,
                    "aliases": entry.aliases ?? []
                ] as [String: Any]
            }
        return (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": models]))
            ?? Data(#"{"object":"list","data":[]}"#.utf8)
    }

    private func forward(request: HTTPRequest, upstreamBaseURL: URL) async -> HostResponse {
        let requestPath = request.path.hasPrefix("/v1/")
            ? String(request.path.dropFirst(3))
            : request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = upstreamBaseURL.appendingPathComponent(requestPath)
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.httpBody = request.body
        for (name, value) in request.headers where !["host", "origin", "x-copool-caller-capability"].contains(name.lowercased()) {
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        if let upstreamAuthorization {
            upstream.setValue(upstreamAuthorization, forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstream)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                Task {
                    do {
                        var line = Data()
                        for try await byte in bytes {
                            line.append(byte)
                            if byte == 0x0A {
                                continuation.yield(line)
                                line.removeAll(keepingCapacity: true)
                            }
                        }
                        if !line.isEmpty { continuation.yield(line) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            return HostResponse(statusCode: status, headers: headers, body: .stream(stream))
        } catch {
            return Self.response(status: 502, body: Data(#"{"error":"upstream unavailable"}"#.utf8))
        }
    }

    private static func response(status: Int, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) -> HostResponse {
        HostResponse(statusCode: status, headers: headers, body: .data(body))
    }

    private static func httpHeader(status: Int, headers: [String: String]) -> Data {
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        return Data("HTTP/1.1 \(status) \(reason)\r\n\(fields)\r\nConnection: close\r\n\r\n".utf8)
    }

    private static func httpResponse(status: Int, headers: [String: String], body: Data) -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        return httpHeader(status: status, headers: all) + body
    }

    private static func chunk(_ body: Data) -> Data {
        Data(String(body.count, radix: 16).utf8) + Data("\r\n".utf8) + body + Data("\r\n".utf8)
    }
}

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let separator = "\r\n\r\n"
        let pieces = text.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = pieces.first else { return nil }
        let lines = head.split(separator: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
        let body = pieces.count == 2 ? Data(pieces[1].utf8) : Data()
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }
}

final class ControlServer: @unchecked Sendable {
    let socketPath: String
    private let capability: String
    private let onCommand: @Sendable (HostControlCommand) -> Data
    private let onShutdown: @Sendable () -> Void
    private let queue = DispatchQueue(label: "host.control")
    private var serverFD: Int32 = -1

    init(socketPath: String, capability: String, onCommand: @escaping @Sendable (HostControlCommand) -> Data, onShutdown: @escaping @Sendable () -> Void) {
        self.socketPath = socketPath
        self.capability = capability
        self.onCommand = onCommand
        self.onShutdown = onShutdown
    }

    func start() {
        try? FileManager.default.removeItem(atPath: socketPath)
        queue.async { self.runLoop() }
    }

    private func runLoop() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let raw = UnsafeMutableRawPointer(pathPtr)
            socketPath.withCString { bytes in _ = memcpy(raw, bytes, min(socketPath.utf8.count, 104)) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard bind(fd, withUnsafePointer(to: &addr) { UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self) }, size) == 0,
              listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            DispatchQueue.global().async { [self] in handleClient(client) }
        }
        close(fd)
        serverFD = -1
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func stop() {
        let fd = serverFD
        if fd >= 0 { close(fd) }
        serverFD = -1
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let request = String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = request.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0] == capability,
              let command = HostControlCommand(rawValue: parts[1]) else {
            writeResponse(Data(#"{"error":"unauthorized"}"#.utf8), to: client)
            return
        }
        writeResponse(onCommand(command), to: client)
        if command == .shutdown {
            onShutdown()
        }
    }

    private func writeResponse(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, data.count) }
    }
}

@MainActor
final class HostApplication {
    static let shared = HostApplication()

    private var controlServer: ControlServer?
    private var dataServers: [String: DataPlaneServer] = [:]
    private let targetID = "codex"
    private var internalCapability = UUID().uuidString
    private var callerCapability = UUID().uuidString
    private var hostRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexToolsSwift/host", isDirectory: true)
    }
    private var socketPath: String { hostRoot.appendingPathComponent("control.sock").path }
    var socketPathForShutdown: String { socketPath }
    private var registryPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexToolsSwift/provider-registry-v2.json")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        writeCapability(internalCapability, to: hostRoot.appendingPathComponent("internal-capability"))
        writeCapability(callerCapability, to: hostRoot.appendingPathComponent("targets/codex/caller-capability"))
        HostState.shared.registerBinding(targetID: targetID, capability: callerCapability)
        let control = ControlServer(socketPath: socketPath, capability: internalCapability, onCommand: { command in
            switch command {
            case .start:
                Task { @MainActor in await HostApplication.shared.startDataPlane() }
                return Data(#"{"ok":true,"action":"start"}"#.utf8)
            case .stop:
                Task { @MainActor in await HostApplication.shared.stopDataPlane() }
                return Data(#"{"ok":true,"action":"stop"}"#.utf8)
            case .status:
                return (try? JSONEncoder().encode(HostState.shared.snapshot())) ?? Data(#"{"running":false}"#.utf8)
            case .capabilities:
                let caps = HostCapabilities(
                    transports: ["http-loopback", "uds-control"],
                    supportedPaths: ["/health", "/v1/models", "/v1/responses", "/v1/chat/completions"],
                    version: "0.2.0"
                )
                return (try? JSONEncoder().encode(caps)) ?? Data(#"{}"#.utf8)
            case .shutdown:
                return Data(#"{"ok":true,"action":"shutdown"}"#.utf8)
            }
        }, onShutdown: {
            Task { @MainActor in await HostApplication.shared.shutdown() }
        })
        controlServer = control
        control.start()
        await startDataPlane()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    func startDataPlane() async {
        guard dataServers[targetID] == nil else { return }
        guard let port = Self.firstFreePort(startingAt: 18787, attempts: 8) else { return }
        let upstream = ProcessInfo.processInfo.environment["COPOOL_INPROCESS_UPSTREAM"].flatMap(URL.init(string:))
        let authorization = ProcessInfo.processInfo.environment["COPOOL_INPROCESS_AUTH"]
        let server = DataPlaneServer(
            port: port,
            targetID: targetID,
            callerCapability: callerCapability,
            registryPath: registryPath,
            upstreamBaseURL: upstream,
            upstreamAuthorization: authorization.map { $0.hasPrefix("Bearer ") ? $0 : "Bearer \($0)" }
        )
        dataServers[targetID] = server
        do {
            try await server.start()
            HostState.shared.setPort(targetID: targetID, port: port)
            HostState.shared.markStarted()
        } catch {
            dataServers.removeValue(forKey: targetID)
        }
    }

    func stopDataPlane() async {
        for server in dataServers.values { await server.stop() }
        dataServers.removeAll()
        HostState.shared.markStopped()
    }

    func shutdown() async {
        await stopDataPlane()
        controlServer?.stop()
        controlServer = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        exit(0)
    }

    private func writeCapability(_ capability: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? capability.write(to: url, atomically: true, encoding: .utf8)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }

    static func firstFreePort(startingAt base: Int, attempts: Int) -> Int? {
        for offset in 0..<attempts {
            let port = base + offset
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            guard probe >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let available = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            close(probe)
            if available { return port }
        }
        return nil
    }
}

@main
struct CopoolRouterHostMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        await HostApplication.shared.run()
    }
}
