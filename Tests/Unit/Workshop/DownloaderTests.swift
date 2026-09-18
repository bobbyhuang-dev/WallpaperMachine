import Darwin
import XCTest

@testable import MacWallpaperEngine

@MainActor
final class DownloaderTests: XCTestCase {
  private let item = WorkshopItem(
    id: "123456", title: "Download lifecycle", creator: "Test", summary: "", previewURL: nil,
    tags: ["Video"], size: 0, subscriptions: 0)

  func testAnonymousAccountCannotStartDownload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mwe-invalid-account-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"))
    downloader.start(
      item: item, username: "anonymous", executable: root.appendingPathComponent("missing"),
      library: root.appendingPathComponent("Library"), onImported: {})
    XCTAssertFalse(downloader.isRunning)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertNil(downloader.downloadedID)
  }

    func testStagingSweepOnlyReclaimsDirectoriesNothingIsWorkingIn() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mwe-staging-sweep-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        // SteamCMD writes deep inside staging, which never moves the directory's own timestamp.
        func age(_ url: URL, to date: Date) throws {
            var paths = [url.path]
            if let walker = files.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in walker { paths.append(child.path) }
            }
            for path in paths {
                try files.setAttributes([.modificationDate: date], ofItemAtPath: path)
            }
        }
        func staging(_ name: String, stillWriting: Bool) throws -> URL {
            let url = root.appendingPathComponent(WorkshopDownloader.stagingPrefix + name, isDirectory: true)
            let content = url.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
            try files.createDirectory(at: content, withIntermediateDirectories: true)
            let item = content.appendingPathComponent("item")
            try Data("payload".utf8).write(to: item)
            try age(url, to: Date(timeIntervalSinceNow: -3600))
            if stillWriting {
                try files.setAttributes([.modificationDate: Date()], ofItemAtPath: item.path)
            }
            return url
        }

        let abandoned = try staging("abandoned", stillWriting: false)
        let claimed = try staging("claimed", stillWriting: false)
        let occupied = try staging("occupied", stillWriting: false)
        let writing = try staging("writing", stillWriting: true)
        let unrelated = root.appendingPathComponent("SteamSession", isDirectory: true)
        try files.createDirectory(at: unrelated, withIntermediateDirectories: false)

        // A live app holds its claim open for the whole download.
        let claim = open(claimed.appendingPathComponent("owner").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(claim, 0)
        defer { close(claim) }
        XCTAssertEqual(flock(claim, LOCK_EX | LOCK_NB), 0)

        // A crash leaves SteamCMD writing with the app that started it gone. SteamCMD inherits the
        // claim, so handing the locked descriptor to a child and dropping this process's own copy
        // is what an orphaned download looks like from a later launch.
        let inherited = open(occupied.appendingPathComponent("owner").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(inherited, 0)
        XCTAssertEqual(flock(inherited, LOCK_EX | LOCK_NB), 0)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30"]
        child.standardInput = FileHandle(fileDescriptor: inherited, closeOnDealloc: false)
        try child.run()
        close(inherited)
        defer { child.terminate() }

        WorkshopDownloader.removeAbandonedStaging(in: root, quietFor: 60)

        XCTAssertFalse(files.fileExists(atPath: abandoned.path), "Nothing holds or writes here; it must be reclaimed")
        XCTAssertTrue(files.fileExists(atPath: claimed.path), "A held claim must survive")
        XCTAssertTrue(files.fileExists(atPath: occupied.path), "A claim inherited by a surviving child must survive")
        XCTAssertTrue(files.fileExists(atPath: writing.path), "A stale directory timestamp must not condemn a live download")
        XCTAssertTrue(files.fileExists(atPath: unrelated.path), "Only staging directories are swept")
    }

    func testStagingSweepKeepsWhatItCannotInspect() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mwe-staging-faults-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        func staging(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(WorkshopDownloader.stagingPrefix + name, isDirectory: true)
            try files.createDirectory(at: url.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: url.appendingPathComponent("steamapps/item"))
            var paths = [url.path]
            if let walker = files.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in walker { paths.append(child.path) }
            }
            for path in paths {
                try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
            }
            return url
        }

        // Otherwise reclaimable: quiet, unclaimed, and nothing working inside it.
        let unreadableTree = try staging("unreadable-tree")
        let locked = unreadableTree.appendingPathComponent("steamapps/locked", isDirectory: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: false)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let unreadableClaim = try staging("unreadable-claim")
        let owner = unreadableClaim.appendingPathComponent("owner")
        try Data().write(to: owner)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: owner.path)
        defer { try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path) }

        let quiet = try staging("quiet")
        WorkshopDownloader.removeAbandonedStaging(in: root, quietFor: 60)
        XCTAssertTrue(files.fileExists(atPath: unreadableTree.path), "A tree that cannot be walked is not known to be idle")
        XCTAssertTrue(files.fileExists(atPath: unreadableClaim.path), "A claim that cannot be read is not known to be released")
        XCTAssertFalse(files.fileExists(atPath: quiet.path), "A fully inspected idle directory is still reclaimed")
    }

    func testSteamCMDInheritsTheStagingClaim() async throws {
        // A crash leaves this child writing on its own; the claim it inherits is what tells a later
        // launch the staging is still in use.
        let root = try makeRuntime("""
            [ -e /dev/fd/3 ] && printf inherited > ../claim-visible
            IFS= read -r finish
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = startDownload(in: root)
        defer { Task { await downloader.shutdown() } }
        let marker = root.appendingPathComponent("claim-visible")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "inherited")
    }

  func testImmediateShutdownWaitsForStagingCleanup() async throws {
    let root = try makeRuntime("IFS= read -r finish")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.start(
      item: item, username: "localcanceltest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), onImported: {})
    await downloader.shutdown()
    XCTAssertFalse(downloader.isRunning)
    XCTAssertTrue(downloader.wasCancelled)
    XCTAssertNil(downloader.downloadedID)
    let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    XCTAssertFalse(children.contains { $0.hasPrefix(".mac-wallpaper-engine-workshop-") })
  }

  func testShortSplitPromptsAllowPasswordAndGuardCodeBeforeDownload() async throws {
    let root = try makeRuntime(
      """
      printf 'Steam Console Client\\npass'
      sleep 0.1
      printf 'word: '
      IFS= read -r password
      [ "$password" = 'local-password' ] || exit 10
      printf '\\nLogging in using username/password.\\nSteam Guard co'
      sleep 0.1
      printf 'de: '
      IFS= read -r code
      [ "$code" = '12345' ] || exit 11
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"title":"Terminal fixture","type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'downloaded-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("local-password")
      try await waitUntil { downloader.prompt == .guardCode }
      downloader.submitSecret("12345")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "downloaded-content")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testMobileApprovalCanAdvanceToIndeterminateDownload() async throws {
    let root = try makeRuntime(
      """
      printf 'Please confirm the login in the Steam Mobile app on your phone.\\n'
      sleep 0.5
      printf 'Waiting for user info...OK\\nDownloading item 123456 ... (25%%)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.status == "Downloading Workshop files…" }
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.prompt)
      XCTAssertNil(downloader.errorMessage)
      await downloader.shutdown()
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testWorkshopDiskGrowthReportsProgressAgainstListedSize() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 512 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
      touch ../first-written
      while [ ! -f ../release-next ]; do sleep 0.02; done
      head -c 1024 /dev/zero > steamapps/workshop/downloads/431960/123456/part2
      touch ../second-written
      while [ ! -f ../release-finish ]; do sleep 0.02; done
      head -c 4096 /dev/zero > steamapps/workshop/downloads/431960/123456/part3
      touch ../third-written
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let downloader = startDownload(in: root, item: sizedItem)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("first-written").path) }
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 512)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      try Data().write(to: root.appendingPathComponent("release-next"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("second-written").path) }
      try await waitUntil { downloader.progress == 0.75 }
      XCTAssertEqual(downloader.bytesReceived, 1536)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      // More bytes than Steam listed never claim completion; only its success line does.
      try Data().write(to: root.appendingPathComponent("release-finish"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("third-written").path) }
      try await waitUntil { downloader.bytesReceived == 2048 }
      XCTAssertEqual(downloader.progress, 0.99)
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
    } catch { await downloader.shutdown(); throw error }
  }

  func testPreallocatedWorkshopFilesReportOnlyBytesThatCrossedTheNetwork() async throws {
    // Steam can allocate a file's full length before its chunks arrive; the tree then claims
    // the whole item at once while the network meter has seen almost nothing.
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 2048 /dev/zero > steamapps/workshop/downloads/431960/123456/movie.mp4
      touch ../allocated
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 0
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("allocated").path) }
      try await waitUntil { downloader.progress == 0 }
      XCTAssertEqual(downloader.bytesReceived, 0)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      monitor.received = 512
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 512)
      monitor.received = 1536
      try await waitUntil { downloader.progress == 0.75 }
      XCTAssertEqual(downloader.bytesReceived, 1536)
      // Traffic beyond what landed on disk (retries, Steam's own chatter) never runs ahead of it.
      monitor.received = 4096
      try await waitUntil { downloader.progress == 0.99 }
      XCTAssertEqual(downloader.bytesReceived, 2048)
      // A meter that stops reporting leaves the tree as the only measure.
      monitor.received = nil
      try await waitUntil { downloader.bytesReceived == 2048 && downloader.progress == 0.99 }
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
    } catch { await downloader.shutdown(); throw error }
  }

  func testWorkshopDiskGrowthWithoutListedSizeStaysIndeterminate() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 512 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
      touch ../first-written
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("first-written").path) }
      try await Task.sleep(for: .milliseconds(1200))
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testAppUpdateProgressParsesBytes() async throws {
    let root = try makeRuntime(
      """
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("The incomplete install must not publish assets")
    }
    do {
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 250)
      XCTAssertEqual(downloader.bytesExpected, 1000)
      await downloader.shutdown()
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testGuardFailureAfterMobileApprovalStopsWithoutRequestingAnotherCode() async throws {
    let root = try makeRuntime(
      """
      printf 'Please confirm the login in the Steam Mobile app on your phone.\\n'
      sleep 0.5
      printf 'FAILED (Account logon denied, need two-factor code)\\n'
      IFS= read -r unexpected
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.prompt)
      XCTAssertTrue(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testFailureWrittenImmediatelyBeforeExitIsNotLost() async throws {
    let root = try makeRuntime(
      """
      printf 'Logging in user to Steam Public...FAILED (Timeout)'
      exit 0
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path),
        "Login failure must stop before starting the importer")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testDeniedMobileApprovalCanRestartWithFreshCredentials() async throws {
    let root = try makeRuntime(
      """
      printf 'password: '
      IFS= read -r password
      printf '\\nPlease confirm the login in the Steam Mobile app on your phone.\\n'
      if [ ! -f ../approve-next-login ]; then
          printf 'FAILED (Access Denied)\\n'
          exit 1
      fi
      [ "$password" = 'fresh-password' ] || exit 10
      printf 'Two-factor code: '
      IFS= read -r code
      [ "$code" = 'NEW42' ] || exit 11
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'retried-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("first-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertTrue(downloader.canRetryAuthentication)
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
          $0.hasPrefix(".mac-wallpaper-engine-workshop-")
        })

      try Data().write(to: root.appendingPathComponent("approve-next-login"))
      downloader.start(
        item: item, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), onImported: {})
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.errorMessage)
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fresh-password")
      try await waitUntil { downloader.prompt == .guardCode }
      XCTAssertEqual(downloader.steamGuardChallenge, .authenticatorCode)
      downloader.submitSecret("NEW42")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.steamGuardChallenge)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "retried-content")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testWorkshopAccessDenialDoesNotOfferAuthenticationRetry() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      printf 'ERROR! Download item 123456 failed (Access Denied).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testSceneAssetsInstallUsesWindowsAppAndKeepsOnlyValidatedAssets() async throws {
    let root = try makeRuntime(
      """
      platform=''
      install=''
      app=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +@sSteamCmdForcePlatformType) shift; platform="$1" ;;
              +force_install_dir) shift; install="$1" ;;
              +app_update) shift; app="$1" ;;
          esac
          shift
      done
      [ "$platform" = windows ] && [ "$app" = 431960 ] && [ -n "$install" ] || exit 12
      printf 'password: '
      IFS= read -r password
      [ "$password" = 'local-password' ] || exit 13
      printf '\\nWaiting for user info...OK\\n'
      mkdir -p "$install/assets/shaders" "$install/assets/materials/util" config
      printf 'vertex-content' > "$install/assets/shaders/genericimage2.vert"
      printf 'fragment-content' > "$install/assets/shaders/genericimage2.frag"
      printf '{"passes":[{"shader":"genericimage2"}]}' > "$install/assets/materials/util/effectpassthrough.json"
      printf 'windows-executable' > "$install/wallpaper64.exe"
      printf 'temporary-login' > config/loginusers.vdf
      printf "Success! App '431960' fully installed.\\n"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("previous-incomplete-install".utf8).write(
      to: destination.appendingPathComponent("old"))
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination, onInstalled: {})
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("local-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertTrue(ClientPaths.hasSceneAssets(at: destination))
      XCTAssertEqual(
        try String(
          contentsOf: destination.appendingPathComponent("shaders/genericimage2.vert"),
          encoding: .utf8), "vertex-content")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
      try assertNoStaging(in: root)
      XCTAssertEqual(
        Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
        ["shaders", "materials"])
      XCTAssertNil(downloader.downloadedID, "Shared assets must not be reported as a Workshop item")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testIncompleteSceneAssetsNeverReplaceExistingInstallation() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\n'
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial-download' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf "Success! App '431960' fully installed.\\n"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: destination.appendingPathComponent("existing"))
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("An incomplete install must not become the renderer's configured assets")
    }
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(
        downloader.canRetryAuthentication, "Asset validation failure is not a sign-in failure")
      XCTAssertEqual(
        try String(contentsOf: destination.appendingPathComponent("existing"), encoding: .utf8),
        "preserved")
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: destination.path), ["existing"])
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testCancellingSceneAssetDownloadDoesNotPublishPartialResources() async throws {
    let root = try makeRuntime(
      """
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("Cancellation must not publish partial scene assets")
    }
    do {
      try await waitUntil { downloader.progress == 0.25 }
      await downloader.shutdown()
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testSavedSessionSurvivesRelaunchWithoutSubmittingSecrets() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = startDownload(in: root, username: "LocalTest")
    try await authenticate(first)
    try await assertImported(first, in: root, itemID: "123456")
    XCTAssertEqual(first.savedAccount?.lowercased(), "localtest")
    XCTAssertNil(first.sessionWarning)
    try assertPrivateSession(in: root)

    let second = startDownload(
      in: root, username: "LOCALTEST", itemID: "234567", libraryName: "OtherLibrary")
    try await assertImported(second, in: root, itemID: "234567", libraryName: "OtherLibrary")
    XCTAssertEqual(
      try String(
        contentsOf: root.appendingPathComponent("OtherLibrary/234567/movie.mp4"), encoding: .utf8),
      "cached:localtest:234567")
    try assertNoStaging(in: root)
  }

  func testSwitchingAccountsNeverRestoresPreviousAccountsCredentials() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = startDownload(in: root)
    try await authenticate(first)
    try await assertImported(first, in: root, itemID: "123456")

    let other = startDownload(in: root, username: "another_account", itemID: "234567")
    try await authenticate(other)
    try await assertImported(other, in: root, itemID: "234567")
    XCTAssertEqual(other.savedAccount, "another_account")
    let restored = startDownload(in: root, username: "another_account", itemID: "345678")
    try await assertImported(restored, in: root, itemID: "345678")

    let previous = startDownload(in: root, itemID: "456789")
    try await authenticate(previous)
    try await assertImported(previous, in: root, itemID: "456789")
  }

  func testInvalidCachedCredentialWarningAllowsPasswordFallback() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("fallback", in: root)

    let recovered = startDownload(in: root, itemID: "234567")
    try await authenticate(recovered)
    try await assertImported(recovered, in: root, itemID: "234567")
    XCTAssertFalse(recovered.canRetryAuthentication)
    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "345678")
    try await assertImported(next, in: root, itemID: "345678")
  }

  func testTerminalCachedCredentialRejectionRequiresExplicitFreshLogin() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("terminal", in: root)

    let rejected = startDownload(in: root, itemID: "234567")
    try await waitForStop(rejected)
    XCTAssertNotNil(rejected.errorMessage)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertNil(rejected.savedAccount)
    XCTAssertNil(rejected.downloadedID)
    try assertNoStaging(in: root)

    // Leave terminal mode enabled: any stale cache would be rejected again.
    let retry = startDownload(in: root, itemID: "234567")
    try await authenticate(retry)
    try await assertImported(retry, in: root, itemID: "234567")
  }

  func testForgettingSavedAccountRemovesCredentialsAcrossRelaunch() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    initial.forgetSavedAccount()
    XCTAssertNil(initial.savedAccount)
    XCTAssertNil(initial.errorMessage)
    try assertNoSavedCredentials(in: root)

    let next = startDownload(in: root, itemID: "234567")
    XCTAssertNil(next.savedAccount)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testOptingOutClearsExistingSessionAndDoesNotSaveNewLogin() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")

    let optedOut = startDownload(in: root, itemID: "234567", rememberSession: false)
    try await authenticate(optedOut)
    try await assertImported(optedOut, in: root, itemID: "234567")
    XCTAssertNil(optedOut.savedAccount)
    try assertNoSavedCredentials(in: root)

    let next = startDownload(in: root, itemID: "345678")
    XCTAssertNil(next.savedAccount)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "345678")
  }

  func testRejectedLoginDoesNotPersistCredentialsWrittenBeforeAuthentication() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("reject", in: root)
    let rejected = startDownload(in: root)
    try await authenticate(rejected)
    try await waitForStop(rejected)
    XCTAssertNotNil(rejected.errorMessage)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertNil(rejected.savedAccount)
    try assertNoSavedCredentials(in: root)
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "123456")
  }

  func testDownloadAccessFailurePreservesSuccessfullyAuthenticatedSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("access", in: root)
    let denied = startDownload(in: root)
    try await authenticate(denied)
    try await waitForStop(denied)
    XCTAssertNotNil(denied.errorMessage)
    XCTAssertFalse(denied.canRetryAuthentication)
    XCTAssertEqual(denied.savedAccount, "localtest")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "234567")
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testAuthenticatedCancellationRetainsSessionButRemovesPartialWallpaper() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("cancel", in: root)
    let cancelled = startDownload(in: root)
    try await authenticate(cancelled)
    do {
      try await waitUntil { cancelled.status == "Downloading Workshop files…" }
      XCTAssertNil(cancelled.progress)
      await cancelled.shutdown()
    } catch {
      await cancelled.shutdown()
      throw error
    }
    XCTAssertNil(cancelled.downloadedID)
    XCTAssertTrue(cancelled.wasCancelled)
    XCTAssertEqual(cancelled.savedAccount, "localtest")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "234567")
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testFailedAccountSwitchPreservesPreviousAccountSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("reject", in: root)
    let rejected = startDownload(in: root, username: "another_account", itemID: "234567")
    try await authenticate(rejected)
    try await waitForStop(rejected)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertEqual(rejected.savedAccount, "localtest")
    try setSessionMode("normal", in: root)
    let previous = startDownload(in: root, itemID: "345678")
    try await assertImported(previous, in: root, itemID: "345678")
  }

  func testSavedCredentialSymlinkCannotReadOutsidePrivateCache() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    let files = FileManager.default
    let original = root.appendingPathComponent("SteamSession/config/config.vdf")
    let outside = root.appendingPathComponent("outside-credential")
    try files.moveItem(at: original, to: outside)
    try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: outside.path)
    try files.createSymbolicLink(at: original, withDestinationURL: outside)
    let blocked = startDownload(in: root, itemID: "234567")
    try await waitForStop(blocked)
    XCTAssertNotNil(blocked.errorMessage)
    XCTAssertNil(blocked.downloadedID)
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "token:localtest")
    XCTAssertEqual(
      (try files.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue,
      0o640)
    try assertNoStaging(in: root)
  }

  func testRestartRejectsRuntimeRemovedByPreviousProcess() async throws {
    let root = try makeRuntime("rm steamcmd; exit 42")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertNil(downloader.downloadedID)
    XCTAssertFalse(downloader.wasCancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)
  }

  func testSerialDownloadsKeepPromptsCancellationAndQueueIndependent() async throws {
    let root = try makeRuntime(
      """
      set -eu
      item=''
      while [ "$#" -gt 0 ]; do
          if [ "$1" = +workshop_download_item ]; then shift; shift; item="$1"; fi
          shift
      done
      printf 'password: '
      IFS= read -r password
      [ "$password" = "secret$item" ] || exit 10
      printf '\\nWaiting for user info...OK\\nDownloading item %s ... (25%%)\\n' "$item"
      touch "../running-$item"
      while [ ! -f "../release-$item" ]; do sleep 0.02; done
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'content-%s' "$item" > "$content/movie.mp4"
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    func enqueue(_ id: String) throws -> WorkshopDownload {
      let requested = WorkshopItem(
        id: id, title: "Queued \(id)", creator: "Test", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), rememberSession: false
      ) {
        imported.insert(id)
      }
      return try XCTUnwrap(manager.download(for: id))
    }
    do {
      let first = try enqueue("1")
      let second = try enqueue("2")
      let third = try enqueue("3")
      let fourth = try enqueue("4")
      let fifth = try enqueue("5")
      XCTAssertTrue(
        try enqueue("1") === first, "A repeated click must not create a second transfer")
      try await waitUntil { first.worker.prompt == .password }
      XCTAssertTrue(second.isQueued)
      XCTAssertTrue(third.isQueued)
      XCTAssertTrue(fourth.isQueued)
      XCTAssertTrue(fifth.isQueued)
      first.worker.submitSecret("secret1")
      try await waitUntil { first.worker.status == "Downloading Workshop files…" }
      XCTAssertNil(first.progress)
      XCTAssertNil(second.worker.prompt)
      XCTAssertNil(third.worker.prompt)
      manager.cancel(second)
      XCTAssertTrue(first.isPending)
      XCTAssertTrue(third.isQueued)
      XCTAssertTrue(fourth.isQueued)
      XCTAssertTrue(fifth.isQueued)
      manager.cancel(fifth)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { third.worker.prompt == .password }
      XCTAssertNil(fourth.worker.prompt)
      third.worker.submitSecret("secret3")
      try await waitUntil { third.worker.status == "Downloading Workshop files…" }
      XCTAssertNil(third.progress)
      try Data().write(to: root.appendingPathComponent("release-3"))
      try await waitUntil { fourth.worker.prompt == .password }
      fourth.worker.submitSecret("secret4")
      try await waitUntil { fourth.worker.status == "Downloading Workshop files…" }
      XCTAssertNil(fourth.progress)
      try Data().write(to: root.appendingPathComponent("release-4"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "3", "4"])
      for id in imported {
        XCTAssertEqual(
          try String(
            contentsOf: root.appendingPathComponent("Library/\(id)/movie.mp4"), encoding: .utf8),
          "content-\(id)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/2").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("running-5").path))
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testQueuedDownloadReusesSignInSavedByPreviousJob() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    for id in ["123456", "234567"] {
      let requested = WorkshopItem(
        id: id, title: id, creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0,
        subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), onImported: {})
    }
    do {
      let first = try XCTUnwrap(manager.download(for: "123456"))
      let second = try XCTUnwrap(manager.download(for: "234567"))
      try await authenticate(first.worker)
      try await waitUntil { !manager.isRunning || second.worker.prompt != nil }
      XCTAssertNil(
        second.worker.prompt, "Queued work must restore the sign-in saved by the completed job")
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/234567/movie.mp4"), encoding: .utf8),
        "cached:localtest:234567")
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// A batch signs in once. Siblings wait through the prompt, start silently from the sign-in
  /// saved the moment Steam accepts it, and fill the slots; the rest wait for a free slot.
  func testAcceptedSignInLetsSiblingsRunSideBySideUpToTheSlotLimit() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 2)
    var imported = Set<String>()
    let jobs = try ["1", "2", "3", "4"].map { id in
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      try await waitUntil { jobs[0].worker.prompt == .password }
      XCTAssertEqual(manager.activeCount, 1)
      XCTAssertTrue(jobs[1...].allSatisfy(\.isQueued), "Prompts must not pile up")
      XCTAssertEqual(jobs[1].hold, .signIn)
      jobs[0].worker.submitSecret("local-password")
      try await waitUntil { started("1") && started("2") }
      XCTAssertEqual(manager.activeCount, 2)
      XCTAssertNil(jobs[1].worker.prompt, "A sibling restores the accepted sign-in silently")
      XCTAssertTrue(jobs[2].isQueued)
      XCTAssertEqual(jobs[2].hold, .slot)
      XCTAssertTrue(jobs[3].isQueued)
      XCTAssertFalse(started("3"))
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { started("3") }
      XCTAssertEqual(manager.activeCount, 2)
      XCTAssertTrue(jobs[3].isQueued)
      XCTAssertFalse(started("4"))
      for id in ["2", "3"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
      try await waitUntil { started("4") }
      try Data().write(to: root.appendingPathComponent("release-4"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2", "3", "4"])
      for id in imported {
        XCTAssertEqual(
          try String(
            contentsOf: root.appendingPathComponent("Library/\(id)/movie.mp4"), encoding: .utf8),
          "content-\(id)")
      }
      XCTAssertEqual(manager.savedAccount, "localtest")
      XCTAssertFalse(manager.sessionConflictDetected)
      try assertNoStaging(in: root)
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// With a sign-in already saved, a batch does not wait for its first job to get through
  /// Steam's login: every job restores the saved sign-in itself and they start together.
  func testSavedSignInStartsAWholeBatchAtOnceWithoutWaitingForTheFirstLogin() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    func enqueue(_ id: String) throws -> WorkshopDownload {
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      let first = try enqueue("1")
      try await authenticate(first.worker, guardCode: false)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(manager.savedAccount, "localtest")

      let batch = try ["2", "3", "4"].map(enqueue)
      try await waitUntil { started("2") && started("3") && started("4") }
      XCTAssertEqual(manager.activeCount, 3, "Nothing waits behind the first job's login")
      XCTAssertTrue(batch.allSatisfy { $0.worker.prompt == nil })
      for id in ["2", "3", "4"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2", "3", "4"])
      try assertNoStaging(in: root)
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// Steam ending a session for another of our own sign-ins means the account cannot run two
  /// at once: the ended job goes back in line behind the running one and the queue turns serial.
  func testSessionConflictSerialisesTheQueueAndRetriesTheEndedJob() async throws {
    let root = try makeParallelRuntime(
      conflict: """
        if [ -f ../running-1 ] && [ "$item" = 2 ] && [ ! -f ../conflicted ]; then
            touch ../conflicted
            printf 'FAILED (Logged in elsewhere)\\n'
            exit 1
        fi
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    let jobs = try ["1", "2"].map { id in
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      try await authenticate(jobs[0].worker, guardCode: false)
      try await waitUntil {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("conflicted").path)
          && jobs[1].isQueued
      }
      XCTAssertTrue(jobs[1].worker.endedBySessionConflict)
      XCTAssertTrue(manager.sessionConflictDetected)
      XCTAssertEqual(manager.slotLimit, 1)
      XCTAssertTrue(jobs[1].isPending)
      XCTAssertNil(jobs[1].errorMessage, "A job back in line for a retry is not a failure")
      XCTAssertFalse(jobs[1].isCancelled)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertFalse(started("2"), "The retry waits for the running session to end")
      XCTAssertEqual(manager.activeCount, 1)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { started("2") }
      try Data().write(to: root.appendingPathComponent("release-2"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2"])
      XCTAssertNil(jobs[1].errorMessage)
      XCTAssertNil(jobs[1].worker.errorMessage)
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testFailedDownloadReleasesSlotAndShutdownNeverLaunchesQueuedWork() async throws {
    let root = try makeRuntime(
      """
      set -eu
      item=''
      while [ "$#" -gt 0 ]; do
          if [ "$1" = +workshop_download_item ]; then shift; shift; item="$1"; fi
          shift
      done
      touch "../launched-$item"
      if [ "$item" = 1 ]; then printf 'FAILED (Invalid Password)\\n'; exit 1; fi
      printf 'password: '
      IFS= read -r password
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    for id in ["1", "2", "3"] {
      let requested = WorkshopItem(
        id: id, title: id, creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0,
        subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    }
    do {
      try await waitUntil { manager.download(for: "2")?.worker.prompt == .password }
      XCTAssertTrue(manager.download(for: "1")?.worker.canRetryAuthentication == true)
      XCTAssertTrue(manager.download(for: "3")?.isQueued == true)
      await manager.shutdown()
      XCTAssertFalse(manager.isRunning)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("launched-3").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testPendingDownloadsPreventSessionPreferenceChanges() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: item.id)
    try setSessionMode("cancel", in: root)
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    manager.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("OtherLibrary"), onImported: {})
    do {
      try await waitUntil { manager.download(for: item.id)?.worker.status == "Downloading Workshop files…" }
      XCTAssertNil(manager.download(for: item.id)?.progress)
      manager.forgetSavedAccount()
      XCTAssertNotNil(manager.errorMessage)
      XCTAssertEqual(manager.savedAccount, "localtest")
      let other = WorkshopItem(
        id: "234567", title: "Opt out", creator: "Test", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      manager.start(
        item: other, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("OtherLibrary"), rememberSession: false, onImported: {}
      )
      XCTAssertNil(manager.download(for: other.id))
      await manager.shutdown()
      try assertPrivateSession(in: root)
      manager.forgetSavedAccount()
      XCTAssertNil(manager.savedAccount)
      try assertNoSavedCredentials(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testLateCachedCredentialRejectionCannotEraseNewerSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    let rejectingRuntime = try makeRuntime(
      """
      [ -f config/config.vdf ] || exit 10
      printf 'Logging in using cached credentials\\n'
      touch ../old-session-restored
      while [ ! -f ../reject-old-session ]; do sleep 0.02; done
      printf 'FAILED (Invalid cached credentials)\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: rejectingRuntime) }
    let rejected = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    rejected.start(
      item: item, username: "localtest",
      executable: rejectingRuntime.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("OtherLibrary"), onImported: {})
    do {
      try await waitUntil {
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("old-session-restored").path)
      }
      let renewed = startDownload(in: root, itemID: "234567")
      try await assertImported(renewed, in: root, itemID: "234567")
      try Data().write(to: root.appendingPathComponent("reject-old-session"))
      try await waitForStop(rejected)
      XCTAssertTrue(rejected.canRetryAuthentication)
      XCTAssertEqual(rejected.savedAccount, "localtest")
      let next = startDownload(in: root, itemID: "345678")
      try await assertImported(next, in: root, itemID: "345678")
    } catch {
      await rejected.shutdown()
      throw error
    }
  }

  func testUnconfirmedWorkshopContentIsNotPublished() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'partial-content' > steamapps/workshop/content/431960/123456/movie.mp4
      exit 0
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertNil(downloader.downloadedID)
    XCTAssertFalse(downloader.wasCancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)
  }

  func testDefaultRuntimeRejectsShellWithoutExecutingOrChangingIt() throws {
    let root = try makeRuntime("printf unexpected > ../executed")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("runtime/steamcmd")
    let original = try Data(contentsOf: executable)
    XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable))
    XCTAssertEqual(try Data(contentsOf: executable), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
  }

  func testMalformedMachOLoadCommandsAreRejectedWithoutModifyingSource() throws {
    let root = try makeRuntime("exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("runtime/steamcmd")
    // A 64-bit executable declares a load-command table that exceeds the actual file.
    var malformed = Data()
    for word in [UInt32(0xfeed_facf), 0x0100_0007, 3, 2, 1, 4096, 0, 0] {
      var littleEndian = word.littleEndian
      withUnsafeBytes(of: &littleEndian) { malformed.append(contentsOf: $0) }
    }
    try malformed.write(to: executable)
    XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable)) { error in
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(try Data(contentsOf: executable), malformed)
  }

    func testFatBinaryRepeatingOneCPUTypeIsRejectedWithoutModifyingSource() throws {
        let root = try makeRuntime("exit 0")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("runtime/steamcmd")
        // Two x86_64 slices differing only by subtype: a CPU-keyed selection resolves one and
        // would leave the other unvalidated and unverified by codesign --arch.
        let slice = fixtureMachO(fileType: 2)
        var fat = Data()
        func append(_ values: [UInt32]) {
            for value in values {
                var bigEndian = value.bigEndian
                withUnsafeBytes(of: &bigEndian) { fat.append(contentsOf: $0) }
            }
        }
        let first = 4096, second = 8192
        append([0xcafebabe, 2])
        append([0x01000007, 3, UInt32(first), UInt32(slice.count), 12])
        append([0x01000007, 8, UInt32(second), UInt32(slice.count), 12])
        fat.append(Data(repeating: 0, count: first - fat.count))
        fat.append(slice)
        fat.append(Data(repeating: 0, count: second - fat.count))
        fat.append(slice)
        try fat.write(to: executable)
        XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable)) { error in
            XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
        }
        XCTAssertEqual(try Data(contentsOf: executable), fat)
    }

  func testDefaultProviderPreservesContainedFrameworkLinksAcrossPrivateVarAliases() async throws {
    let files = FileManager.default
    let directory = try makeMachOFrameworkRuntime()
    defer { try? files.removeItem(at: directory) }
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
    let aliasPath =
      root.path.hasPrefix("/private/var/")
      ? String(root.path.dropFirst("/private".count)) : root.path
    let privatePath = aliasPath.hasPrefix("/var/") ? "/private" + aliasPath : aliasPath
    let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
    let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
    let physical = URL(fileURLWithPath: privatePath, isDirectory: true)
    try await service.validateBootstrap(at: physical)
    try await service.validate(at: alias)
    XCTAssertEqual(
      try service.resolve(executable: alias.appendingPathComponent("steamcmd")),
      try service.resolve(executable: physical.appendingPathComponent("steamcmd")))
    let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
    let prepared = try await service.prepare(
      executable: physical.appendingPathComponent("steamcmd"), staging: staging)
    XCTAssertEqual(
      try Data(contentsOf: prepared), try Data(contentsOf: root.appendingPathComponent("steamcmd")))
    XCTAssertEqual(
      try files.destinationOfSymbolicLink(
        atPath: staging.appendingPathComponent("Frameworks/Breakpad.framework/Resources").path),
      "Versions/Current/Resources")
    XCTAssertEqual(
      try String(
        contentsOf: staging.appendingPathComponent(
          "Frameworks/Breakpad.framework/Resources/Info.txt"), encoding: .utf8),
      "sealed-resource-fixture")

    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    try files.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("preserved".utf8).write(to: outside.appendingPathComponent("sentinel"))
    try files.removeItem(at: framework.appendingPathComponent("Resources"))
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Resources").path,
      withDestinationPath: "../../../outside")
    do {
      try await service.validate(at: physical)
      XCTFail("A framework link escaping its container must be rejected")
    } catch {
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(
      try String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8),
      "preserved")
  }

  func testNestedHelperRetainsExecutableContextThroughDylibAndRPathChains() async throws {
    let files = FileManager.default
    let directory = try makeMachOFrameworkRuntime()
    defer { try? files.removeItem(at: directory) }
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let version = root.appendingPathComponent(
      "Frameworks/Breakpad.framework/Versions/A", isDirectory: true)
    let helper = version.appendingPathComponent("Helpers/report_sender")
    try files.createDirectory(
      at: helper.deletingLastPathComponent(), withIntermediateDirectories: false)
    let images = [
      (
        helper,
        fixtureMachO(
          fileType: 2, dependency: "@executable_path/../Resources/breakpadUtilities.dylib",
          rpaths: ["@executable_path/../Resources"])
      ),
      (
        version.appendingPathComponent("Resources/breakpadUtilities.dylib"),
        fixtureMachO(fileType: 6, dependency: "@rpath/helperSupport.dylib")
      ),
      (
        version.appendingPathComponent("Resources/helperSupport.dylib"),
        fixtureMachO(fileType: 6, dependency: "@executable_path/../Resources/last.dylib")
      ),
      (version.appendingPathComponent("Resources/last.dylib"), fixtureMachO(fileType: 6)),
    ]
    for (url, contents) in images { try contents.write(to: url) }
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
    let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
    _ = try await service.prepare(
      executable: root.appendingPathComponent("steamcmd"), staging: staging)
    for (url, contents) in images {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent(relative)), contents)
    }

    let outside = directory.appendingPathComponent("outside.dylib")
    let sentinel = fixtureMachO(fileType: 6)
    try sentinel.write(to: outside)
    try fixtureMachO(fileType: 6, dependency: "@executable_path/../../../../../../outside.dylib")
      .write(to: version.appendingPathComponent("Resources/last.dylib"))
    do {
      try await service.validate(at: root)
      XCTFail("Nested executable context must not permit escaping the runtime")
    } catch {
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(try Data(contentsOf: outside), sentinel)
  }

  private func makeMachOFrameworkRuntime() throws -> URL {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(
      "mwe-framework-links-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
    let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
    try files.createDirectory(
      at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try Data("sealed-resource-fixture".utf8).write(
      to: version.appendingPathComponent("Resources/Info.txt"))
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Resources").path,
      withDestinationPath: "Versions/Current/Resources")
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Breakpad").path,
      withDestinationPath: "Versions/Current/Breakpad")
    for (path, contents) in [
      (root.appendingPathComponent("steamcmd"), fixtureMachO(fileType: 2)),
      (
        root.appendingPathComponent("steamconsole.dylib"),
        fixtureMachO(fileType: 6, dependency: "@loader_path/crashhandler.dylib")
      ),
      (
        root.appendingPathComponent("crashhandler.dylib"),
        fixtureMachO(fileType: 6, dependency: "@loader_path/Breakpad.framework/Versions/A/Breakpad")
      ),
      (version.appendingPathComponent("Breakpad"), fixtureMachO(fileType: 6)),
    ] {
      try contents.write(to: path)
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appendingPathComponent("steamcmd.sh"))
    return directory
  }

  private func fixtureMachO(fileType: UInt32, dependency: String? = nil, rpaths: [String] = [])
    -> Data
  {
    func words(_ values: [UInt32]) -> Data {
      var result = Data()
      for value in values {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
      }
      return result
    }
    var commands = Data()
    let entries = dependency.map { [(UInt32(0xc), $0)] } ?? []
    for (command, path) in entries + rpaths.map({ (UInt32(0x8000_001c), $0) }) {
      let name = Data((path + "\0").utf8)
      let header = command == 0xc ? 24 : 12
      let length = (header + name.count + 3) & ~3
      commands.append(words([command, UInt32(length), UInt32(header)]))
      if command == 0xc { commands.append(words([0, 0, 0])) }
      commands.append(name)
      commands.append(Data(repeating: 0, count: length - header - name.count))
    }
    return words([
      0xfeed_facf, 0x0100_0007, 3, fileType, UInt32(entries.count + rpaths.count),
      UInt32(commands.count), 0, 0,
    ]) + commands
  }

  func testShutdownWaitsForOwnedDescendantsBeforeRemovingStaging() async throws {
    let root = try makeRuntime(
      """
      (trap '' TERM; sleep 3; printf late > ../late-write) &
      printf 'password: '
      IFS= read -r password
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      await downloader.shutdown()
      XCTAssertTrue(downloader.wasCancelled)
      try assertNoStaging(in: root)
      try await Task.sleep(for: .milliseconds(1300))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }
  private func makeSessionRuntime() throws -> URL {
    try makeRuntime(
      """
      set -eu
      account=''
      install=''
      item=''
      for argument in "$@"; do
          case "$argument" in
              *local-password*|*12345-secret*) exit 80 ;;
          esac
      done
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +login) shift; account="$1" ;;
              +force_install_dir) shift; install="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      [ -n "$account" ] && [ -n "$install" ] && [ -n "$item" ] || exit 81
      account=$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')
      registry="$HOME/Library/Application Support/Steam/registry.vdf"
      homeconfig="$HOME/Library/Application Support/Steam/config/config.vdf"
      mode=normal
      if [ -f ../session-mode ]; then mode=$(cat ../session-mode); fi
      source=fresh
      if [ -f config/config.vdf ] || [ -f "$registry" ] || [ -f "$homeconfig" ] || [ -f ssfn123456 ]; then
          [ "$(cat config/config.vdf)" = "token:$account" ] || exit 82
          [ "$(cat "$registry")" = "registry:$account" ] || exit 83
          [ "$(cat ssfn123456)" = "machine-token" ] || exit 84
          [ "$(cat "$homeconfig")" = "home-token:$account" ] || exit 87
          source=cached
          if [ "$mode" = terminal ]; then
              printf 'FAILED (Invalid cached credentials)\\n'
              exit 1
          fi
          if [ "$mode" = fallback ]; then
              printf 'Warning (invalid cached credentials)\\n'
              source=fresh
          fi
      fi
      if [ "$source" = fresh ]; then
          printf 'password: '
          IFS= read -r password
          [ "$password" = local-password ] || exit 85
          printf '\\nSteam Guard code: '
          IFS= read -r code
          [ "$code" = 12345-secret ] || exit 86
          mkdir -p config "$(dirname "$registry")" "$(dirname "$homeconfig")"
          printf 'token:%s' "$account" > config/config.vdf
          printf 'registry:%s' "$account" > "$registry"
          printf 'home-token:%s' "$account" > "$homeconfig"
          printf 'machine-token' > ssfn123456
          printf '%s:%s' "$password" "$code" > config/console.log
          printf '%s' "$password" > submitted-password.txt
          chmod 644 config/config.vdf "$registry" "$homeconfig" ssfn123456
      fi
      if [ "$mode" = reject ]; then
          printf '\\nFAILED (Invalid Password)\\n'
          exit 1
      fi
      printf '\\nWaiting for user info...OK\\n'
      if [ "$mode" = access ]; then
          printf 'Downloading item %s ...\\nERROR! Download item %s failed (Access Denied).\\n' "$item" "$item"
          exit 1
      fi
      content="$install/steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf '%s:%s:%s' "$source" "$account" "$item" > "$content/movie.mp4"
      if [ "$mode" = cancel ]; then
          printf 'Downloading item %s ... (25%%)\\n' "$item"
          IFS= read -r finish
          exit 0
      fi
      printf 'Downloading item %s ...\\nSuccess. Downloaded item %s\\n' "$item" "$item"
      """)
  }

  /// Like the session runtime, but every transfer blocks until `release-<item>` appears next to
  /// the staging directories, so the test observes which sessions run side by side.
  private func makeParallelRuntime(conflict: String = "") throws -> URL {
    try makeRuntime(
      """
      set -eu
      account=''
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +login) shift; account="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      [ -n "$account" ] && [ -n "$item" ] || exit 81
      if [ -f config/config.vdf ]; then
          [ "$(cat config/config.vdf)" = "token:$account" ] || exit 82
          printf 'Logging in using cached credentials\\n'
      else
          printf 'password: '
          IFS= read -r password
          [ "$password" = local-password ] || exit 85
          mkdir -p config
          printf 'token:%s' "$account" > config/config.vdf
          chmod 644 config/config.vdf
      fi
      \(conflict)
      printf '\\nWaiting for user info...OK\\nDownloading item %s ... (25%%)\\n' "$item"
      touch "../running-$item"
      while [ ! -f "../release-$item" ]; do sleep 0.02; done
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'content-%s' "$item" > "$content/movie.mp4"
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
  }

  private func setSessionMode(_ mode: String, in root: URL) throws {
    try Data(mode.utf8).write(to: root.appendingPathComponent("session-mode"))
  }

  private func authenticate(_ downloader: WorkshopDownloader, guardCode: Bool = true) async throws {
    do {
      try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
      guard downloader.prompt == .password else {
        throw WorkshopFailure(
          message: "Expected a fresh password prompt: \(downloader.errorMessage ?? "session ended")"
        )
      }
      downloader.submitSecret("local-password")
      guard guardCode else { return }
      try await waitUntil { downloader.prompt == .guardCode || !downloader.isRunning }
      guard downloader.prompt == .guardCode else {
        throw WorkshopFailure(
          message: "Expected a Steam Guard prompt: \(downloader.errorMessage ?? "session ended")")
      }
      downloader.submitSecret("12345-secret")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  private func waitForStop(_ downloader: WorkshopDownloader) async throws {
    do {
      try await waitUntil { !downloader.isRunning }
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  private func assertImported(
    _ downloader: WorkshopDownloader, in root: URL, itemID: String, libraryName: String = "Library",
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try await waitForStop(downloader)
    XCTAssertNil(downloader.errorMessage, file: file, line: line)
    XCTAssertEqual(downloader.downloadedID, itemID, file: file, line: line)
    let movie = root.appendingPathComponent("\(libraryName)/\(itemID)/movie.mp4")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: movie.path),
      "The newly requested wallpaper must actually be imported", file: file, line: line)
  }

  private func assertNoStaging(in root: URL, file: StaticString = #filePath, line: UInt = #line)
    throws
  {
    let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(
      children.contains { $0.hasPrefix(".mac-wallpaper-engine-workshop-") }, file: file, line: line)
  }

  private func sessionEntries(in root: URL) throws -> [URL] {
    let session = root.appendingPathComponent("SteamSession")
    guard FileManager.default.fileExists(atPath: session.path) else { return [] }
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: session, includingPropertiesForKeys: [.isRegularFileKey]))
    return [session] + enumerator.compactMap { $0 as? URL }
  }

  private func assertNoSavedCredentials(
    in root: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    for url in try sessionEntries(in: root)
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let contents = try Data(contentsOf: url)
      for marker in ["token:", "registry:", "machine-token", "local-password", "12345-secret"] {
        XCTAssertNil(
          contents.range(of: Data(marker.utf8)),
          "Forgotten credentials remain in \(url.lastPathComponent)", file: file, line: line)
      }
    }
  }

  private func assertPrivateSession(
    in root: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let entries = try sessionEntries(in: root)
    for url in entries {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
      XCTAssertEqual(
        permissions & 0o077, 0,
        "Steam credentials must be inaccessible to group and other users: \(url.path)", file: file,
        line: line)
      guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
      let contents = try Data(contentsOf: url)
      for forbidden in [
        "local-password", "12345-secret", "fresh:localtest:123456", "\"movie.mp4\"",
      ] {
        XCTAssertNil(
          contents.range(of: Data(forbidden.utf8)),
          "Session storage must not retain submitted secrets or wallpaper content", file: file,
          line: line)
      }
      XCTAssertNotEqual(url.lastPathComponent, "console.log", file: file, line: line)
    }
  }

  func testNetworkReceiveMeterUsesOnlyFreshPIDScopedDeltaBytes() {
    var meter = NetworkReceiveMeter(processID: 42)
    func row(_ bytes: Int64) -> Data { Data(",bytes_in,\nsteamcmd.42,\(bytes),\n".utf8) }
    meter.append(row(9_000_000), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data(",bytes_in,\nsteamcmd.42,60".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("0000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 600_000)
    meter.append(row(300_000), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 450_000)
    meter.append(Data(",bytes_in,\nsteamcmd.142,999999999,\nsteamcmd.42,-1,\nsteamcmd.42,NaN,\n".utf8), at: 2.5)
    XCTAssertEqual(meter.rate(at: 2.5), 450_000)
    meter.append(row(0), at: 3)
    XCTAssertEqual(meter.rate(at: 3), 300_000)
    meter.append(row(0), at: 4)
    meter.append(row(0), at: 5)
    XCTAssertEqual(meter.rate(at: 5), 0)
    XCTAssertNil(meter.rate(at: 8.1))
    meter.append(row(50_000_000), at: 20)
    XCTAssertNil(meter.rate(at: 20))
    meter.append(row(150_000), at: 21.5)
    XCTAssertEqual(meter.rate(at: 21.5), 100_000)
    meter.append(row(900_000_000), at: 21.6)
    XCTAssertNil(meter.rate(at: 21.6))
    XCTAssertNil(meter.rate(at: .nan))
  }

  func testNetworkReceiveMeterAcceptsTerminalCRLFAndSplitLineEndings() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\r\nMacWallpaperEng.42,1,\r\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data(",bytes_in,\r\nMacWallpaperEng.42,1000,\r\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 1000)
    meter.append(Data(",bytes_in,\r".utf8), at: 2)
    meter.append(Data("\nMacWallpaperEng.42,2000,\r".utf8), at: 2)
    meter.append(Data("\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 1500)
    meter.append(Data("MacWallpaperEng.42,0,\r\n".utf8), at: 3)
    XCTAssertEqual(meter.rate(at: 3), 1000)
  }

  func testNetworkReceiveMeterHonoursHeaderColumnOrder() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_out,bytes_in,\nsteamcmd.42,111,600000,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data("steamcmd.42,222,300000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 300_000)
  }

  func testNetworkReceiveMeterRejectsUnscopedMalformedAndOverflowingRows() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data("steamcmd.42,600000,\nother.42,700000,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data(",bytes_in,\nsteamcmd.42,99999999999999999999,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0.4))
    meter.append(Data("steamcmd.42,600000,\n".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 300_000)
  }

  func testNetworkReceiveMeterDropsOversizedPartialInput() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\nsteamcmd.42,600000,\n".utf8), at: 0)
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 300_000)
    meter.append(Data(repeating: 0x61, count: 70_000), at: 2)
    XCTAssertNil(meter.rate(at: 2))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 3)
    XCTAssertNil(meter.rate(at: 3))
    meter.append(Data(",bytes_in,\nsteamcmd.42,600000,\n".utf8), at: 4)
    XCTAssertNil(meter.rate(at: 4))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 5)
    XCTAssertEqual(meter.rate(at: 5), 300_000)
  }

  func testNetworkReceiveMeterResetsOnBatchedSameTimestampSamples() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\nsteamcmd.42,1000,\nsteamcmd.42,900000000,\n".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 300_000)
  }

  func testNetworkReceiveMeterTotalsEveryRowAfterTheFirst() {
    var meter = NetworkReceiveMeter(processID: 42)
    func row(_ bytes: Int64) -> Data { Data(",bytes_in,\nsteamcmd.42,\(bytes),\n".utf8) }
    XCTAssertEqual(meter.bytesReceived, 0)
    // nettop's first row carries everything since the process launched: sign-in, not transfer.
    meter.append(row(9_000_000), at: 0)
    XCTAssertEqual(meter.bytesReceived, 0)
    meter.append(row(600_000), at: 1)
    XCTAssertEqual(meter.bytesReceived, 600_000)
    // Rows other processes, malformed numbers and negative values never count.
    meter.append(Data(",bytes_in,\nsteamcmd.142,999999,\nsteamcmd.42,-1,\nsteamcmd.42,NaN,\n".utf8), at: 1.5)
    XCTAssertEqual(meter.bytesReceived, 600_000)
    // A row outside the rate window or batched at one timestamp still carries real bytes.
    meter.append(row(50_000), at: 20)
    XCTAssertNil(meter.rate(at: 20))
    XCTAssertEqual(meter.bytesReceived, 650_000)
    meter.append(Data(",bytes_in,\nsteamcmd.42,1000,\nsteamcmd.42,2000,\n".utf8), at: 21)
    XCTAssertEqual(meter.bytesReceived, 653_000)
    // Runaway partial output resets the rate window but keeps the total.
    meter.append(Data(String(repeating: "x", count: 70_000).utf8), at: 22)
    XCTAssertEqual(meter.bytesReceived, 653_000)
    meter.append(row(4_000), at: 23)
    XCTAssertEqual(meter.bytesReceived, 657_000)
    XCTAssertNil(meter.rate(at: 23))
    meter.append(row(5_000), at: 24)
    XCTAssertEqual(meter.rate(at: 24), 5_000)
  }

  func testNetworkRateIsIndependentOfWorkshopSizeAndClearsOnCancellation() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ... (75%%)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 600_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertTrue(monitor.startedPIDs.isEmpty)
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 600_000 }
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertEqual(monitor.startedPIDs.count, 1)
      monitor.value = 0
      try await waitUntil { downloader.bytesPerSecond == 0 }
      monitor.value = nil
      try await waitUntil { downloader.bytesPerSecond == nil }
      monitor.value = 600_000
      try await waitUntil { downloader.bytesPerSecond == 600_000 }
      downloader.cancel()
      XCTAssertNil(downloader.bytesPerSecond)
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.stopCount, 1)
    } catch { await downloader.shutdown(); throw error }
  }

  func testCompletedDownloadClearsTransferTelemetry() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-content ]; do sleep 0.02; done
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'real-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 450_000
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: monitor)
    downloader.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false
    ) {
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.progress)
    }
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 450_000 }
      try Data().write(to: root.appendingPathComponent("release-content"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.stopCount, 1)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "real-content")
    } catch { await downloader.shutdown(); throw error }
  }

  func testFailedDownloadClearsTransferTelemetryAndStopsMonitor() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-failure ]; do sleep 0.02; done
      printf 'ERROR! Download item 123456 failed (Access Denied).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 300_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 300_000 }
      try Data().write(to: root.appendingPathComponent("release-failure"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.startedPIDs.count, 1)
      XCTAssertEqual(monitor.stopCount, 1)
    } catch { await downloader.shutdown(); throw error }
  }

  func testMonitorFailureDoesNotDisturbTransfer() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-download ]; do sleep 0.02; done
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'monitor-isolated-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FailingNetworkRunner()
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: ProcessNetworkMonitor(runner: runner))
    downloader.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { runner.invocation != nil }
      let invocation = try XCTUnwrap(runner.invocation)
      XCTAssertEqual(invocation.0.path, "/usr/bin/nettop")
      let arguments = invocation.1
      XCTAssertEqual(arguments.count, 12)
      let pid = try XCTUnwrap(arguments.count > 4 ? Int32(arguments[4]) : nil)
      XCTAssertGreaterThan(pid, 0)
      XCTAssertEqual(arguments, ["-P", "-L", "0", "-p", String(pid), "-n", "-x", "-d", "-s", "1", "-J", "bytes_in"])
      XCTAssertTrue(downloader.isRunning)
      XCTAssertNil(downloader.errorMessage)
      XCTAssertNil(downloader.bytesPerSecond)
      try Data().write(to: root.appendingPathComponent("release-download"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "monitor-isolated-content")
    } catch { await downloader.shutdown(); throw error }
  }

  func testRestartRestartsMonitorWithFreshProcessAndNoStaleRate() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      if [ -f ../second-pass ]; then
          touch ../second-launch
          IFS= read -r finish
      else
          touch ../first-launch
          while [ ! -f ../release-first ]; do sleep 0.02; done
          exit 42
      fi
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 500_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { monitor.startedPIDs.count == 1 }
      try await waitUntil { downloader.bytesPerSecond == 500_000 }
      monitor.value = nil
      try Data().write(to: root.appendingPathComponent("second-pass"))
      try Data().write(to: root.appendingPathComponent("release-first"))
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { monitor.startedPIDs.count == 2 }
      XCTAssertEqual(monitor.stopCount, 1)
      XCTAssertNotEqual(monitor.startedPIDs[0], monitor.startedPIDs[1])
      XCTAssertNil(downloader.bytesPerSecond)
      monitor.value = 700_000
      try await waitUntil { downloader.bytesPerSecond == 700_000 }
      await downloader.shutdown()
      XCTAssertTrue(downloader.wasCancelled)
      XCTAssertEqual(monitor.stopCount, 2)
    } catch { await downloader.shutdown(); throw error }
  }

  func testAppUpdatePhaseProgressTracksExplicitByteCountersOnly() async throws {
    let root = try makeRuntime("""
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      touch ../phase-one
      while [ ! -f ../next-phase ]; do sleep 0.02; done
      printf 'Update state (0x36) verifying, progress: 50.00 (500 / 1000)\\n'
      touch ../phase-two
      while [ ! -f ../final-phase ]; do sleep 0.02; done
      printf 'Update state (0x61) downloading, progress: 0.00 (0 / 0)\\n'
      touch ../phase-three
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 400_000
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: monitor)
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: root.appendingPathComponent("SceneAssets")
    ) { XCTFail("The incomplete install must not publish assets") }
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-one").path) }
      try await waitUntil { downloader.progress == 0.25 }
      try await waitUntil { downloader.bytesPerSecond == 400_000 }
      XCTAssertEqual(downloader.bytesReceived, 250)
      XCTAssertEqual(downloader.bytesExpected, 1000)
      try Data().write(to: root.appendingPathComponent("next-phase"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-two").path) }
      try await waitUntil { downloader.progress == 0.5 }
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      try await waitUntil { downloader.bytesPerSecond == nil }
      try Data().write(to: root.appendingPathComponent("final-phase"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-three").path) }
      try await waitUntil { downloader.progress == nil }
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testNetworkMonitorStreamsSamplesBeforeProcessExits() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    guard listener >= 0 else { return }
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    guard bound == 0 else { return }
    XCTAssertEqual(listen(listener, 1), 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let located = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    XCTAssertEqual(located, 0)
    guard located == 0 else { return }
    let client = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(client, 0)
    guard client >= 0 else { return }
    defer { close(client) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    XCTAssertEqual(connected, 0)
    guard connected == 0 else { return }
    let peer = accept(listener, nil, nil)
    XCTAssertGreaterThanOrEqual(peer, 0)
    guard peer >= 0 else { return }
    defer { close(peer) }
    var byte: UInt8 = 1
    XCTAssertEqual(send(client, &byte, 1, 0), 1)
    XCTAssertEqual(recv(peer, &byte, 1, 0), 1)
    let monitor = ProcessNetworkMonitor()
    monitor.start(processID: getpid())
    do {
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      while monitor.rate(at: ProcessInfo.processInfo.systemUptime) == nil,
            ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertNotNil(monitor.rate(at: ProcessInfo.processInfo.systemUptime), "nettop output must stream before its process exits")
      await monitor.stop()
      XCTAssertNil(monitor.rate(at: ProcessInfo.processInfo.systemUptime))
    } catch { await monitor.stop(); throw error }
  }

  private func makeRuntime(_ script: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mwe-terminal-tests-\(UUID().uuidString)")
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let executable = runtime.appendingPathComponent("steamcmd")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return root
  }

  private func startDownload(
    in root: URL, username: String = "localtest", itemID: String = "123456",
    libraryName: String = "Library", rememberSession: Bool = true, item: WorkshopItem? = nil,
    networkMonitor: (any ProcessNetworkMonitoring)? = nil
  ) -> WorkshopDownloader {
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: networkMonitor ?? FixtureNetworkMonitor())
    let requestedItem = item ?? WorkshopItem(
      id: itemID, title: "Session fixture", creator: "Test", summary: "", previewURL: nil,
      tags: ["Video"], size: 0, subscriptions: 0)
    downloader.start(
      item: requestedItem, username: username,
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent(libraryName), rememberSession: rememberSession,
      onImported: {})
    return downloader
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else {
        throw WorkshopFailure(message: "SteamCMD did not advance its interactive session")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// Replaces only Valve runtime verification; PTY, child lifecycle, session and importer remain real.
private struct ShellRuntimeProvider: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    let root = executable.deletingLastPathComponent()
    try check(root)
    return SteamCMDRuntime(rootURL: root, executableURL: root.appendingPathComponent("steamcmd"))
  }

  func prepare(executable: URL, staging: URL) async throws -> URL {
    try Task.checkCancellation()
    let runtime = try resolve(executable: executable)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let binary = staging.appendingPathComponent("steamcmd")
    try FileManager.default.copyItem(at: runtime.executableURL, to: binary)
    try check(staging)
    return binary
  }

  func validateBootstrap(at root: URL) async throws { try check(root) }
  func validate(at root: URL) async throws { try check(root) }

  private func check(_ root: URL) throws {
    try Task.checkCancellation()
    let executable = root.appendingPathComponent("steamcmd")
    let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isExecutableFile(atPath: executable.path),
      try String(contentsOf: executable, encoding: .utf8).hasPrefix("#!/bin/sh\n")
    else {
      throw WorkshopFailure(message: "The shell runtime fixture is missing or invalid")
    }
  }
}

/// The fixture exercises production filesystem/load-command validation, not Apple's trust policy.
private struct FixtureSystemAssessment: SteamCMDProcessRunning {
  func run(
    executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
    onOutput: @escaping @Sendable (Data) -> Void
  ) async throws -> Int32 {
    guard ["/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/arch"].contains(executable.path) else {
      throw WorkshopFailure(message: "The fixture must not execute a runtime program")
    }
    try Task.checkCancellation()
    return 0
  }
}

@MainActor
private final class FixtureNetworkMonitor: ProcessNetworkMonitoring {
  var value: Double?
  var received: Int64?
  var startedPIDs: [Int32] = []
  private(set) var stopCount = 0
  private var running = false

  func start(processID: Int32) {
    startedPIDs.append(processID)
    running = true
  }

  func rate(at time: TimeInterval) -> Double? { value }

  func bytesReceived() -> Int64? { received }

  func stop() async {
    if running { stopCount += 1 }
    running = false
  }
}

private final class FailingNetworkRunner: SteamCMDProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: (URL, [String])?

  var invocation: (URL, [String])? {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  private func record(_ executable: URL, _ arguments: [String]) {
    lock.lock()
    defer { lock.unlock() }
    captured = (executable, arguments)
  }

  func run(
    executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
    onOutput: @escaping @Sendable (Data) -> Void
  ) async throws -> Int32 {
    record(executable, arguments)
    throw WorkshopFailure(message: "fixture monitor failure")
  }
}
