import Darwin
import Foundation
import Observation

struct SteamCMDSetupIssue: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case invalidSelection, incompleteRuntime, network, invalidArchive, rosettaRequired
        case securityApprovalRequired, invalidSignature, updateFailed, timedOut, fileSystem
    }
    let kind: Kind
    let detail: String
    var errorDescription: String? { detail }
}

enum SteamCMDSetupState: Equatable {
    case idle, checking, downloading(received: Int64, expected: Int64?), extracting, updating
    case validating, committing, ready, cancelled, failed(SteamCMDSetupIssue)
}

@MainActor
protocol SteamCMDDownloadActivity: AnyObject {
    var isRunning: Bool { get }
}

protocol SteamCMDProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32
}

/// Every invocation owns a process group, including shell children; returning means its leader was reaped.
struct SteamCMDProcessRunner: SteamCMDProcessRunning {
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixIssue(String(localized: "Create process output pipe"), errno) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw posixIssue(String(localized: "Initialize process actions"), result) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw posixIssue(String(localized: "Initialize process attributes"), result) }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ code: Int32) throws { if code != 0 { throw posixIssue(String(localized: "Configure child process"), code) } }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[0]))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[1]))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw posixIssue(String(localized: "Start \(executable.lastPathComponent)"), result) }
        // The parent does not need a writer. Keep the deferred close from closing a reused descriptor.
        close(descriptors[1])
        descriptors[1] = -1
        let started = ContinuousClock.now
        var lastOutput = started
        var cleaned = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each drain so a noisy child cannot starve cancellation or the total deadline.
            for _ in 0..<32 {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                guard count > 0 else { break }
                lastOutput = .now
                onOutput(Data(buffer.prefix(count)))
            }
        }
        do {
            while true {
                try Task.checkCancellation()
                drain()
                // Observe exit without reaping: reserve the leader PID until all group signals are sent.
                var information = siginfo_t()
                let waited = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if waited == 0, information.si_pid == pid { break }
                if waited < 0, errno != EINTR {
                    let code = errno
                    // If another reaper took the leader, this PID is no longer ours to signal.
                    if code == ECHILD { cleaned = true }
                    throw posixIssue(String(localized: "Wait for child process"), code)
                }
                if started.duration(to: .now) > .seconds(1800) || lastOutput.duration(to: .now) > .seconds(300) {
                    throw SteamCMDSetupIssue(kind: .timedOut, detail: String(localized: "SteamCMD timed out. Check the connection and retry."))
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            drain()
            let status = await Self.stopGroup(pid, leaderExited: true)
            cleaned = true
            try Task.checkCancellation()
            return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        } catch {
            if !cleaned { _ = await Self.stopGroup(pid, leaderExited: false) }
            throw error
        }
    }

    private static func stopGroup(_ pid: pid_t, leaderExited: Bool) async -> Int32 {
        // An unstructured cleanup task deliberately does not inherit the cancelled caller's flag.
        await Task.detached(priority: .utility) {
            kill(-pid, SIGTERM)
            if !leaderExited {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while kill(-pid, 0) == 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            // The unreaped leader reserves this PID/PGID until after the final group signal.
            // A completed leader has no useful background work to leave running.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            return status
        }.value
    }

    private func posixIssue(_ action: String, _ code: Int32) -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "\(action): \(String(cString: strerror(code)))"))
    }
}

@MainActor
@Observable
final class SteamCMDSetupStore {
    private(set) var selectedRuntime: SteamCMDRuntime?
    private(set) var state: SteamCMDSetupState = .idle
    private(set) var retainedCandidateURL: URL?
    var isBusy: Bool {
        if discarding { return true }
        return switch state {
        case .checking, .downloading, .extracting, .updating, .validating, .committing: true
        case .idle, .ready, .cancelled, .failed: false
        }
    }
    @ObservationIgnored private let downloader: any SteamCMDDownloadActivity
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private let runtimeProvider: any SteamCMDRuntimeProviding
    @ObservationIgnored private let processRunner: any SteamCMDProcessRunning
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var discardOperation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private struct PendingInstallation: Codable, Equatable {
        enum Stage: String, Codable { case bootstrap, complete }
        let directory: String
        let device: UInt64
        let inode: UInt64
        var stage: Stage
        let replacingExisting: Bool
        var needsRosetta = false
        var detail = ""
    }
    @ObservationIgnored private var pending: PendingInstallation?
    private var discarding = false
    private var pendingURL: URL { supportDirectory.appendingPathComponent("SteamCMDPending.json") }
    private static let preferenceKey = "MacWallpaperEngineSteamCMDPath"
    private var managedURL: URL { supportDirectory.appendingPathComponent("SteamCMD", isDirectory: true) }

    init(downloader: any SteamCMDDownloadActivity, supportDirectory: URL = ClientPaths.supportURL,
         defaults: UserDefaults = .standard, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
         processRunner: any SteamCMDProcessRunning = SteamCMDProcessRunner()) {
        self.downloader = downloader
        // Normalize only Apple's fixed system aliases, never a user-selected runtime symlink.
        let path = supportDirectory.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            self.supportDirectory = URL(fileURLWithPath: "/private" + path, isDirectory: true)
        } else {
            self.supportDirectory = supportDirectory
        }
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.runtimeProvider = runtimeProvider
        self.processRunner = processRunner
        do {
            if let record = try readPending() {
                do {
                    _ = try stagingURL(for: record)
                    try Self.requireSafeDirectory(retainedRoot(record), mayBeMissing: false)
                    setPending(record)
                    state = .failed(pendingIssue(record))
                } catch {
                    // A dangling or substituted candidate cannot be resumed. Remove only the
                    // private record, never the path it supplied or a directory discovered through it.
                    if try readPending() == record { unlink(pendingURL.path) }
                    throw error
                }
            }
        } catch { state = .failed(Self.issue(error)) }
    }

    func refresh() async {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        begin(state: .checking) { store, token in
            defer {
                if let record = store.pending { store.state = .failed(store.pendingIssue(record)) }
            }
            if let explicit = store.defaults.string(forKey: Self.preferenceKey), !explicit.isEmpty {
                do {
                    let runtime = try await store.checkedRuntime(URL(fileURLWithPath: explicit))
                    try store.check(token)
                    store.selectedRuntime = runtime
                    store.state = .ready
                } catch {
                    try store.check(token)
                    store.selectedRuntime = nil
                    throw error
                }
                return
            }
            let candidates = [store.managedURL.appendingPathComponent("MacOS/steamcmd"),
                              store.managedURL.appendingPathComponent("steamcmd"),
                              URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
                              URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Steam/steamcmd.sh")]
            for candidate in candidates {
                try store.check(token)
                do {
                    let runtime = try await store.checkedRuntime(candidate)
                    try store.check(token)
                    store.selectedRuntime = runtime
                    store.state = .ready
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            try store.check(token)
            store.selectedRuntime = nil
            store.state = .idle
        }
        await operation?.value
    }

    func selectExisting(at url: URL) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        begin(state: .checking) { store, token in
            let runtime = try await store.checkedRuntime(url)
            try store.check(token)
            store.defaults.set(runtime.executableURL.path, forKey: Self.preferenceKey)
            store.selectedRuntime = runtime
            store.state = .ready
        }
    }

    func install(replacingExisting: Bool = false) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        if pending != nil { retryInstallation(); return }
        begin(state: .checking) { store, token in
            try await store.performInstall(replacingExisting: replacingExisting, token: token)
        }
    }

    func retryInstallation() {
        guard !isBusy, !downloader.isRunning, !discarding, let record = pending else { return }
        begin(state: .checking) { store, token in
            try await store.performRetained(record, token: token)
        }
    }

    func prepareApproval() async throws -> SteamCMDApprovalCandidate {
        guard !isBusy, !discarding, let record = pending,
              let approver = runtimeProvider as? any SteamCMDRuntimeApproving else { throw staleApprovalIssue() }
        let token = generation
        let root = try stagingURL(for: record).appendingPathComponent("runtime/MacOS", isDirectory: true)
        let candidate = try await approver.approvalCandidate(at: root, bootstrap: record.stage == .bootstrap)
        try check(token)
        guard !isBusy, !discarding, pending == record, candidate.rootURL == root,
              candidate.bootstrap == (record.stage == .bootstrap) else { throw staleApprovalIssue() }
        _ = try stagingURL(for: record)
        return candidate
    }

    func approveRetainedCandidate(_ candidate: SteamCMDApprovalCandidate) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        guard let record = pending, candidate.rootURL == retainedCandidateURL,
              candidate.bootstrap == (record.stage == .bootstrap),
              let approver = runtimeProvider as? any SteamCMDRuntimeApproving else {
            state = .failed(staleApprovalIssue())
            return
        }
        begin(state: .checking) { store, token in
            defer { if Task.isCancelled { try? store.removeStaging(record) } }
            _ = try store.stagingURL(for: record)
            let current = try await approver.approvalCandidate(at: candidate.rootURL, bootstrap: candidate.bootstrap)
            try store.check(token)
            guard store.pending == record, current == candidate else { throw store.staleApprovalIssue() }
            try await approver.approve(candidate)
            try store.check(token)
            try await store.performRetained(record, token: token)
        }
    }

    func discardRetainedCandidate() {
        guard !discarding, state != .committing, let record = pending else { return }
        discarding = true
        // Shutdown must also wait for this explicit deletion, not only the cancelled process owner.
        let active = operation
        active?.cancel()
        discardOperation = Task { @MainActor in
            await active?.value
            defer { discarding = false; discardOperation = nil }
            do {
                if pending?.directory == record.directory { try removeStaging(record) }
                state = selectedRuntime == nil ? .idle : .ready
            } catch { state = .failed(Self.issue(error)) }
        }
    }

    private func staleApprovalIssue() -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .invalidSelection, detail: String(localized: "The retained SteamCMD candidate changed. Review it again before approving."))
    }

    func cancel() {
        guard state != .committing else { return }
        if isBusy { operation?.cancel() }
    }

    func shutdown() async {
        if isBusy { cancel() }
        await operation?.value
        await discardOperation?.value
    }

    private func begin(state newState: SteamCMDSetupState,
                       body: @escaping @MainActor (SteamCMDSetupStore, UUID) async throws -> Void) {
        let token = UUID()
        generation = token
        state = newState
        operation = Task {
            defer { if generation == token { operation = nil } }
            do { try await body(self, token) }
            catch {
                guard generation == token else { return }
                // Do not leave an externally deleted or replaced old runtime available after failure.
                if let old = selectedRuntime {
                    let provider = runtimeProvider
                    do {
                        try await Task.detached(priority: .utility) {
                            let runtime = try provider.resolve(executable: old.executableURL)
                            try await provider.validate(at: runtime.rootURL)
                        }.value
                    }
                    catch { selectedRuntime = nil }
                }
                if error is CancellationError || Task.isCancelled { state = .cancelled }
                else { state = .failed(Self.issue(error)) }
            }
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func checkedRuntime(_ executable: URL) async throws -> SteamCMDRuntime {
        let runtime = try runtimeProvider.resolve(executable: executable)
        try await runtimeProvider.validate(at: runtime.rootURL)
        return runtime
    }

    private func setPending(_ record: PendingInstallation?) {
        pending = record
        retainedCandidateURL = record.map {
            supportDirectory.appendingPathComponent($0.directory, isDirectory: true)
                .appendingPathComponent("runtime/MacOS", isDirectory: true)
        }
    }

    private func pendingIssue(_ record: PendingInstallation) -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: record.needsRosetta ? .rosettaRequired : .securityApprovalRequired, detail: record.detail)
    }

    private func stagingURL(for record: PendingInstallation) throws -> URL {
        let prefix = ".steamcmd-setup-"
        guard record.directory.hasPrefix(prefix),
              let identifier = UUID(uuidString: String(record.directory.dropFirst(prefix.count))),
              record.directory == prefix + identifier.uuidString else { throw staleApprovalIssue() }
        let staging = supportDirectory.appendingPathComponent(record.directory, isDirectory: true)
        try Self.requireSafeDirectory(staging, mayBeMissing: false)
        var info = stat()
        guard lstat(staging.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              UInt64(info.st_dev) == record.device, UInt64(info.st_ino) == record.inode else { throw staleApprovalIssue() }
        return staging
    }

    private func readPending() throws -> PendingInstallation? {
        try Self.requireSafeDirectory(supportDirectory, mayBeMissing: true)
        let descriptor = open(pendingURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw staleApprovalIssue()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 16 * 1024 else { throw staleApprovalIssue() }
        let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
        guard data.count == Int(info.st_size) else { throw staleApprovalIssue() }
        return try JSONDecoder().decode(PendingInstallation.self, from: data)
    }

    private func persistPending(_ record: PendingInstallation) throws {
        _ = try stagingURL(for: record)
        try Self.requireSafeDirectory(retainedRoot(record), mayBeMissing: false)
        if let existing = try readPending(), existing.directory != record.directory { throw staleApprovalIssue() }
        let temporary = supportDirectory.appendingPathComponent(".steamcmd-pending-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw staleApprovalIssue() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: JSONEncoder().encode(record))
        try handle.synchronize()
        guard rename(temporary.path, pendingURL.path) == 0 else { throw staleApprovalIssue() }
        setPending(record)
    }

    private func retainedRoot(_ record: PendingInstallation) -> URL {
        supportDirectory.appendingPathComponent(record.directory, isDirectory: true)
            .appendingPathComponent("runtime/MacOS", isDirectory: true)
    }

    private func removeStaging(_ record: PendingInstallation) throws {
        // Never resolve a supplied path or follow a substituted staging directory during deletion.
        if let existing = try readPending(), existing.directory == record.directory {
            guard existing.device == record.device, existing.inode == record.inode,
                  unlink(pendingURL.path) == 0 else { throw staleApprovalIssue() }
        }
        if pending?.directory == record.directory { setPending(nil) }
        let staging = try stagingURL(for: record)
        try FileManager.default.removeItem(at: staging)
    }

    private func performInstall(replacingExisting: Bool, token: UUID) async throws {
        let fm = FileManager.default
        try Self.requireSafeDirectory(supportDirectory, mayBeMissing: true)
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Self.requireSafeDirectory(managedURL, mayBeMissing: true)
        if fm.fileExists(atPath: managedURL.path), !replacingExisting {
            throw SteamCMDSetupIssue(kind: .invalidSelection, detail: String(localized: "SteamCMD already exists. Confirm Reinstall SteamCMD before replacing it."))
        }
        let staging = supportDirectory.appendingPathComponent(".steamcmd-setup-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else {
            throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Could not create a private SteamCMD installation directory."))
        }
        var info = stat()
        guard lstat(staging.path, &info) == 0 else { throw staleApprovalIssue() }
        let record = PendingInstallation(directory: staging.lastPathComponent, device: UInt64(info.st_dev),
                                         inode: UInt64(info.st_ino), stage: .bootstrap, replacingExisting: replacingExisting)
        var handedOff = false
        defer { if !handedOff { try? removeStaging(record) } }
        let container = staging.appendingPathComponent("runtime", isDirectory: true)
        let runtimeRoot = container.appendingPathComponent("MacOS", isDirectory: true)
        let home = staging.appendingPathComponent("home", isDirectory: true)
        let temporary = staging.appendingPathComponent("tmp", isDirectory: true)
        for directory in [runtimeRoot, home, temporary] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                           "TMPDIR": temporary.path + "/", "TERM": "dumb", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let archive = staging.appendingPathComponent("steamcmd.tar.gz")
        state = .downloading(received: 0, expected: nil)
        let download = SteamCMDBootstrapDownload(destination: archive, configuration: sessionConfiguration) { [weak self] received, expected in
            Task { @MainActor in
                guard let self, self.generation == token, !Task.isCancelled,
                      case .downloading = self.state else { return }
                self.state = .downloading(received: received, expected: expected)
            }
        }
        try await download.start()
        try check(token)
        state = .extracting
        let listing = SteamCMDOutputBuffer(limit: 2 * 1024 * 1024)
        let listed = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-t", "-f", archive.path], workingDirectory: staging, environment: environment,
            onOutput: { listing.append($0) })
        guard listed == 0, !listing.overflowed else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive could not be listed safely."))
        }
        try Self.validateListing(listing.data)
        let sizes = SteamCMDOutputBuffer(limit: 2 * 1024 * 1024)
        var listingEnvironment = environment
        listingEnvironment["LC_ALL"] = "C"
        listingEnvironment["LANG"] = "C"
        let measured = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-t", "-v", "--numeric-owner", "-f", archive.path], workingDirectory: staging,
            environment: listingEnvironment, onOutput: { sizes.append($0) })
        guard measured == 0, !sizes.overflowed else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive's expanded size could not be checked safely."))
        }
        try Self.validateExpandedSizeListing(sizes.data)
        try check(token)
        let diagnostics = SteamCMDOutputBuffer(limit: 16 * 1024)
        let extracted = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-x", "-k", "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-fflags", "--no-xattrs", "--no-mac-metadata", "-f", archive.path, "-C", runtimeRoot.path],
            workingDirectory: staging, environment: environment, onOutput: { diagnostics.append($0) })
        guard extracted == 0 else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "SteamCMD extraction failed. \(diagnostics.text)"))
        }
        try await Self.inspectAndQuarantine(runtimeRoot, byteLimit: 256 * 1024 * 1024)
        for path in ["steamcmd", "steamcmd.sh", "crashhandler.dylib", "Frameworks/Breakpad.framework"] {
            guard fm.fileExists(atPath: runtimeRoot.appendingPathComponent(path).path) else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The official SteamCMD bootstrap is missing \(path)."))
            }
        }
        handedOff = true
        try await performRetained(record, token: token)
    }

    private func performRetained(_ initial: PendingInstallation, token: UUID) async throws {
        var record = initial
        var retain = false
        defer { if !retain { try? removeStaging(record) } }
        do {
            let staging = try stagingURL(for: record)
            let container = staging.appendingPathComponent("runtime", isDirectory: true)
            let runtimeRoot = container.appendingPathComponent("MacOS", isDirectory: true)
            try Self.requireSafeDirectory(runtimeRoot, mayBeMissing: false)
            let home = staging.appendingPathComponent("home", isDirectory: true)
            let temporary = staging.appendingPathComponent("tmp", isDirectory: true)
            try Self.requireSafeDirectory(home, mayBeMissing: false)
            try Self.requireSafeDirectory(temporary, mayBeMissing: false)
            let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                               "TMPDIR": temporary.path + "/", "TERM": "dumb", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            let diagnostics = SteamCMDOutputBuffer(limit: 16 * 1024)
            if record.stage == .bootstrap {
                try check(token)
                state = .validating
                try await runtimeProvider.validateBootstrap(at: runtimeRoot)
                try check(token)
                state = .updating
                var updateEnvironment = environment
                updateEnvironment["DYLD_FRAMEWORK_PATH"] = runtimeRoot.appendingPathComponent("Frameworks").path
                let updated = try await processRunner.run(executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [runtimeRoot.appendingPathComponent("steamcmd.sh").path, "+quit"],
                    workingDirectory: runtimeRoot, environment: updateEnvironment, onOutput: { diagnostics.append($0) })
                guard updated == 0 else {
                    throw SteamCMDSetupIssue(kind: .updateFailed, detail: String(localized: "SteamCMD update exited with status \(updated). \(diagnostics.text)"))
                }
                try check(token)
                try Self.requireSafeDirectory(runtimeRoot, mayBeMissing: false)
                // New updater bytes cross a new security boundary; retrying old approved bytes does not.
                try await Self.inspectAndQuarantine(container, byteLimit: nil)
                record.stage = .complete
                if pending != nil { try persistPending(record) }
            }
            state = .validating
            try await finishInstallation(record, staging: staging, container: container, runtimeRoot: runtimeRoot,
                                         environment: environment, diagnostics: diagnostics, token: token)
        } catch {
            if !Task.isCancelled, let issue = error as? SteamCMDSetupIssue,
               issue.kind == .securityApprovalRequired || issue.kind == .rosettaRequired {
                try check(token)
                record.needsRosetta = issue.kind == .rosettaRequired
                record.detail = issue.detail
                try persistPending(record)
                retain = true
            }
            throw error
        }
    }

    private func finishInstallation(_ record: PendingInstallation, staging: URL, container: URL, runtimeRoot: URL,
                                    environment: [String: String], diagnostics: SteamCMDOutputBuffer, token: UUID) async throws {
        let fm = FileManager.default
        try await runtimeProvider.validate(at: runtimeRoot)
        try check(token)
        let runtime = try runtimeProvider.resolve(executable: runtimeRoot.appendingPathComponent("steamcmd"))
        var smokeEnvironment = environment
        // The no-bootstrap executable needs the same private loader paths supplied by Valve's wrapper.
        smokeEnvironment["DYLD_LIBRARY_PATH"] = runtimeRoot.path
        smokeEnvironment["DYLD_FRAMEWORK_PATH"] = runtimeRoot.appendingPathComponent("Frameworks").path
        let smoke = try await processRunner.run(executable: runtime.executableURL,
            arguments: ["-inhibitbootstrap", "+quit"], workingDirectory: runtimeRoot,
            environment: smokeEnvironment, onOutput: { diagnostics.append($0) })
        guard smoke == 0 else {
            throw SteamCMDSetupIssue(kind: .updateFailed, detail: String(localized: "SteamCMD's no-login verification exited with status \(smoke). \(diagnostics.text)"))
        }
        try check(token)
        try await runtimeProvider.validate(at: runtimeRoot)
        // No suspension from the cancellation check through the publication/selection update.
        try check(token)
        state = .committing
        try Self.requireSafeDirectory(managedURL, mayBeMissing: true)
        if fm.fileExists(atPath: managedURL.path) {
            guard record.replacingExisting else {
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Another SteamCMD installation appeared. Confirm replacement and retry."))
            }
            let backupName = ".steamcmd-backup-\(UUID().uuidString)"
            let backup = supportDirectory.appendingPathComponent(backupName, isDirectory: true)
            do {
                _ = try fm.replaceItemAt(managedURL, withItemAt: container, backupItemName: backupName, options: .withoutDeletingBackupItem)
            } catch {
                if fm.fileExists(atPath: backup.path) {
                    do {
                        if fm.fileExists(atPath: managedURL.path) {
                            // Preserve the uncertain replacement inside our staging before restoring the old directory.
                            try fm.moveItem(at: managedURL, to: staging.appendingPathComponent("failed-publication"))
                        }
                        try fm.moveItem(at: backup, to: managedURL)
                    } catch {
                        throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "SteamCMD replacement and recovery failed. The previous installation backup is at \(backup.path). \(error.localizedDescription)"))
                    }
                }
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "SteamCMD could not be replaced. \(error.localizedDescription)"))
            }
            try? fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: container, to: managedURL)
        }
        let installedRoot = managedURL.appendingPathComponent("MacOS", isDirectory: true)
        let installed = SteamCMDRuntime(rootURL: installedRoot, executableURL: installedRoot.appendingPathComponent("steamcmd"))
        defaults.set(installed.executableURL.path, forKey: Self.preferenceKey)
        selectedRuntime = installed
        state = .ready
    }

    private static func requireSafeDirectory(_ url: URL, mayBeMissing: Bool) throws {
        // Do not use standardizedFileURL here: Foundation can rewrite /private/var
        // to the /var symlink after the trusted system alias was normalized in init.
        var current = url.path
        guard url.isFileURL, current.hasPrefix("/"),
              !current.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Unsafe installation directory: \(current)"))
        }
        while current != "/" {
            var info = stat()
            if lstat(current, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Unsafe installation directory: \(current)"))
                }
            } else if errno != ENOENT || !mayBeMissing {
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Cannot access installation directory: \(current)"))
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func validateListing(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive listing is empty or unreadable."))
        }
        for entry in text.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."),
                  !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !entry.contains("\\") else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an unsafe path."))
            }
        }
    }

    private static func validateExpandedSizeListing(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive's size listing is unreadable."))
        }
        var total: Int64 = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            // macOS bsdtar under LC_ALL=C and --numeric-owner prints:
            // permissions links uid gid size month day time-or-year pathname.
            // Reject unknown output instead of interpreting warnings or another format as zero bytes.
            let fields = line.split(maxSplits: 8, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 9, let kind = fields[0].first, "-dl".contains(kind),
                  UInt64(fields[1]) != nil, UInt64(fields[2]) != nil, UInt64(fields[3]) != nil,
                  !fields[4].isEmpty, fields[4].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let size = Int64(fields[4]), size >= 0 else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an unparseable size or unsupported entry."))
            }
            if kind == "-" {
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= 256 * 1024 * 1024 else {
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The expanded SteamCMD archive exceeds 256 MiB."))
                }
                total = sum
            }
        }
    }

    private static func inspectAndQuarantine(_ root: URL, byteLimit: Int64?) async throws {
        let inspection = Task.detached(priority: .utility) {
            try inspectAndQuarantineFiles(root, byteLimit: byteLimit)
        }
        try await withTaskCancellationHandler {
            try await inspection.value
            try Task.checkCancellation()
        } onCancel: {
            inspection.cancel()
        }
    }

    private nonisolated static func inspectAndQuarantineFiles(_ root: URL, byteLimit: Int64?) throws {
        let fm = FileManager.default
        var total: Int64 = 0
        let canonicalRoot = resolvedPath(root) + "/"
        let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));MacWallpaperEngine;\(UUID().uuidString)"
        func walk(_ directory: URL) throws {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(file.path, &info) == 0 else {
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Cannot inspect extracted SteamCMD file."))
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard chmod(file.path, info.st_mode & 0o777) == 0 else { throw issue(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                    try walk(file)
                case S_IFREG:
                    guard info.st_nlink == 1 else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Hard-linked SteamCMD files are not allowed."))
                    }
                    let (sum, overflow) = total.addingReportingOverflow(Int64(info.st_size))
                    guard !overflow, byteLimit.map({ sum <= $0 }) ?? true else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The expanded SteamCMD archive exceeds 256 MiB."))
                    }
                    total = sum
                    guard chmod(file.path, info.st_mode & 0o777) == 0 else { throw issue(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                    let marked = quarantine.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
                    guard marked == 0 else {
                        throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Cannot preserve downloaded-file security metadata: \(file.lastPathComponent)."))
                    }
                case S_IFLNK:
                    let target = try fm.destinationOfSymbolicLink(atPath: file.path)
                    // Valve's updater adds a Contents-style sibling: runtime/Frameworks -> MacOS/Frameworks.
                    // Accept any relative link that resolves inside this tree; reject absolute, dangling, or escaping ones.
                    let resolved = resolvedPath(file)
                    guard !target.hasPrefix("/"), !target.isEmpty,
                          !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          resolved.hasPrefix(canonicalRoot), fm.fileExists(atPath: resolved) else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an external or unresolved symbolic link."))
                    }
                    // Foundation can leave a cyclic path unresolved; require a real final non-link object.
                    var targetInfo = stat()
                    guard lstat(resolved, &targetInfo) == 0, targetInfo.st_mode & S_IFMT != S_IFLNK else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains a cyclic symbolic link."))
                    }
                default:
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Special files are not allowed in SteamCMD archives."))
                }
            }
        }
        try walk(root)
    }

    /// POSIX realpath keeps /var and /tmp identities stable when checking link containment.
    private nonisolated static func resolvedPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.resolvingSymlinksInPath().path
    }

    private nonisolated static func issue(_ error: Error) -> SteamCMDSetupIssue {
        (error as? SteamCMDSetupIssue) ?? SteamCMDSetupIssue(kind: .fileSystem, detail: error.localizedDescription)
    }
}

private final class SteamCMDOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.withLock {
            if storage.count + data.count > limit { exceeded = true }
            storage.append(data)
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
        }
    }
    var data: Data { lock.withLock { storage } }
    var text: String { String(decoding: data, as: UTF8.self) }
    var overflowed: Bool { lock.withLock { exceeded } }
}

/// Serial URLSession delegate streams bounded chunks to a private disk file, never an in-memory archive.
private final class SteamCMDBootstrapDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let source = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    private static let maximum: Int64 = 64 * 1024 * 1024
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    // Remaining state is confined to the serial delegate queue, established before task.resume().
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?

    init(destination: URL, configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    self.continuation = continuation
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.timeoutIntervalForRequest = 300
                    configuration.timeoutIntervalForResource = 1800
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: Self.source)
                    lock.withLock {
                        self.task = task
                        task.resume()
                        if cancelled { task.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == Self.source.host,
              request.url?.port == nil || request.url?.port == 443 else {
            failure = SteamCMDSetupIssue(kind: .network, detail: String(localized: "SteamCMD download redirected outside the official HTTPS host."))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == Self.source.host else {
            failure = SteamCMDSetupIssue(kind: .network, detail: String(localized: "The official SteamCMD server did not return HTTP 200."))
            completionHandler(.cancel)
            return
        }
        expected = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        if let expected, expected > Self.maximum {
            failure = SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD bootstrap exceeds 64 MiB."))
            completionHandler(.cancel)
            return
        }
        progress(0, expected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= Self.maximum - received else {
            failure = SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD bootstrap exceeds 64 MiB."))
            dataTask.cancel()
            return
        }
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            progress(received, expected)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.close() } catch { if failure == nil { failure = error } }
        file = nil
        let wasCancelled = lock.withLock { self.task = nil; return cancelled }
        let completion = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let failure { completion?.resume(throwing: failure) }
        else if let error {
            completion?.resume(throwing: SteamCMDSetupIssue(kind: (error as? URLError)?.code == .timedOut ? .timedOut : .network, detail: error.localizedDescription))
        } else if received == 0 || expected.map({ $0 != received }) == true {
            completion?.resume(throwing: SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD bootstrap download is empty or truncated.")))
        } else { completion?.resume() }
    }
}
