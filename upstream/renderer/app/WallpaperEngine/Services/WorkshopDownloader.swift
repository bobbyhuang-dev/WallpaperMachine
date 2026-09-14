import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class WorkshopDownloader {
    enum Prompt: String { case password = "Steam password", guardCode = "Steam Guard code" }
    enum SteamGuardChallenge { case mobileApproval, authenticatorCode, emailCode }
    private(set) var isRunning = false
    private(set) var status = "Ready to download"
    private(set) var progress: Double?
    private(set) var prompt: Prompt?
    private(set) var steamGuardChallenge: SteamGuardChallenge?
    var canRetryAuthentication: Bool { authenticationFailed && !isRunning }
    private var authenticationFailed = false
    private(set) var errorMessage: String?
    private(set) var downloadedID: String?
    private(set) var currentItemID: String?
    private(set) var isInstallingAssets = false
    private(set) var savedAccount: String?
    private(set) var sessionWarning: String?
    @ObservationIgnored private let sessionDirectory: URL
    @ObservationIgnored private var cachedCredentialsRejected = false
    @ObservationIgnored private var assetsDownloadCompleted = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var terminal: FileHandle?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recentOutput = ""
    @ObservationIgnored private var outputBuffer = [UInt8](repeating: 0, count: 8192)
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var isAuthenticating = true
    private static let failurePattern = try! NSRegularExpression(pattern: #"(?:failed|error!?)\s*\(([^)\r\n]+)\)"#)
    private static let progressPattern = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#)

    init(sessionDirectory: URL = ClientPaths.supportURL.appendingPathComponent("SteamSession", isDirectory: true)) {
        self.sessionDirectory = sessionDirectory
        savedAccount = Self.readSavedAccount(at: sessionDirectory)
    }

    func forgetSavedAccount() {
        guard !isRunning else { return }
        do {
            try Self.removeSession(at: sessionDirectory)
            savedAccount = nil
            sessionWarning = nil
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Could not forget the saved Steam sign-in: \(error.localizedDescription)")
        }
    }

    func start(item: WorkshopItem, username: String, executable: URL, library: URL, rememberSession: Bool = true, onImported: @escaping @MainActor () async throws -> Void) {
        guard !isRunning else { return }
        guard UInt64(item.id) != nil, item.kind != .application else {
            errorMessage = "Choose a valid Workshop wallpaper. Application wallpapers execute Windows programs and cannot be used on macOS."
            return
        }
        download(itemID: item.id, username: username, executable: executable, root: library.deletingLastPathComponent(), rememberSession: rememberSession) { staging in
            self.status = "Validating and adding to your library…"
            let source = staging.appendingPathComponent("steamapps/workshop/content/431960/\(item.id)", isDirectory: true)
            let report = try await WallpaperImportService().importItems([source], into: library, duplicates: .skip) { _ in }
            if report.cancelled { throw CancellationError() }
            guard report.importedIDs.contains(item.id) || report.skipped.contains(item.id) else {
                throw WorkshopFailure(message: report.failures.isEmpty
                    ? "Steam did not produce a valid wallpaper folder. Confirm ownership and retry."
                    : report.failures.joined(separator: "\n"))
            }
            self.downloadedID = item.id
            self.status = "Downloaded to your library"
            do { try await onImported() }
            catch { self.errorMessage = "Downloaded successfully, but the library could not refresh: \(error.localizedDescription). Use Refresh in Library before applying." }
        }
    }

    func installAssets(username: String, executable: URL, destination: URL, rememberSession: Bool = true, onInstalled: @escaping @MainActor () throws -> Void) {
        download(itemID: nil, username: username, executable: executable, root: destination.deletingLastPathComponent(), rememberSession: rememberSession) { staging in
            self.status = "Validating and installing scene assets…"
            try ClientPaths.installSceneAssets(from: staging.appendingPathComponent("wallpaper-engine/assets"), to: destination)
            try onInstalled()
            self.status = "Scene assets installed"
        }
    }

    private func download(itemID: String?, username: String, executable: URL, root: URL, rememberSession: Bool,
                          onDownloaded: @escaping @MainActor (URL) async throws -> Void) {
        guard !isRunning else { return }
        guard let account = Self.normalizedAccount(username) else {
            errorMessage = "Enter your Steam account login name (not your display name). An account that owns Wallpaper Engine is required."
            return
        }
        if !rememberSession {
            forgetSavedAccount()
            guard errorMessage == nil else { return }
        }
        failure = nil
        errorMessage = nil
        sessionWarning = nil
        cachedCredentialsRejected = false
        isAuthenticating = true
        assetsDownloadCompleted = false
        authenticationFailed = false
        steamGuardChallenge = nil
        if itemID != nil { downloadedID = nil }
        progress = nil
        prompt = nil
        recentOutput = ""
        isRunning = true
        currentItemID = itemID
        isInstallingAssets = itemID == nil
        status = "Preparing a private SteamCMD download…"
        task = Task {
            let staging = root.appendingPathComponent(".mac-wallpaper-engine-workshop-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? terminal?.close()
                terminal = nil
                process = nil
                prompt = nil
                recentOutput = ""
                isRunning = false
                task = nil
                try? FileManager.default.removeItem(at: staging)
            }
            var restoredSession = false
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try Self.prepare(executable: executable, staging: staging)
                }.value
                if rememberSession, Self.readSavedAccount(at: sessionDirectory) == account {
                    let directory = sessionDirectory
                    restoredSession = try await Task.detached(priority: .utility) {
                        try Self.copySessionFiles(from: directory, to: staging)
                    }.value
                }
                try Task.checkCancellation()
                let started = Date()
                var restarts = 0
                repeat {
                    try Task.checkCancellation()
                    try await Task.detached(priority: .utility) {
                        try Self.validateRuntime(at: staging)
                    }.value
                    try Task.checkCancellation()
                    try launch(executable: prepared, staging: staging, account: account, itemID: itemID)
                    while let process, process.isRunning {
                        try Task.checkCancellation()
                        try readTerminalOutput()
                        if failure != nil || Date().timeIntervalSince(started) > 1800 || Date().timeIntervalSince(lastActivity) > 300 {
                            if failure == nil {
                                authenticationFailed = isAuthenticating
                                failure = "SteamCMD timed out. If Steam Guard was not completed, retry signing in and approve the new request or enter a fresh code. Otherwise check your connection and available disk space."
                            }
                            await stopProcess()
                            break
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    // Drain the last output before closing, even when SteamCMD has already exited.
                    try readTerminalOutput()
                    try? terminal?.close()
                    terminal = nil
                    restarts += 1
                } while process?.terminationStatus == 42 && restarts < 4 && failure == nil
                try Task.checkCancellation()
                if let failure { throw WorkshopFailure(message: failure) }
                guard process?.terminationStatus == 0 else {
                    authenticationFailed = isAuthenticating
                    throw WorkshopFailure(message: "SteamCMD exited before completing the download. Confirm this account owns Wallpaper Engine, approve Steam Guard, and retry. On Apple silicon, SteamCMD may require Rosetta 2.")
                }
                progress = nil
                if isInstallingAssets && !assetsDownloadCompleted {
                    throw WorkshopFailure(message: "Steam exited without confirming a complete Wallpaper Engine installation. Retry installing scene assets; existing assets have not been changed.")
                }
                try await onDownloaded(staging)
            } catch is CancellationError {
                await stopProcess()
                try? readTerminalOutput()
                authenticationFailed = false
                steamGuardChallenge = nil
                status = "Download cancelled"
            } catch {
                await stopProcess()
                try? readTerminalOutput()
                errorMessage = error.localizedDescription
                status = "Download could not finish"
            }
            if rememberSession {
                do {
                    if !isAuthenticating && !authenticationFailed {
                        let directory = sessionDirectory
                        let stored = try await Task.detached(priority: .utility) {
                            try Self.saveSession(from: staging, account: account, to: directory)
                        }.value
                        if stored {
                            savedAccount = account
                        } else {
                            sessionWarning = String(localized: "Steam did not provide reusable sign-in files. You may need to sign in again next time.")
                        }
                    } else if restoredSession && cachedCredentialsRejected {
                        try Self.removeSession(at: sessionDirectory)
                        savedAccount = nil
                    }
                } catch {
                    sessionWarning = String(localized: "Could not update the saved Steam sign-in: \(error.localizedDescription). You may need to sign in again next time.")
                }
            }
        }
    }

    func submitSecret(_ value: String) {
        guard isRunning, prompt != nil, !value.isEmpty,
              !value.contains(where: { $0.isNewline || $0 == "\0" }), let terminal else { return }
        do {
            // Only the terminal receives the secret. No arguments, scripts, defaults, or log output.
            try terminal.write(contentsOf: Data((value + "\n").utf8))
            prompt = nil
            recentOutput = ""
            status = "Waiting for Steam authentication…"
            lastActivity = Date()
        } catch {
            authenticationFailed = true
            failure = "SteamCMD closed its login prompt. Retry signing in to start a new session."
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        status = "Cancelling…"
        // The task stops the child before staging cleanup; the importer checks cancellation before its atomic move.
    }

    func shutdown() async {
        guard let current = task else { return }
        current.cancel()
        await current.value
    }

    private func launch(executable: URL, staging: URL, account: String, itemID: String?) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw WorkshopFailure(message: "Could not create a private terminal for SteamCMD. Restart MacWallpaperEngine and retry.")
        }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            tcsetattr(slave, TCSANOW, &settings)
        }
        let input = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WorkshopFailure(message: "Could not read SteamCMD’s private terminal without blocking. Restart MacWallpaperEngine and retry.")
        }
        terminal = input
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = staging
        let isInstalled = FileManager.default.fileExists(atPath: staging.appendingPathComponent("steamconsole.dylib").path)
        let installDirectory = itemID == nil ? staging.appendingPathComponent("wallpaper-engine") : staging
        let platform = itemID == nil ? ["+@sSteamCmdForcePlatformType", "windows"] : []
        let command = itemID.map { ["+workshop_download_item", "431960", $0, "validate"] } ?? ["+app_update", "431960", "validate"]
        process.arguments = (isInstalled ? ["-inhibitbootstrap"] : []) + ["+@ShutdownOnFailedCommand", "1"] + platform
            + ["+force_install_dir", installDirectory.path, "+login", account] + command + ["+quit"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = staging.path
        environment["TERM"] = "dumb"
        environment["DYLD_LIBRARY_PATH"] = staging.path
        environment["DYLD_FRAMEWORK_PATH"] = staging.path
        process.environment = environment
        process.standardInput = child
        process.standardOutput = child
        process.standardError = child
        self.process = process
        recentOutput = ""
        prompt = nil
        steamGuardChallenge = nil
        isAuthenticating = true
        lastActivity = Date()
        do { try process.run() }
        catch {
            try? child.close()
            throw WorkshopFailure(message: "Cannot launch SteamCMD: \(error.localizedDescription). Install the macOS SteamCMD distribution; on Apple silicon install Rosetta 2 if requested.")
        }
        try? child.close()
        status = "Starting SteamCMD and contacting Steam…"
    }

    private func readTerminalOutput() throws {
        guard let terminal else { return }
        // FileHandle.read(upToCount:) waits to fill its buffer on a PTY. A short
        // password prompt would deadlock both sides, so read only available bytes.
        while true {
            let count = outputBuffer.withUnsafeMutableBytes {
                Darwin.read(terminal.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                consume(String(decoding: outputBuffer[..<count], as: UTF8.self))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EIO {
                return
            } else if errno != EINTR {
                throw WorkshopFailure(message: "Lost the connection to SteamCMD’s login terminal. Retry signing in.")
            }
        }
    }

    private func consume(_ text: String) {
        guard isRunning else { return }
        lastActivity = Date()
        recentOutput += text.lowercased()
        // Keep only the incomplete line, not old prompts that can mask later failures.
        while let newline = recentOutput.firstIndex(where: { $0.isNewline }) {
            let line = String(recentOutput[..<newline])
            recentOutput.removeSubrange(...newline)
            consumeLine(line)
        }
        recentOutput = String(recentOutput.suffix(4096))
        // Interactive prompts have no newline and can span multiple reads.
        consumeLine(recentOutput)
    }

    private func consumeLine(_ line: String) {
        let output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, failure == nil else { return }
        if output.contains("cached credential") && (output.contains("invalid") || output.contains("expired") || output.contains("revoked")) {
            cachedCredentialsRejected = true
            // SteamCMD can fall back to its password prompt in the same process.
            if output.contains("warning") {
                status = String(localized: "Saved Steam sign-in expired; waiting for fresh authentication…")
                if output.hasSuffix("password:") { consumeLine("password:") }
                return
            }
        }
        if output.contains("no subscription") || (output.contains("access denied") && !isAuthenticating) || output.contains("does not own") {
            failure = "Steam denied this download. Sign in with an account that owns Wallpaper Engine and has access to this Workshop item."
        } else if output.contains("error! download item") || output.contains("failed to download") || output.contains("error! failed to start downloading item") {
            failure = "Steam could not download this item. It may be private, removed, or unavailable to this account. Open its Workshop page and retry."
        } else if isInstallingAssets && (output.contains("error! app") || output.contains("failed to install app")) {
            failure = "Steam could not install Wallpaper Engine’s shared assets. Confirm ownership and check available disk space, then retry."
        } else if let match = Self.failurePattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) {
            let reason = output[range]
            authenticationFailed = isAuthenticating
            if cachedCredentialsRejected && reason.contains("cached credential") {
                failure = String(localized: "Your saved Steam sign-in has expired or was revoked. Choose Retry Steam sign-in and complete authentication again.")
            } else if reason.contains("two-factor") || reason.contains("auth code") || reason.contains("steam guard")
                || (steamGuardChallenge != nil && (reason.contains("denied") || reason.contains("cancel"))) {
                failure = "Steam Guard was rejected, cancelled, or expired. Choose Retry Steam sign-in, enter your password again, then approve the new request or use a fresh code."
            } else if reason.contains("timeout") || reason.contains("timed out") || reason.contains("connection") || reason.contains("service unavailable") {
                failure = "Steam could not complete the connection or sign-in in time. Check your connection and any Steam Guard approval, then retry."
            } else if reason.contains("rate limit") || reason.contains("too many") {
                failure = "Steam has temporarily limited sign-in attempts. Wait before retrying."
            } else {
                failure = "Steam rejected the sign-in. Check your account login name, password, and Steam Guard approval, then retry."
            }
        } else if output.contains("invalid password") || output.contains("invalid login") || output.contains("account logon denied") {
            authenticationFailed = true
            failure = "Steam rejected the sign-in. Check your account login name and password, then retry."
        } else if output.hasSuffix("password:") {
            prompt = .password
            steamGuardChallenge = nil
            progress = nil
            status = "Enter your Steam password below"
        } else if output.hasSuffix("auth code:") || output.hasSuffix("steam guard code:") || output.hasSuffix("two-factor code:") || output.hasSuffix("enter the code:") || output.hasSuffix("enter code:") {
            prompt = .guardCode
            steamGuardChallenge = output.hasSuffix("steam guard code:") ? .emailCode : .authenticatorCode
            progress = nil
            status = "Enter the code from Steam Guard or your email"
        } else if isInstallingAssets && (output.contains("update state") || output.contains("success! app")) {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            status = output.contains("success! app") ? "Download finished; validating scene assets…" : "Downloading and validating Wallpaper Engine files…"
            if output.contains("success! app '431960' fully installed") { assetsDownloadCompleted = true }
        } else if output.contains("success. downloaded item") {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            status = "Download finished; waiting for SteamCMD to close…"
            progress = 1
        } else if output.contains("downloading item") {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            status = "Downloading Workshop files…"
        } else if output.contains("logged in ok") || output.contains("waiting for user info...ok") {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            progress = nil
            status = isInstallingAssets ? "Signed in; requesting Wallpaper Engine’s shared assets…" : "Signed in; requesting your Workshop download…"
        } else if output.contains("confirm") && (output.contains("mobile") || output.contains("steam guard")) {
            prompt = nil
            steamGuardChallenge = .mobileApproval
            progress = nil
            status = "Approve the sign-in in the Steam mobile app"
        } else if output.contains("logging in using cached credentials") {
            prompt = nil
            progress = nil
            status = String(localized: "Using your saved Steam sign-in…")
        } else if output.contains("logging in") || output.contains("waiting for client config") || output.contains("waiting for user info") {
            prompt = nil
            progress = nil
            status = "Waiting for Steam authentication…"
        } else if output.contains("update") || output.contains("verifying installation") {
            status = "Updating the private SteamCMD runtime…"
        }
        if failure != nil {
            prompt = nil
            progress = nil
            return
        }
        if let match = Self.progressPattern.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
           let range = Range(match.range(at: 1), in: output), let percent = Double(output[range]), percent <= 100 {
            progress = percent / 100
        }
    }

    private func stopProcess() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 {
            if !process.isRunning { return }
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        if process.isRunning {
            // This PID belongs to our still-live direct child, not an externally discovered process.
            Darwin.kill(process.processIdentifier, SIGKILL)
            while process.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value }
        }
    }

    nonisolated private static func normalizedAccount(_ username: String) -> String? {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty, account != "anonymous",
              account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return account
    }

    nonisolated private static func readSavedAccount(at directory: URL) -> String? {
        let files = FileManager.default
        let identity = directory.appendingPathComponent("account")
        guard (try? files.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? files.attributesOfItem(atPath: identity.path)[.type]) as? FileAttributeType == .typeRegular,
              let account = try? String(contentsOf: identity, encoding: .utf8) else { return nil }
        return normalizedAccount(account)
    }

    nonisolated private static func removeSession(at directory: URL) throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    nonisolated private static func privateDirectory(_ directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw WorkshopFailure(message: String(localized: "Steam sign-in storage must be a private directory, not a symbolic link."))
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    nonisolated private static func copySessionFiles(from source: URL, to destination: URL) throws -> Bool {
        let files = FileManager.default
        try privateDirectory(source)
        try privateDirectory(destination)
        var copied = false
        // Preserve Steam's opaque token + machine-auth state, not logs, programs,
        // downloaded content, or submitted passwords/codes. macOS uses both roots.
        layouts: for base in ["", "Library/Application Support/Steam"] {
            var sourceBase = source
            var destinationBase = destination
            for component in base.split(separator: "/") {
                sourceBase.appendPathComponent(String(component))
                destinationBase.appendPathComponent(String(component))
                guard files.fileExists(atPath: sourceBase.path) else { continue layouts }
                guard try files.attributesOfItem(atPath: sourceBase.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw WorkshopFailure(message: String(localized: "Steam sign-in files cannot be read through symbolic links."))
                }
                try privateDirectory(destinationBase)
            }
            for subdirectory in ["", "config"] {
                let folder = subdirectory.isEmpty ? sourceBase : sourceBase.appendingPathComponent(subdirectory)
                guard files.fileExists(atPath: folder.path) else { continue }
                guard try files.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw WorkshopFailure(message: String(localized: "Steam sign-in files cannot be read through symbolic links."))
                }
                for file in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    let name = file.lastPathComponent
                    let isSessionFile = subdirectory.isEmpty
                        ? name == "registry.vdf" || name.hasPrefix("ssfn")
                        : name == "config.vdf" || name == "loginusers.vdf" || name == "local.vdf" || (name.hasPrefix("local_") && name.hasSuffix(".vdf"))
                    guard isSessionFile else { continue }
                    guard try files.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                        throw WorkshopFailure(message: String(localized: "Steam sign-in storage contains an unsafe file."))
                    }
                    let targetFolder = subdirectory.isEmpty ? destinationBase : destinationBase.appendingPathComponent(subdirectory)
                    try privateDirectory(targetFolder)
                    let target = targetFolder.appendingPathComponent(name)
                    try files.copyItem(at: file, to: target)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    copied = true
                }
            }
        }
        return copied
    }

    nonisolated private static func saveSession(from staging: URL, account: String, to directory: URL) throws -> Bool {
        let files = FileManager.default
        let pending = directory.deletingLastPathComponent().appendingPathComponent(".steam-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: pending) }
        guard try copySessionFiles(from: staging, to: pending) else { return false }
        let identity = pending.appendingPathComponent("account")
        try Data(account.utf8).write(to: identity, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        if files.fileExists(atPath: directory.path) {
            try privateDirectory(directory)
            _ = try files.replaceItemAt(directory, withItemAt: pending)
        } else {
            try files.moveItem(at: pending, to: directory)
        }
        return true
    }

    nonisolated private static func prepare(executable: URL, staging: URL) throws -> URL {
        let files = FileManager.default
        let resolved = executable.resolvingSymlinksInPath()
        let root = resolved.deletingLastPathComponent()
        let binary = root.appendingPathComponent("steamcmd")
        guard files.isExecutableFile(atPath: binary.path) else {
            throw WorkshopFailure(message: "Choose steamcmd.sh or steamcmd from Valve’s complete macOS SteamCMD distribution. Keep its Frameworks folder and crashhandler.dylib beside the executable.")
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["steamcmd", "Frameworks", "crashhandler.dylib", "Steam.AppBundle", "steamconsole.dylib", "steamclient.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib", "libaudio.dylib", "libsteaminput.dylib", "public", "package"] {
            let source = root.appendingPathComponent(name)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        return staging.appendingPathComponent("steamcmd")
    }

    nonisolated private static func validateRuntime(at root: URL) throws {
        let framework = root.appendingPathComponent("Frameworks/Breakpad.framework")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamconsole.dylib").path),
              FileManager.default.fileExists(atPath: framework.path) else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--deep", "--strict", framework.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            throw WorkshopFailure(message: "SteamCMD’s Breakpad framework has an invalid signature. The download was stopped before launching it, so macOS will not repeatedly show a damaged-app warning. Select a repaired, complete SteamCMD installation or run this project’s scripts/setup-steamcmd.py. Your account has not been signed in.")
        }
    }

}
