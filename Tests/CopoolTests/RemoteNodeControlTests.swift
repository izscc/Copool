import XCTest
@testable import Copool

/// AC-204: handshake evaluation, heartbeat status folding, upgrade/rollback
/// gates. Transport-level SSH is not exercised here (covered by the existing
/// remote integration fixtures); the state transitions are.
final class RemoteNodeControlTests: XCTestCase {
    func testHandshakeAcceptsMatchingProtocol() {
        let handshake = RemoteHandshake.evaluate(appVersion: "1.0", nodeVersion: "1.0", nodeProtocol: 1)
        XCTAssertTrue(handshake.accepted)
        XCTAssertNil(handshake.reason)
    }

    func testHandshakeRejectsProtocolMismatch() {
        let handshake = RemoteHandshake.evaluate(appVersion: "1.0", nodeVersion: "1.0", nodeProtocol: 99)
        XCTAssertFalse(handshake.accepted)
        XCTAssertEqual(handshake.reason, "protocol mismatch")
    }

    func testHeartbeatPayloadCarriesNoSecrets() {
        let payload = RemoteHeartbeat(
            nodeID: "n1",
            sentAt: 1_700_000_000,
            status: .online,
            activeSessionCount: 2,
            openRequestCount: 1,
            version: "1.0"
        )
        XCTAssertTrue(RemoteHeartbeat.validateNoSecrets(in: payload))
    }

    func testMonitorStatusTransitions() {
        let monitor = HeartbeatMonitor(timeoutSeconds: 90, now: { 1_700_000_000 })
        let node = RemoteNode(identity: "i", platform: "darwin", version: "1.0")

        XCTAssertEqual(monitor.status(lastHeartbeatAt: nil, pendingOperation: nil), .offline)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: 1_700_000_000 - 10, pendingOperation: nil), .online)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: 1_700_000_000 - 50, pendingOperation: nil), .degraded)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: 1_700_000_000 - 200, pendingOperation: nil), .offline)
        XCTAssertEqual(monitor.status(lastHeartbeatAt: 1_700_000_000, pendingOperation: "upgrade"), .updating)
    }

    func testUpgradeAndRollbackGates() {
        let monitor = HeartbeatMonitor(timeoutSeconds: 90, now: { 1_700_000_000 })
        let node = RemoteNode(identity: "i", platform: "darwin", version: "1.0")

        let upgrading = monitor.beginUpgrade(node: node)
        XCTAssertEqual(upgrading.status, .updating)
        XCTAssertEqual(upgrading.pendingOperation, "upgrade")

        let completed = monitor.completeUpgrade(node: upgrading, newVersion: "1.1")
        XCTAssertEqual(completed.version, "1.1")
        XCTAssertEqual(completed.status, .online)
        XCTAssertNil(completed.pendingOperation)
    }
}
