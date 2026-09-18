import XCTest
@testable import MacWallpaperEngine

/// The real FSEvents stream, as `UserAssetStore` uses it: one notification per settled
/// burst, a further one for a later change, nothing after `stop()`, and no wake-up at all
/// while the folder is idle.
///
/// Every measurement is taken against a baseline captured once the stream has been running
/// for a moment. A stream started in the same instant a folder is created can report that
/// creation, which is not a change this watcher invented; the store tolerates it because it
/// diffs rather than trusting the notification.
final class DirectoryWatcherTests: XCTestCase {
    private var folder: URL!

    /// Comfortably longer than the 0.25 s debounce, so a missing notification is a real
    /// absence rather than an unfinished one.
    private let window: TimeInterval = 2

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("directory-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    /// Runs the main run loop for `seconds` so main-queue notifications are delivered.
    ///
    /// Deliberately not an inverted `XCTestExpectation`: an inverted expectation fails when
    /// it is fulfilled, so fulfilling one on a timer fails every test that waits. This is a
    /// plain delay, and the assertions about what did or did not arrive belong in the tests.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func startedWatcher(_ counter: NotificationCounter) throws -> DirectoryWatcher {
        let watcher = DirectoryWatcher(url: folder, debounce: 0.25) { counter.increment() }
        guard watcher.isActive else {
            watcher.stop()
            throw XCTSkip("FSEvents is unavailable in this environment")
        }
        settle(window)
        counter.reset()
        return watcher
    }

    func testABurstOfWritesSettlesIntoASingleNotification() throws {
        let counter = NotificationCounter()
        let watcher = try startedWatcher(counter)
        defer { watcher.stop() }

        for index in 0..<8 { try write("file-\(index).png") }
        settle(window)
        XCTAssertEqual(counter.value, 1, "one settled burst must report once, not once per file")

        // A separate change later is a separate settle, not part of the first one.
        try write("later.png")
        settle(window)
        XCTAssertEqual(counter.value, 2)
    }

    func testARemovalIsReported() throws {
        try write("doomed.png")
        let counter = NotificationCounter()
        let watcher = try startedWatcher(counter)
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: folder.appendingPathComponent("doomed.png"))
        settle(window)
        XCTAssertEqual(counter.value, 1)
    }

    func testAnIdleFolderNeverNotifies() throws {
        let counter = NotificationCounter()
        let watcher = try startedWatcher(counter)
        defer { watcher.stop() }

        settle(window * 2)
        XCTAssertEqual(counter.value, 0, "an unchanged folder must never wake the watcher")
    }

    func testAStoppedWatcherReportsNothingFurther() throws {
        let counter = NotificationCounter()
        let watcher = try startedWatcher(counter)

        watcher.stop()
        XCTAssertFalse(watcher.isActive)
        for index in 0..<4 { try write("after-\(index).png") }
        settle(window)
        XCTAssertEqual(counter.value, 0)
    }
}

/// Counts notifications delivered on the main actor from a non-isolated test body.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}
