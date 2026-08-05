import XCTest
@testable import Copool

/// Phase 9 acceptance: AC-204 (no keychain secrets in remote payloads),
/// handshake compat, heartbeat state machine, upgrade/rollback.
final class RemoteNodeTests: XCTestCase {
    func testHandshakeAcceptsMatchingProtocol() {
        let handshake = RemoteHandshake.evaluate(appVersion: "2.1.0", nodeVersion: "2.1.0", nodeProtocol: RemoteHandshake.currentProtocol)
        XCTAssertTrue(handshake.accepted)
        XCTAssertNil(handshake.reason)
    }

    func testHandshakeRejectsProtocolMismatch() {
        let handshake = RemoteHandshake.evaluate(appVersion: "2.1.0", nodeVersion: "2.0.0", nodeProtocol: RemoteHandshake.currentProtocol + 1)
        XCTAssertFalse(handshake.accepted)
        XCTAssertEqual(handshake.reason, "protocol mismatch")
    }

    // MARK: - AC-204 secret isolation

    func testHeartbeatPayloadContainsNoSecrets() {
        let heartbeat = RemoteHeartbeat(
            nodeID: "n-1",
            sentAt: 0,
            status: .online,
            activeSessionCount: 2,
            openRequestCount: 1,
            version: "2.1.0"
        )
        XCTAssertTrue(RemoteHeartbeat.validateNoSecrets(in: heartbeat))
        let encoded = (try! JSONEncoder().encode(heartbeat))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("keychain"))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("provider"))
    }

    // MARK: - Heartbeat state machine

    func testHeartbeatStatusTransitions() {
        let now: Int64 = 1_000_000
        let monitor = HeartbeatMonitor(timeoutSeconds: 90, now: { now })

        XCTAssertEqual(monitor.status(lastHeartbeatAt: nil, pendingOperation: nil), .offline)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: now - 10, pendingOperation: nil), .online)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: now - 50, pendingOperation: nil), .degraded)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: now - 100, pendingOperation: nil), .offline)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: now - 10, pendingOperation: "upgrade"), .updating)
    }

    func testUpgradeAndRollbackLifecycle() {
        let node = RemoteNode(identity: "i-1", platform: "macos", version: "2.1.0")
        let monitor = HeartbeatMonitor(timeoutSeconds: 90)

        let upgrading = monitor.beginUpgrade(node: node)
        XCTAssertEqual(upgrading.status, .updating)
        XCTAssertEqual(upgrading.pendingOperation, "upgrade")

        let completed = monitor.completeUpgrade(node: upgrading, newVersion: "2.2.0")
        XCTAssertEqual(completed.version, "2.2.0")
        XCTAssertNil(completed.pendingOperation)
        XCTAssertEqual(completed.status, .online)

        // Rollback semantics: completeUpgrade back to the previous version.
        let rolledBack = monitor.completeUpgrade(node: upgrading, newVersion: "2.1.0")
        XCTAssertEqual(rolledBack.version, "2.1.0")
        XCTAssertEqual(rolledBack.status, .online)
    }
}
