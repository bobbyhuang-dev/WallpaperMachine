import XCTest
@testable import MacWallpaperEngine

@MainActor
final class DownloaderTests: XCTestCase {
    private let item = WorkshopItem(id: "123456", title: "Download lifecycle", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)

    func testAnonymousAccountCannotStartDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-invalid-account-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"))
        downloader.start(item: item, username: "anonymous", executable: root.appendingPathComponent("missing"), library: root.appendingPathComponent("Library"), onImported: {})
        XCTAssertFalse(downloader.isRunning)
        XCTAssertNotNil(downloader.errorMessage)
        XCTAssertNil(downloader.downloadedID)
    }

    func testImmediateShutdownWaitsForStagingCleanup() async throws {
        let root = try makeRuntime("IFS= read -r finish")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        downloader.start(item: item, username: "localcanceltest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("Library"), onImported: {})
        await downloader.shutdown()
        XCTAssertFalse(downloader.isRunning)
        XCTAssertTrue(downloader.wasCancelled)
        XCTAssertNil(downloader.downloadedID)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(children.contains { $0.hasPrefix(".mac-wallpaper-engine-workshop-") })
    }

    func testShortSplitPromptsAllowPasswordAndGuardCodeBeforeDownload() async throws {
        let root = try makeRuntime("""
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
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8), "downloaded-content")
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testMobileApprovalCanAdvanceToDownloadProgress() async throws {
        let root = try makeRuntime("""
            printf 'Please confirm the login in the Steam Mobile app on your phone.\\n'
            sleep 0.5
            printf 'Waiting for user info...OK\\nDownloading item 123456 ... (25%%)\\n'
            IFS= read -r finish
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = startDownload(in: root)
        do {
            try await waitUntil { downloader.progress == 0.25 }
            XCTAssertNil(downloader.prompt)
            XCTAssertNil(downloader.errorMessage)
            await downloader.shutdown()
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testGuardFailureAfterMobileApprovalStopsWithoutRequestingAnotherCode() async throws {
        let root = try makeRuntime("""
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
        let root = try makeRuntime("""
            printf 'Logging in user to Steam Public...FAILED (Timeout)'
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = startDownload(in: root)
        do {
            try await waitUntil { !downloader.isRunning }
            XCTAssertNotNil(downloader.errorMessage)
            XCTAssertNil(downloader.downloadedID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path), "Login failure must stop before starting the importer")
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testDeniedMobileApprovalCanRestartWithFreshCredentials() async throws {
        let root = try makeRuntime("""
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
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".mac-wallpaper-engine-workshop-") })

            try Data().write(to: root.appendingPathComponent("approve-next-login"))
            downloader.start(item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("Library"), onImported: {})
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
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8), "retried-content")
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testWorkshopAccessDenialDoesNotOfferAuthenticationRetry() async throws {
        let root = try makeRuntime("""
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
        let root = try makeRuntime("""
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
        try Data("previous-incomplete-install".utf8).write(to: destination.appendingPathComponent("old"))
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        downloader.installAssets(username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), destination: destination, onInstalled: {})
        do {
            try await waitUntil { downloader.prompt == .password }
            downloader.submitSecret("local-password")
            try await waitUntil { !downloader.isRunning }
            XCTAssertNil(downloader.errorMessage)
            XCTAssertTrue(ClientPaths.hasSceneAssets(at: destination))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("shaders/genericimage2.vert"), encoding: .utf8), "vertex-content")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
            try assertNoStaging(in: root)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["shaders", "materials"])
            XCTAssertNil(downloader.downloadedID, "Shared assets must not be reported as a Workshop item")
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testIncompleteSceneAssetsNeverReplaceExistingInstallation() async throws {
        let root = try makeRuntime("""
            printf 'Waiting for user info...OK\\n'
            mkdir -p wallpaper-engine/assets/shaders
            printf 'partial-download' > wallpaper-engine/assets/shaders/genericimage2.vert
            printf "Success! App '431960' fully installed.\\n"
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("SceneAssets")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: destination.appendingPathComponent("existing"))
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        downloader.installAssets(username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), destination: destination) {
            XCTFail("An incomplete install must not become the renderer's configured assets")
        }
        do {
            try await waitUntil { !downloader.isRunning }
            XCTAssertNotNil(downloader.errorMessage)
            XCTAssertFalse(downloader.canRetryAuthentication, "Asset validation failure is not a sign-in failure")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("existing"), encoding: .utf8), "preserved")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["existing"])
            try assertNoStaging(in: root)
        } catch {
            await downloader.shutdown()
            throw error
        }
    }

    func testCancellingSceneAssetDownloadDoesNotPublishPartialResources() async throws {
        let root = try makeRuntime("""
            mkdir -p wallpaper-engine/assets/shaders
            printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
            printf 'Update state (0x61) downloading, 25%%\\n'
            IFS= read -r finish
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("SceneAssets")
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        downloader.installAssets(username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), destination: destination) {
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

        let second = startDownload(in: root, username: "LOCALTEST", itemID: "234567", libraryName: "OtherLibrary")
        try await assertImported(second, in: root, itemID: "234567", libraryName: "OtherLibrary")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("OtherLibrary/234567/movie.mp4"), encoding: .utf8), "cached:localtest:234567")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
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
            try await waitUntil { cancelled.progress == 0.25 }
            await cancelled.shutdown()
        } catch {
            await cancelled.shutdown()
            throw error
        }
        XCTAssertNil(cancelled.downloadedID)
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertEqual(cancelled.savedAccount, "localtest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
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
        XCTAssertEqual((try files.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
        try assertNoStaging(in: root)
    }

    func testConcurrentDownloadsKeepPromptsCancellationAndQueueIndependent() async throws {
        let root = try makeRuntime("""
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
        let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        var imported = Set<String>()
        func enqueue(_ id: String) throws -> WorkshopDownload {
            let requested = WorkshopItem(id: id, title: "Concurrent \(id)", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
            manager.start(item: requested, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("Library"), rememberSession: false) {
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
            XCTAssertTrue(try enqueue("1") === first, "A repeated click must not create a second transfer")
            try await waitUntil { [first, second, third].allSatisfy { $0.worker.prompt == .password } }
            XCTAssertTrue(fourth.isQueued)
            XCTAssertTrue(fifth.isQueued)
            first.worker.submitSecret("secret1")
            try await waitUntil { first.progress == 0.25 }
            XCTAssertEqual(second.worker.prompt, .password)
            XCTAssertEqual(third.worker.prompt, .password)
            manager.cancel(second)
            try await waitUntil { fourth.worker.prompt == .password }
            XCTAssertTrue(first.isPending)
            XCTAssertTrue(third.isPending)
            XCTAssertTrue(fifth.isQueued, "Only the oldest queued item may claim a freed slot")
            manager.cancel(fifth)
            third.worker.submitSecret("secret3")
            fourth.worker.submitSecret("secret4")
            try await waitUntil { ["1", "3", "4"].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\($0)").path) } }
            for id in ["1", "3", "4"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
            try await waitUntil { !manager.isRunning }
            XCTAssertEqual(imported, ["1", "3", "4"])
            for id in imported {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Library/\(id)/movie.mp4"), encoding: .utf8), "content-\(id)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/2").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("running-5").path))
            try assertNoStaging(in: root)
        } catch {
            await manager.shutdown()
            throw error
        }
    }

    func testFailedDownloadReleasesSlotAndShutdownNeverLaunchesQueuedWork() async throws {
        let root = try makeRuntime("""
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
        let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"), maximumConcurrentDownloads: 1, runtimeProvider: ShellRuntimeProvider())
        for id in ["1", "2", "3"] {
            let requested = WorkshopItem(id: id, title: id, creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
            manager.start(item: requested, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
        }
        do {
            try await waitUntil { manager.download(for: "2")?.worker.prompt == .password }
            XCTAssertTrue(manager.download(for: "1")?.worker.canRetryAuthentication == true)
            XCTAssertTrue(manager.download(for: "3")?.isQueued == true)
            await manager.shutdown()
            XCTAssertFalse(manager.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched-3").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
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
        let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        manager.start(item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("OtherLibrary"), onImported: {})
        do {
            try await waitUntil { manager.download(for: item.id)?.progress == 0.25 }
            manager.forgetSavedAccount()
            XCTAssertNotNil(manager.errorMessage)
            XCTAssertEqual(manager.savedAccount, "localtest")
            let other = WorkshopItem(id: "234567", title: "Opt out", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
            manager.start(item: other, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("OtherLibrary"), rememberSession: false, onImported: {})
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
        let rejectingRuntime = try makeRuntime("""
            [ -f config/config.vdf ] || exit 10
            printf 'Logging in using cached credentials\\n'
            touch ../old-session-restored
            while [ ! -f ../reject-old-session ]; do sleep 0.02; done
            printf 'FAILED (Invalid cached credentials)\\n'
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: rejectingRuntime) }
        let rejected = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        rejected.start(item: item, username: "localtest", executable: rejectingRuntime.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("OtherLibrary"), onImported: {})
        do {
            try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("old-session-restored").path) }
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
        let root = try makeRuntime("""
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
        try assertNoStaging(in: root)
    }

    func testDefaultRuntimeRejectsShellWithoutExecutingOrChangingIt() throws {
        let root = try makeRuntime("printf unexpected > ../executed")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("runtime/steamcmd")
        let original = try Data(contentsOf: executable)
        XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable))
        XCTAssertEqual(try Data(contentsOf: executable), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    }

    func testMalformedMachOLoadCommandsAreRejectedWithoutModifyingSource() throws {
        let root = try makeRuntime("exit 0")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("runtime/steamcmd")
        // A 64-bit executable declares a load-command table that exceeds the actual file.
        var malformed = Data()
        for word in [UInt32(0xfeedfacf), 0x01000007, 3, 2, 1, 4096, 0, 0] {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { malformed.append(contentsOf: $0) }
        }
        try malformed.write(to: executable)
        XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable)) { error in
            XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
        }
        XCTAssertEqual(try Data(contentsOf: executable), malformed)
    }

    func testDefaultProviderPreservesContainedFrameworkLinksAcrossPrivateVarAliases() async throws {
        let files = FileManager.default
        let directory = try makeMachOFrameworkRuntime()
        defer { try? files.removeItem(at: directory) }
        let root = directory.appendingPathComponent("MacOS", isDirectory: true)
        let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
        let aliasPath = root.path.hasPrefix("/private/var/") ? String(root.path.dropFirst("/private".count)) : root.path
        let privatePath = aliasPath.hasPrefix("/var/") ? "/private" + aliasPath : aliasPath
        let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
        let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
        let physical = URL(fileURLWithPath: privatePath, isDirectory: true)
        try await service.validateBootstrap(at: physical)
        try await service.validate(at: alias)
        XCTAssertEqual(try service.resolve(executable: alias.appendingPathComponent("steamcmd")),
                       try service.resolve(executable: physical.appendingPathComponent("steamcmd")))
        let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
        let prepared = try await service.prepare(executable: physical.appendingPathComponent("steamcmd"), staging: staging)
        XCTAssertEqual(try Data(contentsOf: prepared), try Data(contentsOf: root.appendingPathComponent("steamcmd")))
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("Frameworks/Breakpad.framework/Resources").path), "Versions/Current/Resources")
        XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("Frameworks/Breakpad.framework/Resources/Info.txt"), encoding: .utf8), "sealed-resource-fixture")

        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("preserved".utf8).write(to: outside.appendingPathComponent("sentinel"))
        try files.removeItem(at: framework.appendingPathComponent("Resources"))
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "../../../outside")
        do {
            try await service.validate(at: physical)
            XCTFail("A framework link escaping its container must be rejected")
        } catch {
            XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8), "preserved")
    }

    func testNestedHelperRetainsExecutableContextThroughDylibAndRPathChains() async throws {
        let files = FileManager.default
        let directory = try makeMachOFrameworkRuntime()
        defer { try? files.removeItem(at: directory) }
        let root = directory.appendingPathComponent("MacOS", isDirectory: true)
        let version = root.appendingPathComponent("Frameworks/Breakpad.framework/Versions/A", isDirectory: true)
        let helper = version.appendingPathComponent("Helpers/report_sender")
        try files.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: false)
        let images = [
            (helper, fixtureMachO(fileType: 2, dependency: "@executable_path/../Resources/breakpadUtilities.dylib", rpaths: ["@executable_path/../Resources"])),
            (version.appendingPathComponent("Resources/breakpadUtilities.dylib"), fixtureMachO(fileType: 6, dependency: "@rpath/helperSupport.dylib")),
            (version.appendingPathComponent("Resources/helperSupport.dylib"), fixtureMachO(fileType: 6, dependency: "@executable_path/../Resources/last.dylib")),
            (version.appendingPathComponent("Resources/last.dylib"), fixtureMachO(fileType: 6))
        ]
        for (url, contents) in images { try contents.write(to: url) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
        let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
        _ = try await service.prepare(executable: root.appendingPathComponent("steamcmd"), staging: staging)
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
        let directory = files.temporaryDirectory.appendingPathComponent("mwe-framework-links-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("MacOS", isDirectory: true)
        let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
        let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
        try files.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("sealed-resource-fixture".utf8).write(to: version.appendingPathComponent("Resources/Info.txt"))
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Breakpad").path, withDestinationPath: "Versions/Current/Breakpad")
        for (path, contents) in [
            (root.appendingPathComponent("steamcmd"), fixtureMachO(fileType: 2)),
            (root.appendingPathComponent("steamconsole.dylib"), fixtureMachO(fileType: 6, dependency: "@loader_path/crashhandler.dylib")),
            (root.appendingPathComponent("crashhandler.dylib"), fixtureMachO(fileType: 6, dependency: "@loader_path/Breakpad.framework/Versions/A/Breakpad")),
            (version.appendingPathComponent("Breakpad"), fixtureMachO(fileType: 6))
        ] {
            try contents.write(to: path)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appendingPathComponent("steamcmd.sh"))
        return directory
    }

    private func fixtureMachO(fileType: UInt32, dependency: String? = nil, rpaths: [String] = []) -> Data {
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
        for (command, path) in entries + rpaths.map({ (UInt32(0x8000001c), $0) }) {
            let name = Data((path + "\0").utf8)
            let header = command == 0xc ? 24 : 12
            let length = (header + name.count + 3) & ~3
            commands.append(words([command, UInt32(length), UInt32(header)]))
            if command == 0xc { commands.append(words([0, 0, 0])) }
            commands.append(name)
            commands.append(Data(repeating: 0, count: length - header - name.count))
        }
        return words([0xfeedfacf, 0x01000007, 3, fileType, UInt32(entries.count + rpaths.count), UInt32(commands.count), 0, 0]) + commands
    }

    func testShutdownWaitsForOwnedDescendantsBeforeRemovingStaging() async throws {
        let root = try makeRuntime("""
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
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
            XCTAssertNil(downloader.downloadedID)
        } catch {
            await downloader.shutdown()
            throw error
        }
    }
    private func makeSessionRuntime() throws -> URL {
        try makeRuntime("""
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

    private func setSessionMode(_ mode: String, in root: URL) throws {
        try Data(mode.utf8).write(to: root.appendingPathComponent("session-mode"))
    }

    private func authenticate(_ downloader: WorkshopDownloader) async throws {
        do {
            try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
            guard downloader.prompt == .password else {
                throw WorkshopFailure(message: "Expected a fresh password prompt: \(downloader.errorMessage ?? "session ended")")
            }
            downloader.submitSecret("local-password")
            try await waitUntil { downloader.prompt == .guardCode || !downloader.isRunning }
            guard downloader.prompt == .guardCode else {
                throw WorkshopFailure(message: "Expected a Steam Guard prompt: \(downloader.errorMessage ?? "session ended")")
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

    private func assertImported(_ downloader: WorkshopDownloader, in root: URL, itemID: String, libraryName: String = "Library", file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitForStop(downloader)
        XCTAssertNil(downloader.errorMessage, file: file, line: line)
        XCTAssertEqual(downloader.downloadedID, itemID, file: file, line: line)
        let movie = root.appendingPathComponent("\(libraryName)/\(itemID)/movie.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path), "The newly requested wallpaper must actually be imported", file: file, line: line)
    }

    private func assertNoStaging(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix(".mac-wallpaper-engine-workshop-") }, file: file, line: line)
    }

    private func sessionEntries(in root: URL) throws -> [URL] {
        let session = root.appendingPathComponent("SteamSession")
        guard FileManager.default.fileExists(atPath: session.path) else { return [] }
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: session, includingPropertiesForKeys: [.isRegularFileKey]))
        return [session] + enumerator.compactMap { $0 as? URL }
    }

    private func assertNoSavedCredentials(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        for url in try sessionEntries(in: root) where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let contents = try Data(contentsOf: url)
            for marker in ["token:", "registry:", "machine-token", "local-password", "12345-secret"] {
                XCTAssertNil(contents.range(of: Data(marker.utf8)), "Forgotten credentials remain in \(url.lastPathComponent)", file: file, line: line)
            }
        }
    }

    private func assertPrivateSession(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try sessionEntries(in: root)
        for url in entries {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(permissions & 0o077, 0, "Steam credentials must be inaccessible to group and other users: \(url.path)", file: file, line: line)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let contents = try Data(contentsOf: url)
            for forbidden in ["local-password", "12345-secret", "fresh:localtest:123456", "\"movie.mp4\""] {
                XCTAssertNil(contents.range(of: Data(forbidden.utf8)), "Session storage must not retain submitted secrets or wallpaper content", file: file, line: line)
            }
            XCTAssertNotEqual(url.lastPathComponent, "console.log", file: file, line: line)
        }
    }

    private func makeRuntime(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-terminal-tests-\(UUID().uuidString)")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let executable = runtime.appendingPathComponent("steamcmd")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return root
    }

    private func startDownload(in root: URL, username: String = "localtest", itemID: String = "123456", libraryName: String = "Library", rememberSession: Bool = true) -> WorkshopDownloader {
        let downloader = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider())
        let requestedItem = WorkshopItem(id: itemID, title: "Session fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
        downloader.start(item: requestedItem, username: username, executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent(libraryName), rememberSession: rememberSession, onImported: {})
        return downloader
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw WorkshopFailure(message: "SteamCMD did not advance its interactive session") }
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
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
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
              try String(contentsOf: executable, encoding: .utf8).hasPrefix("#!/bin/sh\n") else {
            throw WorkshopFailure(message: "The shell runtime fixture is missing or invalid")
        }
    }
}

/// The fixture exercises production filesystem/load-command validation, not Apple's trust policy.
private struct FixtureSystemAssessment: SteamCMDProcessRunning {
    func run(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
             onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        guard ["/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/arch"].contains(executable.path) else {
            throw WorkshopFailure(message: "The fixture must not execute a runtime program")
        }
        try Task.checkCancellation()
        return 0
    }
}
