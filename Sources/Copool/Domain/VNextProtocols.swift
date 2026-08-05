import Foundation

// MARK: - vNext façade protocols (Phase 1)
//
// These protocols draw the module boundaries the PRD requires without moving
// files between targets: the app talks to engines and stores through these
// surfaces, and the legacy implementations conform until the standalone
// CopoolRouterHost lands (Phase 6). No behavior changes in this phase.

/// The routing engine surface the application depends on.
///
/// Currently implemented by the in-process `SwiftNativeProxyRuntimeService`;
/// Phase 6 moves the same surface behind `CopoolRouterHost` (UDS control
/// API), so callers must not depend on in-process details. Lifecycle
/// (start/stop) stays on the legacy `ProxyRuntimeService` until the host
/// lands; this protocol is the status/capability contract both sides speak.
@preconcurrency
protocol RouterEngine: Sendable {
    func engineStatus() async -> RouterEngineStatus
    /// Static capabilities of the engine (ports, transports, targets).
    var engineCapabilities: RouterEngineCapabilities { get }
}

/// Static capability facts a caller can rely on without probing.
struct RouterEngineCapabilities: Equatable, Sendable {
    var transports: [String]
    var supportedPaths: [String]
    var maxInboundRequestBytes: Int
}

/// Observable state of the routing engine, independent of the legacy
/// `ApiProxyStatus` shape so the façade can evolve.
struct RouterEngineStatus: Equatable, Sendable {
    var running: Bool
    var port: Int?
    var apiKey: String?
    var baseURL: String?
    var availableAccounts: Int
    var activeAccountID: String?
    var activeAccountLabel: String?
    var lastError: String?
}

/// Secret storage abstraction. Implementations must be failable and
/// time-boxed: callers degrade instead of blocking (see KeychainSecretStore).
protocol SecureStore: Sendable {
    func read(account: String, timeout: TimeInterval) -> String?
    @discardableResult
    func write(account: String, value: String, timeout: TimeInterval) -> Bool
    @discardableResult
    func delete(account: String, timeout: TimeInterval) -> Bool
}

/// Immutable snapshot of a target's current configuration (the file as it
/// exists on disk), for diffing.
struct TargetConfigSnapshot: Equatable, Sendable {
    var targetID: String
    var content: String
    var modifiedAt: Date?
}

/// A planned change to a target config: what apply would write.
struct TargetConfigDiff: Equatable, Sendable {
    var targetID: String
    /// nil when the file does not exist yet.
    var before: TargetConfigSnapshot?
    var after: TargetConfigSnapshot
    /// Lines the user owns (left untouched) — never overwrite unmarked user
    /// configuration.
    var preservedUserLines: [String]
}

/// Manages one target's configuration with plan/apply/verify/rollback.
///
/// Phase 4 implements this for the Codex target (config.toml + models cache);
/// the protocol exists now so the UI and tests can program against it.
protocol TargetConfigManaging: Sendable {
    /// Reads the target's current on-disk configuration, or nil when absent.
    func detect() -> TargetConfigSnapshot?

    /// Computes what apply would write, without touching the file.
    func plan(to desired: String) -> TargetConfigDiff

    /// Atomically applies a planned diff; restores the original on failure.
    func apply(_ diff: TargetConfigDiff) throws

    /// Verifies the applied state matches the planned state.
    func verify(_ diff: TargetConfigDiff) -> Bool

    /// Restores the pre-apply snapshot.
    func rollback(_ diff: TargetConfigDiff) throws
}
