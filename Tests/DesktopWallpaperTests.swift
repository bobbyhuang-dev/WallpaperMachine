import AppKit
import ImageIO
import QuartzCore
import XCTest
@testable import MacWallpaperEngine

@MainActor
private final class MemoryDesktopWorkspace: DesktopPictureWorkspace {
    var pictures: [DesktopPictureTarget: DesktopPicture] = [:]
    var writes: [DesktopPictureTarget] = []
    var failures: Set<DesktopPictureTarget> = []
    var didWrite: (() -> Void)?
    var didEnumerate: (() -> Void)?

    func targets() -> [DesktopPictureTarget] {
        didEnumerate?()
        return pictures.keys.sorted { ($0.display + ($0.space ?? "")) < ($1.display + ($1.space ?? "")) }
    }
    func currentPicture(target: DesktopPictureTarget) -> DesktopPicture? { pictures[target] }
    func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) throws {
        if failures.contains(target) { throw CocoaError(.fileWriteNoPermission) }
        pictures[target] = picture
        writes.append(target)
        didWrite?()
    }
}

private actor ControlledPosterEncoder {
    private var requests: [Data: CheckedContinuation<Data, Never>] = [:]
    func encode(_ frame: DesktopPosterFrame) async -> Data {
        await withCheckedContinuation { requests[frame.pixels] = $0 }
    }
    func has(_ data: Data) -> Bool { requests[data] != nil }
    func finish(_ data: Data) { requests.removeValue(forKey: data)?.resume(returning: data) }
}

final class DesktopWallpaperTests: XCTestCase {
    private var root: URL!
    private let one = DesktopPictureTarget(display: "1", space: "one")
    private let two = DesktopPictureTarget(display: "1", space: "two")
    private let external = DesktopPictureTarget(display: "2", space: "external")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-poster-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func original(_ name: String) -> DesktopPicture {
        DesktopPicture(url: root.appendingPathComponent(name + ".heic"),
                       scaling: Int(NSImageScaling.scaleProportionallyDown.rawValue),
                       allowClipping: true, fill: [0.1, 0.2, 0.3, 1])
    }

    @MainActor
    func testNewWallpaperUpdatesEverySpaceImmediatelyWithoutVisitingThem() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("first"), two: original("second")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        workspace.writes.removeAll()
        // Apply another wallpaper in place: no active-space event exists in this fake.
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertEqual(Set(workspace.writes), [one, two])
        for target in [one, two] {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[target]?.url)), Data([2]))
        }
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("first"))
        XCTAssertEqual(workspace.pictures[two], original("second"))
    }

    @MainActor
    func testMultipleDisplaysKeepTheirOwnRenderedFramesAndDisabledDisplayRestores() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("primary"), two: original("primary"), external: original("external")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        for target in [one, two] {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[target]?.url)), Data([1]))
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[external]?.url)), Data([2]))
        try ledger.synchronize(posters: ["1": Data([3])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.pictures[external], original("external"))
        XCTAssertNotEqual(workspace.pictures[one], original("primary"))
    }

    @MainActor
    func testFrameURLsAreImmutableAndPrunedOnlyAfterAllSpacesUpdate() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("same"), two: original("same")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        var urls: Set<URL> = []
        for value in UInt8(0)..<20 {
            try ledger.synchronize(posters: ["1": Data([value])], liveDisplays: ["1"])
            urls.insert(try XCTUnwrap(workspace.pictures[one]?.url))
        }
        XCTAssertEqual(urls.count, 20, "Never alternate stale WallpaperAgent cache keys")
        XCTAssertEqual(workspace.pictures[one]?.url, workspace.pictures[two]?.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.count, 1)
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("same"))
    }

    @MainActor
    func testIdenticalFramesSkipWritesButNewSpacesStillSynchronize() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.writes.count, 1)
        workspace.pictures[two] = original("new-space")
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.writes.count, 2)
        XCTAssertEqual(workspace.writes.last, two)
    }

    @MainActor
    func testSharedPosterJournalsOnceAndStillRestoresAfterRelaunch() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("same"), two: original("same")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        let journal = root.appendingPathComponent("originals.json")
        let marker = Date(timeIntervalSince1970: 1_000)
        var writes = 0
        workspace.didWrite = {
            writes += 1
            if writes == 1 {
                try! FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: journal.path)
            }
        }
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date, marker)
        workspace.didWrite = nil
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("same"))
        XCTAssertEqual(workspace.pictures[two], original("same"))
    }

    @MainActor
    func testFailedJournalSaveCannotBeSkippedOnRetry() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        let journal = root.appendingPathComponent("originals.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"]))
        XCTAssertTrue(workspace.writes.isEmpty)
        try FileManager.default.removeItem(at: journal)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(Set(workspace.writes), [one, two])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertEqual(workspace.pictures[two], original("before"))
    }

    @MainActor
    func testRelaunchRestoresInactiveSpacesAndNativeConfiguration() throws {
        let workspace = MemoryDesktopWorkspace()
        var before = original("before")
        before.nativeOptions = try PropertyListSerialization.data(fromPropertyList: [
            "ImageFilePath": before.url.path, "DynamicStyle": 2,
            "Placement": "SizeToFit", "Change": "TimeInterval", "ChangeDuration": 900
        ], format: .binary, options: 0)
        workspace.pictures = [one: before, two: before]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
        XCTAssertEqual(workspace.pictures[two], before)
    }

    @MainActor
    func testInheritedNativeSelectionSynchronizesAndRestoresAcrossRelaunch() throws {
        let workspace = MemoryDesktopWorkspace()
        let before = try DesktopSpaceWallpaperAPI.decodePicture([:])
        XCTAssertFalse(before.url.isFileURL)
        XCTAssertTrue(try DesktopSpaceWallpaperAPI.configuration(before).isEmpty)
        workspace.pictures = [one: before, two: before]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1, 2, 3])], liveDisplays: ["1"])
        XCTAssertTrue(try XCTUnwrap(workspace.pictures[one]).url.isFileURL)
        XCTAssertEqual(workspace.pictures[one], workspace.pictures[two])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
        XCTAssertEqual(workspace.pictures[two], before)
        XCTAssertTrue(try DesktopSpaceWallpaperAPI.configuration(XCTUnwrap(workspace.pictures[one])).isEmpty)
    }

    @MainActor
    func testPathlessNativeOptionsArePreservedAndAcknowledgementIsNotFalseSuccess() throws {
        let native: [String: Any] = ["Placement": "Crop", "DynamicStyle": 2]
        let picture = try DesktopSpaceWallpaperAPI.decodePicture(native)
        XCTAssertTrue(NSDictionary(dictionary: try DesktopSpaceWallpaperAPI.configuration(picture)).isEqual(to: native))
        XCTAssertTrue(DesktopSpaceWallpaperAPI.acknowledges([:], expected: [:]))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges(["ImageFilePath": "/tmp/poster.png"], expected: [:]))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges([:], expected: native))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges([:], expected: ["ImageFilePath": "/tmp/poster.png"]))
        XCTAssertTrue(DesktopSpaceWallpaperAPI.acknowledges(["ImageFilePath": "/tmp/poster.png"], expected: ["ImageFilePath": "tmp/poster.png"]))
    }

    @MainActor
    func testUnreadableOriginalReportsFailureWithoutWriting() throws {
        let workspace = MemoryDesktopWorkspace()
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        XCTAssertThrowsError(try ledger.apply(png: Data([1]), target: one))
        XCTAssertTrue(workspace.writes.isEmpty)
    }

    @MainActor
    func testLegacyAlternatingJournalMigratesWithoutLosingOriginals() throws {
        let before = original("before")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        try JSONSerialization.data(withJSONObject: [
            "old-a.png": ["original": encoded, "alternate": "old-b.png"],
            "old-b.png": ["original": encoded, "alternate": "old-a.png"]
        ]).write(to: root.appendingPathComponent("originals.json"))
        try Data([0]).write(to: root.appendingPathComponent("old-a.png"))
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: .poster(root.appendingPathComponent("old-a.png"))]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
    }

    @MainActor
    func testUserWallpaperChangeIsNotOverwrittenOnRestore() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        workspace.pictures[two] = original("user-change")
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[two], original("user-change"))
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[two], original("user-change"))
    }

    @MainActor
    func testFailedSpaceDoesNotBlockOthersOrDeleteItsPreviousPosterAndCanRetry() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let oldURL = try XCTUnwrap(workspace.pictures[two]?.url)
        workspace.failures = [two]
        XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"]))
        XCTAssertEqual(try Data(contentsOf: oldURL), Data([1]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
        workspace.failures = []
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(workspace.pictures[one]?.url, workspace.pictures[two]?.url)
    }

    @MainActor
    func testLoadingRendererKeepsPreviousWallpaperAndFallbackDoesNotPruneUnseenSpaces() throws {
        let workspace = MemoryDesktopWorkspace()
        let target = DesktopPictureTarget(display: "1", space: nil)
        workspace.pictures = [target: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let old = try XCTUnwrap(workspace.pictures[target])
        try ledger.synchronize(posters: [:], liveDisplays: ["1"])
        XCTAssertEqual(workspace.pictures[target], old)
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))
    }

    @MainActor
    func testMissingDisplayAndCorruptJournalNeverWriteWallpaper() throws {
        let workspace = MemoryDesktopWorkspace()
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["missing": Data([1])], liveDisplays: ["missing"])
        try ledger.restoreAll()
        XCTAssertTrue(workspace.writes.isEmpty)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("originals.json"))
        XCTAssertThrowsError(try DesktopWallpaperLedger(folder: root, workspace: workspace))
    }

    @MainActor
    func testTopologyEnumeratesInactiveDesktopSpacesExcludesFullscreenAndSupportsSharedSpaces() {
        let groups: [[String: Any]] = [["Display Identifier": "uuid-a", "Spaces": [
            ["uuid": "one", "type": 0], ["uuid": "two", "type": 0],
            ["uuid": "full", "type": 4], ["uuid": "", "type": 0], ["uuid": "unknown"]
        ]], ["Display Identifier": "uuid-b", "Spaces": [["uuid": "external", "type": 0]]]]
        XCTAssertEqual(Set(DesktopSpaceWallpaperAPI.targets(groups: groups, displays: ["1": "UUID-A", "2": "UUID-B"])), [one, two, external])
        let shared: [[String: Any]] = [["Display Identifier": "Main", "Spaces": [["uuid": "one", "type": 0]]]]
        XCTAssertEqual(Set(DesktopSpaceWallpaperAPI.targets(groups: shared, displays: ["1": "A", "2": "B"])), [one, DesktopPictureTarget(display: "2", space: "one")])
    }

    @MainActor
    func testNativeConfigurationPreservesOriginalOptionsAndNormalizesPaths() throws {
        var before = original("before")
        before.nativeOptions = try PropertyListSerialization.data(fromPropertyList: [
            "ImageFilePath": before.url.path, "Placement": "Centered", "DynamicStyle": 2,
            "ChangePath": root.path, "ChangeDuration": 100, "BackgroundColor": [0.1, 0.2, 0.3]
        ], format: .binary, options: 0)
        let config = try DesktopSpaceWallpaperAPI.configuration(before)
        XCTAssertEqual(config["ImageFilePath"] as? String, String(before.url.path.dropFirst()))
        XCTAssertEqual(config["Placement"] as? String, "Centered")
        XCTAssertEqual(config["DynamicStyle"] as? Int, 2)
        XCTAssertEqual(config["ChangeDuration"] as? Int, 100)
        XCTAssertEqual(try DesktopSpaceWallpaperAPI.configuration(original("legacy-fill"))["Placement"] as? String, "Crop")
        XCTAssertEqual(try DesktopSpaceWallpaperAPI.configuration(.poster(before.url))["Placement"] as? String, "FillScreen")
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL(String(before.url.path.dropFirst())), before.url)
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL(before.url.absoluteString), before.url)
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL("/~/Pictures/test.png"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/test.png"))
    }

    @MainActor
    func testRefreshRequestsFirstFrameSynchronouslyAndCoalescesABurst() async throws {
        let workspace = MemoryDesktopWorkspace()
        let layer = CAMetalLayer() // unattached: never creates a window or renderer
        let center = NotificationCenter()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center)
        var requests = 0
        let observer = center.addObserver(forName: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: layer, queue: nil) { _ in requests += 1 }
        defer { center.removeObserver(observer); sync.stop() }
        sync.start()
        workspace.didEnumerate = { XCTAssertGreaterThan(requests, 0, "Request pixels before native synchronization") }
        sync.refresh()
        XCTAssertEqual(requests, 1, "Apply must request a frame before refresh returns, never behind a timer")

        // Snapshot churn (menu opening, volume changes, display refreshes) must
        // not multiply GPU readbacks: the burst collapses into one trailing fire.
        for _ in 0..<5 { sync.refresh() }
        XCTAssertEqual(requests, 1, "A burst inside the throttle window must not re-read the swapchain")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(requests, 2, "The coalesced refresh must still land so the poster matches final state")
    }

    @MainActor
    func testFirstReadyFrameUpdatesAllSpacesWithoutRefreshEvent() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center,
                                            encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        let updated = expectation(description: "Both desktops updated")
        updated.expectedFulfillmentCount = 2
        workspace.didWrite = { updated.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(Set(workspace.writes), [one, two])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([1]))
    }

    @MainActor
    func testDelayedOldLayerFrameCannotOverwriteNewWallpaper() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let center = NotificationCenter(), oldLayer = CAMetalLayer(), newLayer = CAMetalLayer()
        var surfaces = [DesktopPosterSurface(layer: oldLayer, display: "1")]
        let encoder = ControlledPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace, surfaces: { surfaces }, frameCenter: center,
                                            encode: { await encoder.encode($0) })
        sync.start()
        defer { sync.stop() }
        let old = Data([1]), new = Data([2])
        post(old, layer: oldLayer, center: center)
        try await waitFor(encoder, data: old)
        surfaces = [DesktopPosterSurface(layer: newLayer, display: "1")]
        sync.refresh()
        post(new, layer: newLayer, center: center)
        try await waitFor(encoder, data: new)
        let updated = expectation(description: "New frame updates both Spaces")
        updated.expectedFulfillmentCount = 2
        workspace.didWrite = { updated.fulfill() }
        await encoder.finish(new)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        await encoder.finish(old)
        // Let the old encoding continuation run; it must fail its layer guard.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(workspace.writes.count, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), new)
    }

    @MainActor
    func testNativeTransientFailureRetriesWithoutSpaceChange() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        workspace.failures = [two]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center,
                                            encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        let first = expectation(description: "First Space updated")
        workspace.didWrite = { first.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [first], timeout: 2)
        let retry = expectation(description: "Failed Space retried")
        workspace.didWrite = { retry.fulfill() }
        workspace.failures = []
        await fulfillment(of: [retry], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(Set(workspace.writes), [one, two])
    }

    @MainActor
    func testNativeHandoffPreservesPosterAndJournalWithoutLegacyRestore() async throws {
        let workspace = MemoryDesktopWorkspace()
        let before = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: before]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let encoder = ControlledPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center, encode: { await encoder.encode($0) })
        sync.start()
        let first = Data([1]), delayed = Data([2])
        post(first, layer: layer, center: center)
        try await waitFor(encoder, data: first)
        let updated = expectation(description: "Poster installed")
        workspace.didWrite = { updated.fulfill() }
        await encoder.finish(first)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        let poster = try XCTUnwrap(workspace.pictures[one])
        post(delayed, layer: layer, center: center)
        try await waitFor(encoder, data: delayed)
        // The real legacy API rejects restoring an empty native selection.
        // Handoff must not call it, delete the poster, or forget its original.
        workspace.failures = [one]
        sync.suspendForNativeProvider()
        await encoder.finish(delayed)
        for _ in 0..<20 { await Task.yield() }
        sync.refresh()
        XCTAssertEqual(workspace.writes, [one])
        XCTAssertEqual(workspace.pictures[one], poster)
        XCTAssertEqual(try Data(contentsOf: poster.url), first)
        workspace.failures = []
        let recovered = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try recovered.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
    }

    @MainActor
    private func post(_ pixels: Data, layer: CAMetalLayer, center: NotificationCenter) {
        center.post(name: Notification.Name("MacWallpaperEngine.desktopPosterReady"), object: layer,
                    userInfo: ["pixels": pixels, "width": 1, "height": 1, "bgra": false])
    }

    private func waitFor(_ encoder: ControlledPosterEncoder, data: Data) async throws {
        for _ in 0..<200 {
            if await encoder.has(data) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Encoder did not receive frame")
        throw CocoaError(.coderInvalidValue)
    }

    func testRendererPixelsKeepChannelsOrientationAndDimensions() throws {
        let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let bgra = Data([0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255])
        for (pixels, blueFirst) in [(rgba, false), (bgra, true)] {
            let png = try DesktopPosterEncoder.png(pixels: pixels, width: 2, height: 2, bgra: blueFirst)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(bitmap.pixelsWide, 2)
            XCTAssertEqual(bitmap.pixelsHigh, 2)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            for (x, y, expected) in [(0, 0, [255, 0, 0]), (1, 0, [0, 255, 0]), (0, 1, [0, 0, 255]), (1, 1, [255, 255, 255])] {
                var samples = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&samples, atX: x, y: y)
                XCTAssertEqual(Array(samples.prefix(3)), expected)
            }
        }
    }

    func testEncoderRejectsInvalidSizesAndTruncatedPixels() {
        for (width, height, bytes) in [(0, 2, 0), (-1, 2, 0), (2, 2, 15), (2, 2, 17), (Int.max, 1, 0), (16_384, 16_384, 0)] {
            XCTAssertThrowsError(try DesktopPosterEncoder.png(pixels: Data(count: bytes), width: width, height: height, bgra: false))
        }
    }
}
