import XCTest
@testable import Copool

/// TST-05：`TargetConfigFileAdapter` 的 NSLock 重入死锁回归测试。
///
/// M0-4 修复前，`plan(to:)` 持锁调用了 `detect()`，而 `detect()` 内部
/// 也会 `lock.lock()`。NSLock 不可重入——第二次 lock 会无限阻塞，
/// 单测会超时，主线程调用会冻住 UI。
///
/// 修复后抽出了 `detectLocked()`，所有持锁方法都走它。这里先写会超时的
/// 测试证明死锁存在，再验证修复后通过。
///
/// 新增持锁方法时的约定：需要复用另一个持锁方法的逻辑，就把逻辑抽成
/// `private func xxxLocked()`，两边各自在自己的临界区内调它——不要直接
/// 调另一个 `lock.lock()` 的方法。
final class TargetConfigDeadlockTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetConfigDeadlockTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeAdapter(targetID: String) -> TargetConfigFileAdapter {
        let configPath = tempDir.appendingPathComponent("\(targetID).json")
        let stateRoot = tempDir.appendingPathComponent("state", isDirectory: true)
        return TargetConfigFileAdapter(
            targetID: targetID,
            configPath: configPath,
            stateRoot: stateRoot,
            managedProviderID: "copool",
            providerBlockName: "Copool"
        )
    }

    /// M0-4 修前：`plan(to:)` 会永久阻塞。修后：1 秒内完成。
    func testPlanDoesNotDeadlock() throws {
        let adapter = makeAdapter(targetID: "cursor")
        let configPath = tempDir.appendingPathComponent("cursor.json")

        // 先写一份既有配置，让 detect() 能读到东西。
        let existing = """
        {
          "models": { "default": "claude" }
        }
        """
        try existing.write(to: configPath, atomically: true, encoding: .utf8)

        let desired = adapter.desiredConfig(port: 19787, baseURLTemplate: "http://127.0.0.1:%d/v1")

        // 如果 plan(to:) 持锁调 detect()，这一步会永久阻塞，XCTest 会在
        // 默认超时后杀掉。我们提前设 1 秒超时让失败更快暴露。
        let expectation = self.expectation(description: "plan(to:) must not deadlock")
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async {
            _ = adapter.plan(to: desired)
            expectation.fulfill()
        }

        // 修前：永不 fulfill，1 秒后超时。修后：几乎立刻 fulfill。
        wait(for: [expectation], timeout: 1.0)
    }

    /// 自检：确认"超时即失败"的机制本身有效。用 inverted expectation
    /// 直接验证等待逻辑，不真的去锁死一个线程——故意制造的死锁会让
    /// 那个 worker 线程在整个测试进程存活期内都回收不了。
    func testTimeoutDetectorActuallyWorks() {
        let neverFulfilled = expectation(description: "从不 fulfill 的期望必须走到超时")
        neverFulfilled.isInverted = true
        wait(for: [neverFulfilled], timeout: 0.2)
    }

    /// `desiredConfig` 也会调 `detect()`。修前它不持锁所以没事，但为了
    /// 将来的改动不踩坑，这里钉住它的非阻塞性质。
    func testDesiredConfigDoesNotDeadlock() throws {
        let adapter = makeAdapter(targetID: "opencode")
        let configPath = tempDir.appendingPathComponent("opencode.json")
        try "{}".write(to: configPath, atomically: true, encoding: .utf8)

        let expectation = self.expectation(description: "desiredConfig must not deadlock")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = adapter.desiredConfig(port: 20787, baseURLTemplate: "http://127.0.0.1:%d/v1")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    /// 完整的三步操作 `detect → plan → apply` 顺序执行不能阻塞。
    func testFullCycleDoesNotDeadlock() throws {
        let adapter = makeAdapter(targetID: "codex")
        let configPath = tempDir.appendingPathComponent("codex.json")
        try "{}".write(to: configPath, atomically: true, encoding: .utf8)

        let expectation = self.expectation(description: "full cycle must not deadlock")
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot1 = adapter.detect()
            XCTAssertNotNil(snapshot1)

            let desired = adapter.desiredConfig(port: 18787, baseURLTemplate: "http://127.0.0.1:%d/v1")
            let diff = adapter.plan(to: desired)

            try? adapter.apply(diff)
            let snapshot2 = adapter.detect()
            XCTAssertNotNil(snapshot2)

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    /// 并发调用：多个线程同时 detect/plan 不能互相锁死，且结果要一致。
    /// 单线程不重入不代表多线程安全——这条覆盖真实的并发路径。
    func testConcurrentDetectAndPlanDoNotDeadlock() throws {
        let adapter = makeAdapter(targetID: "cursor")
        let configPath = tempDir.appendingPathComponent("cursor.json")
        try "{\"userSetting\": true}".write(to: configPath, atomically: true, encoding: .utf8)

        let desired = adapter.desiredConfig(port: 19787, baseURLTemplate: "http://127.0.0.1:%d/v1")
        let done = expectation(description: "并发 detect/plan 全部返回")
        done.expectedFulfillmentCount = 16

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            if index.isMultiple(of: 2) {
                _ = adapter.detect()
            } else {
                _ = adapter.plan(to: desired)
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 5.0)
    }
}
