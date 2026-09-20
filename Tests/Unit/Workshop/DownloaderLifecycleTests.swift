import Darwin
import XCTest

@testable import MacWallpaperEngine

/// Single-download lifecycle: staging, prompts, progress, scene assets and failure paths.
@MainActor
final class DownloaderLifecycleTests: DownloaderTestCase {
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

  func testPhaseFollowsEachSteamCMDStepBeforeAndAfterTheTransfer() async throws {
    let root = try makeRuntime(
      """
      printf 'Steam Console Client\\nUpdate state (0x5) verifying installation, progress: 1.00\\n'
      while [ ! -f ../release-login ]; do sleep 0.02; done
      printf 'Logging in using username/password.\\npassword: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\n'
      while [ ! -f ../release-download ]; do sleep 0.02; done
      printf 'Downloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"title":"Phase fixture","type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'downloaded-content' > steamapps/workshop/content/431960/123456/movie.mp4
      while [ ! -f ../release-finish ]; do sleep 0.02; done
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let release = { (name: String) in FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }
    let downloader = startDownload(in: root)
    do {
      // Before SteamCMD has reported anything the run is still being prepared or launched.
      XCTAssertTrue([.preparing, .connecting].contains(downloader.phase))
      try await waitUntil { downloader.phase == .updating }
      XCTAssertNil(downloader.progress, "Runtime updates carry no wallpaper progress")
      release("release-login")
      try await waitUntil { downloader.prompt == .password }
      XCTAssertEqual(downloader.phase, .signingIn)
      downloader.submitSecret("local-password")
      try await waitUntil { downloader.phase == .requesting }
      XCTAssertFalse(downloader.isAuthenticating)
      release("release-download")
      try await waitUntil { downloader.phase == .transferring }
      release("release-finish")
      try await waitUntil { downloader.phase == .finishing }
      XCTAssertEqual(downloader.progress, 1, "The last byte fills the ring while validation runs")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.phase, .finishing)
      XCTAssertEqual(downloader.downloadedID, item.id)
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
      try await waitUntil { downloader.status == String(localized: "Downloading Workshop files…") }
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
}
