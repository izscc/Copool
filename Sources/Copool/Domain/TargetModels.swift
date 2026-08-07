import Foundation

// MARK: - Target binding domain (Phase 4)

/// One bound target app (Codex today; Cursor/opencode are future bindings).
/// Each binding owns its caller/internal capability, listener, state
/// directory and provider selection (AC-008) — nothing is shared implicitly.
struct TargetBinding: Codable, Equatable, Sendable, Identifiable {
    /// Stable id, e.g. "codex" / "cursor" / "opencode".
    var id: String
    var displayName: String
    /// Capabilities this binding may use. Caller capability authorizes the
    /// target app; internal capability authorizes our own control surface.
    var callerCapability: String
    var internalCapability: String
    /// Bind address — loopback only (AC-009).
    var listenerHost: String
    var listenerPort: Int?
    /// Where target-owned runtime state lives (independent per target).
    var stateDirectoryPath: String
    /// Provider instances this binding may route to.
    var enabledProviderInstanceIDs: [String]
    /// Current managed configuration fingerprint (for verify/rollback).
    var configFingerprint: String?
    /// 上次写入配置时目录长什么样（FR-CAT-11）。目录之后变了就与
    /// `CatalogFingerprint.compute` 的结果不符，UI 据此提示「配置已过期」。
    /// nil = 还没应用过，此时不算过期——没配过和配过又变了是两件事。
    /// 默认 nil：存量绑定文件里没有这个键，解码后落到 nil，
    /// 也就是"没应用过"——不会让升级后的第一次打开满屏都是过期提示。
    var appliedCatalogFingerprint: String? = nil
    var enabled: Bool

    /// 目录是否已经漂移到与已应用配置不一致。
    ///
    /// 从没应用过时返回 false：那种情况该提示的是「未配置」，
    /// 用「已过期」会让用户去找一个不存在的旧配置（FR-CAT-11）。
    func isCatalogStale(against registry: ProviderRegistryV2) -> Bool {
        guard let appliedCatalogFingerprint else { return false }
        let current = CatalogFingerprint.compute(
            registry: registry,
            enabledInstanceIDs: enabledProviderInstanceIDs
        )
        return current != appliedCatalogFingerprint
    }

    static func codex(port: Int? = nil) -> TargetBinding {
        TargetBinding(
            id: "codex",
            displayName: "Codex",
            callerCapability: "targets/codex/caller-capability",
            internalCapability: "targets/codex/internal-capability",
            listenerHost: "127.0.0.1",
            listenerPort: port,
            stateDirectoryPath: "codex",
            enabledProviderInstanceIDs: [],
            configFingerprint: nil,
            appliedCatalogFingerprint: nil,
            enabled: true
        )
    }

    static func beta(id: String, displayName: String) -> TargetBinding {
        TargetBinding(
            id: id,
            displayName: displayName,
            callerCapability: "targets/\(id)/caller-capability",
            internalCapability: "targets/\(id)/internal-capability",
            listenerHost: "127.0.0.1",
            listenerPort: nil,
            stateDirectoryPath: id,
            enabledProviderInstanceIDs: [],
            configFingerprint: nil,
            appliedCatalogFingerprint: nil,
            enabled: false
        )
    }
}

struct TargetBindingStore: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var bindings: [TargetBinding]

    init(version: Int = currentVersion, bindings: [TargetBinding] = []) {
        self.version = version
        self.bindings = bindings
    }

    static let defaults = TargetBindingStore(bindings: [
        .codex(),
        .beta(id: "cursor", displayName: "Cursor"),
        .beta(id: "opencode", displayName: "opencode")
    ])
}

/// Per-target state directory layout (independent dirs, AC-008).
enum TargetStatePaths {
    static func directory(for bindingID: String, root: URL) -> URL {
        root.appendingPathComponent(bindingID, isDirectory: true)
    }

    static func configBackupPath(for bindingID: String, root: URL) -> URL {
        directory(for: bindingID, root: root).appendingPathComponent("config-backup.toml")
    }

    static func configFingerprintPath(for bindingID: String, root: URL) -> URL {
        directory(for: bindingID, root: root).appendingPathComponent("config-fingerprint.txt")
    }
}

/// Detection result for one target: what is on disk right now.
struct TargetDetection: Equatable, Sendable {
    var bindingID: String
    var configExists: Bool
    var configText: String?
    var managedBlocksPresent: Int
    /// User-owned lines (unmarked) preserved by the last managed write.
    var preservedUserLineCount: Int
}

/// Result of an apply.
struct ApplyReceipt: Equatable, Sendable {
    var bindingID: String
    var appliedAt: Int64
    var backupPath: String
    var fingerprint: String
}

/// Result of a verify.
struct VerificationReport: Equatable, Sendable {
    var bindingID: String
    var matches: Bool
    var detail: String
}
