import Foundation

/// Owns the RouterHost helper launched by Copool. The helper is always this
/// process's child and is stopped through its authenticated control plane.
final class RouterHostProcess: @unchecked Sendable {
    private let client: RouterHostControlClient
    private let fileManager: FileManager
    private let lock = NSLock()
    private var process: Process?

    init(client: RouterHostControlClient = RouterHostControlClient(), fileManager: FileManager = .default) {
        self.client = client
        self.fileManager = fileManager
    }

    func start(upstreamBaseURL: String, authorization: String) throws -> RouterHostControlClient.Status {
        if let status = try? client.status(), status.running {
            return status
        }

        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning {
            return try waitForStatus()
        }

        let executable = try resolveExecutable()
        let child = Process()
        child.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["COPOOL_INPROCESS_UPSTREAM"] = upstreamBaseURL
        environment["COPOOL_INPROCESS_AUTH"] = authorization
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        return try waitForStatus()
    }

    func stop() {
        if (try? client.shutdown()) != nil {
            waitForExit()
            return
        }
        lock.lock()
        let child = process
        process = nil
        lock.unlock()
        if let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
    }

    private func waitForStatus() throws -> RouterHostControlClient.Status {
        var lastError: Error?
        for _ in 0..<50 {
            do {
                let status = try client.status()
                if status.running, status.port != nil {
                    return status
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lastError ?? AppError.network("RouterHost did not become ready")
    }

    private func waitForExit() {
        for _ in 0..<50 {
            lock.lock()
            let child = process
            if let child, !child.isRunning {
                process = nil
                lock.unlock()
                return
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func resolveExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["COPOOL_ROUTER_HOST_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CopoolRouterHost")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }

        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("CopoolRouterHost")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }

        throw AppError.fileNotFound("CopoolRouterHost helper is not installed")
    }
}
