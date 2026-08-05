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
    var enabled: Bool

    static func codex(port: Int?) -> TargetBinding {
        TargetBinding(
            id: "codex",
            displayName: "Codex",
            callerCapability: "cap-codex-caller-\(UUID().uuidString.prefix(8))",
            internalCapability: "cap-codex-internal-\(UUID().uuidString.prefix(8))",
            listenerHost: "127.0.0.1",
            listenerPort: port,
            stateDirectoryPath: "codex",
            enabledProviderInstanceIDs: [],
            configFingerprint: nil,
            enabled: true
        )
    }
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
