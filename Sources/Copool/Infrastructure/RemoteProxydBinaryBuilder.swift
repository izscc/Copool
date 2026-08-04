import Foundation
import Compression

struct RemoteProxydBinaryBuilder {
    let repoRoot: URL?
    let bundledResourceRoot: URL?
    let prebuiltCacheRoot: URL?
    let fileManager: FileManager
    let commandRunner: RemoteShellCommandRunner

    init(
        repoRoot: URL?,
        bundledResourceRoot: URL? = Bundle.main.resourceURL,
        prebuiltCacheRoot: URL? = nil,
        fileManager: FileManager,
        commandRunner: RemoteShellCommandRunner
    ) {
        self.repoRoot = repoRoot
        self.bundledResourceRoot = bundledResourceRoot
        self.prebuiltCacheRoot = prebuiltCacheRoot
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func buildBinary(for server: RemoteServerConfig, forceRebuild: Bool = false) throws -> URL {
        let platform = try detectRemoteLinuxPlatform(for: server)
        if let prebuilt = try prebuiltBinary(for: platform), !forceRebuild {
            return prebuilt
        }
        guard let manifestPath = try proxydManifestPath() else {
            throw AppError.io(L10n.tr("error.remote.unavailable_missing_proxyd_source"))
        }
        guard CommandRunner.resolveExecutable("cargo") != nil else {
            throw AppError.io(
                "\(L10n.tr("error.remote.build_proxyd_failed")): \(L10n.tr("error.remote.cargo_not_found"))"
            )
        }

        try ensureLinuxBuildDependenciesIfNeeded()
        let targetDir = try proxydBuildTargetDirectory()
        let manifestDirectory = manifestPath.deletingLastPathComponent()
        var buildErrors: [String] = []

        for target in [platform.primaryTarget, platform.fallbackTarget] {
            try ensureRustTargetAddedIfPossible(target)
            let binaryPath = targetDir
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent("release", isDirectory: true)
                .appendingPathComponent(RepositoryLocator.proxydBinaryName, isDirectory: false)

            if try prepareBinaryPathForBuild(binaryPath, forceRebuild: forceRebuild) {
                return binaryPath
            }

            for build in buildAttemptCommands(manifestPath: manifestPath, target: target, targetDir: targetDir) {
                let result = try CommandRunner.run(
                    "/usr/bin/env",
                    arguments: build.command,
                    currentDirectory: manifestDirectory
                )
                if result.status == 0, fileManager.isExecutableFile(atPath: binaryPath.path) {
                    return binaryPath
                }
                let details = result.stderr.isEmpty ? result.stdout : result.stderr
                let compact = details.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = compact.isEmpty
                    ? L10n.tr("error.remote.exit_status_format", String(result.status))
                    : compact
                buildErrors.append("\(build.label): \(message)")
            }
        }

        let suffix = buildErrors.isEmpty ? "" : " \(buildErrors.joined(separator: " | "))"
        throw AppError.io("\(L10n.tr("error.remote.build_proxyd_failed")):\(suffix)")
    }

    func prepareBinaryPathForBuild(_ binaryPath: URL, forceRebuild: Bool) throws -> Bool {
        if fileManager.isExecutableFile(atPath: binaryPath.path) {
            if forceRebuild {
                try fileManager.removeItem(at: binaryPath)
                return false
            }
            return true
        }
        return false
    }

    func prebuiltBinary(for platform: RemoteLinuxPlatform) throws -> URL? {
        for target in [platform.primaryTarget, platform.fallbackTarget] {
            if let binary = try prebuiltBinary(forTarget: target) {
                return binary
            }
        }
        return nil
    }

    func prebuiltBinary(forTarget target: String) throws -> URL? {
        if let repoRoot {
            let repoBinary = RepositoryLocator.proxydPrebuiltBinaryURL(in: repoRoot, target: target)
            if fileManager.fileExists(atPath: repoBinary.path) {
                return repoBinary
            }
        }

        if let bundledResourceRoot {
            let bundledCompressedBinary = RepositoryLocator.proxydBundledCompressedBinaryURL(
                in: bundledResourceRoot,
                target: target
            )
            if fileManager.fileExists(atPath: bundledCompressedBinary.path) {
                return try extractBundledCompressedBinary(
                    at: bundledCompressedBinary,
                    target: target
                )
            }
        }

        return nil
    }

    func bundledManifestPath() throws -> URL? {
        guard let bundledResourceRoot else {
            return nil
        }

        let structured = bundledResourceRoot
            .appendingPathComponent(RepositoryLocator.proxydBundledManifestRelativePath, isDirectory: false)
        if fileManager.fileExists(atPath: structured.path) {
            return structured
        }

        return try restoreFlattenedBundledSourceTreeIfNeeded(from: bundledResourceRoot)
    }

    private func proxydManifestPath() throws -> URL? {
        if let repoRoot {
            if let manifest = RepositoryLocator.proxydManifestURL(in: repoRoot),
               fileManager.fileExists(atPath: manifest.path) {
                return manifest
            }
        }

        return try bundledManifestPath()
    }

    private func proxydBuildTargetDirectory() throws -> URL {
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = caches
            .appendingPathComponent("Copool", isDirectory: true)
            .appendingPathComponent("proxyd-target", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func proxydPrebuiltCacheDirectory() throws -> URL {
        if let prebuiltCacheRoot {
            try fileManager.createDirectory(at: prebuiltCacheRoot, withIntermediateDirectories: true)
            return prebuiltCacheRoot
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = applicationSupport
            .appendingPathComponent("CodexToolsSwift", isDirectory: true)
            .appendingPathComponent("proxyd-runtime", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func extractBundledCompressedBinary(at source: URL, target: String) throws -> URL {
        let cacheRoot = try proxydPrebuiltCacheDirectory()
        let extractedBinary = RepositoryLocator.proxydExtractedPrebuiltBinaryURL(in: cacheRoot, target: target)
        let stampPath = extractedBinary
            .deletingLastPathComponent()
            .appendingPathComponent(".archive-stamp", isDirectory: false)
        try fileManager.createDirectory(at: extractedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceStamp = try archiveStamp(for: source)
        if fileManager.isExecutableFile(atPath: extractedBinary.path),
           let existingStamp = try? String(contentsOf: stampPath, encoding: .utf8),
           existingStamp == sourceStamp {
            return extractedBinary
        }

        let compressed = try Data(contentsOf: source)
        let extracted = try decompressZlibData(compressed)
        try extracted.write(to: extractedBinary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        try sourceStamp.write(to: stampPath, atomically: true, encoding: .utf8)
        return extractedBinary
    }

    private func archiveStamp(for archive: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: archive.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(modified)"
    }

    private func decompressZlibData(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        let destinationCapacity = max(64, data.count * 8)
        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourceBaseAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw AppError.io(L10n.tr("error.remote.archive_empty"))
            }

            var decoded = Data()
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            stream.pointee = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                dst_size: 0,
                src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                src_size: 0,
                state: nil
            )

            let status = compression_stream_init(&stream.pointee, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw AppError.io(L10n.tr("error.remote.archive_decompression_init_failed"))
            }
            defer { compression_stream_destroy(&stream.pointee) }

            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
            defer { destination.deallocate() }

            stream.pointee.src_ptr = sourceBaseAddress
            stream.pointee.src_size = data.count

            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = destinationCapacity
                let result = compression_stream_process(&stream.pointee, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = destinationCapacity - stream.pointee.dst_size
                if produced > 0 {
                    decoded.append(destination, count: produced)
                }

                switch result {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return decoded
                default:
                    throw AppError.io(L10n.tr("error.remote.archive_decompression_failed"))
                }
            }
        }
    }

    private func ensureRustTargetAddedIfPossible(_ target: String) throws {
        guard CommandRunner.resolveExecutable("rustup") != nil else {
            return
        }
        _ = try? CommandRunner.run("/usr/bin/env", arguments: ["rustup", "target", "add", target])
    }

    private func buildAttemptCommands(manifestPath: URL, target: String, targetDir: URL) -> [BuildAttempt] {
        let manifest = manifestPath.path
        let targetDirPath = targetDir.path
        var attempts: [BuildAttempt] = []

        if CommandRunner.resolveExecutable("cross") != nil {
            attempts.append(
                BuildAttempt(
                    label: "cross \(target)",
                    command: [
                        "cross", "build",
                        "--manifest-path", manifest,
                        "--release",
                        "--target", target,
                        "--target-dir", targetDirPath,
                    ]
                )
            )
        }

        if hasCargoZigbuild() {
            attempts.append(
                BuildAttempt(
                    label: "cargo zigbuild \(target)",
                    command: [
                        "cargo", "zigbuild",
                        "--manifest-path", manifest,
                        "--release",
                        "--target", target,
                        "--target-dir", targetDirPath,
                    ]
                )
            )
        }

        attempts.append(
            BuildAttempt(
                label: "cargo build \(target)",
                command: [
                    "cargo", "build",
                    "--manifest-path", manifest,
                    "--release",
                    "--target", target,
                    "--target-dir", targetDirPath,
                ]
            )
        )

        return attempts
    }

    private func hasCargoZigbuild() -> Bool {
        guard CommandRunner.resolveExecutable("zig") != nil else {
            return false
        }
        if CommandRunner.resolveExecutable("cargo-zigbuild") != nil {
            return true
        }
        guard CommandRunner.resolveExecutable("cargo") != nil else {
            return false
        }
        if let help = try? CommandRunner.run("/usr/bin/env", arguments: ["cargo", "zigbuild", "--help"]) {
            return help.status == 0
        }
        return false
    }

    private func ensureLinuxBuildDependenciesIfNeeded() throws {
        if CommandRunner.resolveExecutable("cross") != nil || hasCargoZigbuild() {
            return
        }

        #if os(macOS)
        guard CommandRunner.resolveExecutable("brew") != nil else {
            return
        }

        if CommandRunner.resolveExecutable("zig") == nil {
            _ = try CommandRunner.runChecked(
                "/usr/bin/env",
                arguments: ["brew", "install", "zig"],
                errorPrefix: "\(L10n.tr("error.remote.build_proxyd_failed")) (\(L10n.tr("error.remote.install_zig")))"
            )
        }

        if !hasCargoZigbuild() {
            _ = try CommandRunner.runChecked(
                "/usr/bin/env",
                arguments: ["cargo", "install", "cargo-zigbuild", "--locked"],
                errorPrefix: "\(L10n.tr("error.remote.build_proxyd_failed")) (\(L10n.tr("error.remote.install_cargo_zigbuild")))"
            )
        }
        #endif
    }

    private func detectRemoteLinuxPlatform(for server: RemoteServerConfig) throws -> RemoteLinuxPlatform {
        let output = try commandRunner.runSSH(
            server: server,
            command: "uname -s && uname -m"
        )
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let os = lines.first ?? ""
        let arch = lines.count > 1 ? lines[1] : ""

        guard os == "Linux" else {
            let value = os.isEmpty ? L10n.tr("common.unknown") : os
            throw AppError.io(L10n.tr("error.remote.linux_only_format", value))
        }

        switch arch {
        case "x86_64", "amd64":
            return RemoteLinuxPlatform(
                primaryTarget: "x86_64-unknown-linux-musl",
                fallbackTarget: "x86_64-unknown-linux-gnu"
            )
        case "aarch64", "arm64":
            return RemoteLinuxPlatform(
                primaryTarget: "aarch64-unknown-linux-musl",
                fallbackTarget: "aarch64-unknown-linux-gnu"
            )
        default:
            let value = arch.isEmpty ? L10n.tr("common.unknown") : arch
            throw AppError.io(L10n.tr("error.remote.architecture_unsupported_format", value))
        }
    }

    private func restoreFlattenedBundledSourceTreeIfNeeded(from resourcesRoot: URL) throws -> URL? {
        let manifest = resourcesRoot.appendingPathComponent("Cargo.toml", isDirectory: false)
        let main = resourcesRoot.appendingPathComponent("main.rs", isDirectory: false)
        guard fileManager.fileExists(atPath: manifest.path),
              fileManager.fileExists(atPath: main.path) else {
            return nil
        }

        let supportFiles = [
            "auth.rs",
            "models.rs",
            "proxy_daemon.rs",
            "proxy_service.rs",
            "state.rs",
            "store.rs",
            "usage.rs",
            "utils.rs",
        ]
        guard supportFiles.allSatisfy({
            fileManager.fileExists(
                atPath: resourcesRoot.appendingPathComponent($0, isDirectory: false).path
            )
        }) else {
            return nil
        }

        let restoredRoot = try proxydBuildTargetDirectory()
            .appendingPathComponent("bundled-proxyd-src", isDirectory: true)
        if fileManager.fileExists(atPath: restoredRoot.path) {
            try fileManager.removeItem(at: restoredRoot)
        }

        let restoredManifestDir = restoredRoot.appendingPathComponent("proxyd", isDirectory: true)
        let restoredMainDir = restoredManifestDir.appendingPathComponent("src", isDirectory: true)
        let restoredSupportDir = restoredRoot.appendingPathComponent("src", isDirectory: true)
        try fileManager.createDirectory(at: restoredMainDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: restoredSupportDir, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: manifest,
            to: restoredManifestDir.appendingPathComponent("Cargo.toml", isDirectory: false)
        )

        let lockfile = resourcesRoot.appendingPathComponent("Cargo.lock", isDirectory: false)
        if fileManager.fileExists(atPath: lockfile.path) {
            try fileManager.copyItem(
                at: lockfile,
                to: restoredManifestDir.appendingPathComponent("Cargo.lock", isDirectory: false)
            )
        }

        try fileManager.copyItem(
            at: main,
            to: restoredMainDir.appendingPathComponent("main.rs", isDirectory: false)
        )

        for file in supportFiles {
            try fileManager.copyItem(
                at: resourcesRoot.appendingPathComponent(file, isDirectory: false),
                to: restoredSupportDir.appendingPathComponent(file, isDirectory: false)
            )
        }

        return restoredManifestDir.appendingPathComponent("Cargo.toml", isDirectory: false)
    }
}

struct RemoteLinuxPlatform {
    let primaryTarget: String
    let fallbackTarget: String
}

private struct BuildAttempt {
    let label: String
    let command: [String]
}
