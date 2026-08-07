import XCTest
@testable import Copool

/// AC-202: user-confirmed TaskEnvelopes are delegated; pending-only gate;
/// trail is append-only.
final class TaskEnvelopeDispatcherTests: XCTestCase {
    private var trailURL: URL!

    override func setUpWithError() throws {
        trailURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("envelopes-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: trailURL)
    }

    func testPendingEnvelopeIsConfirmedAndDelegated() {
        let dispatcher = TaskEnvelopeDispatcher(trailURL: trailURL)
        let envelope = TaskEnvelope(sessionID: "s1", kind: .codingExecution, intent: "run tests")

        let delegated = dispatcher.confirmAndDelegate(envelope)

        XCTAssertEqual(delegated.status, .executing)
        XCTAssertTrue(delegated.userConfirmed)
        // Trail persisted.
        let trail = (try? String(contentsOf: trailURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(trail.isEmpty)
    }

    func testNonPendingEnvelopeIsNotDelegated() {
        let dispatcher = TaskEnvelopeDispatcher(trailURL: trailURL)
        var rejected = TaskEnvelope(sessionID: "s1", kind: .conversation, intent: "nope")
        rejected.reject()

        let result = dispatcher.confirmAndDelegate(rejected)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertFalse(result.userConfirmed)
    }

    func testCompleteAndFailTransitions() {
        let dispatcher = TaskEnvelopeDispatcher(trailURL: trailURL)
        let envelope = TaskEnvelope(sessionID: "s1", kind: .codingExecution, intent: "x")
        let executing = dispatcher.confirmAndDelegate(envelope)

        dispatcher.complete(executing.id)
        dispatcher.fail("missing", detail: "boom")

        let trail = (try? String(contentsOf: trailURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(trail.contains("\"completed\""))
    }

    func testExecutingEnvelopeCanBeCancelledAndAudited() {
        let dispatcher = TaskEnvelopeDispatcher(trailURL: trailURL)
        let executing = dispatcher.confirmAndDelegate(TaskEnvelope(sessionID: "s1", kind: .codingExecution, intent: "x"))
        dispatcher.cancel(executing.id)
        XCTAssertEqual(dispatcher.current(executing.id)?.status, .failed("cancelled"))
        let trail = (try? String(contentsOf: trailURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(trail.contains("cancelled"))
    }
}
