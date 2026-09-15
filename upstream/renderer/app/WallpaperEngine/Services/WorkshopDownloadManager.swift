import Foundation
import Observation

@MainActor
@Observable
final class WorkshopDownload: Identifiable {
    let id: String
    let item: WorkshopItem?
    let account: String
    let worker: WorkshopDownloader
    fileprivate(set) var isQueued = true
    fileprivate var occupiesSlot = false
    fileprivate var wasCancelled = false
    fileprivate let rememberSession: Bool
    @ObservationIgnored fileprivate var begin: (() -> Void)?

    var isPending: Bool { isQueued || occupiesSlot }
    var status: String {
        if isQueued { return "Queued — waiting for a download slot" }
        if wasCancelled { return "Download cancelled" }
        return worker.status
    }
    var progress: Double? { isQueued ? nil : worker.progress }

    fileprivate init(item: WorkshopItem?, account: String, rememberSession: Bool, sessionDirectory: URL) {
        id = item?.id ?? "scene-assets"
        self.item = item
        self.account = account
        self.rememberSession = rememberSession
        worker = WorkshopDownloader(sessionDirectory: sessionDirectory)
    }
}

/// Owns independent SteamCMD terminals and bounds disk/network contention.
@MainActor
@Observable
final class WorkshopDownloadManager {
    private(set) var downloads: [WorkshopDownload] = []
    private(set) var savedAccount: String?
    private(set) var errorMessage: String?
    let maximumConcurrentDownloads: Int
    @ObservationIgnored private let sessionDirectory: URL
    @ObservationIgnored private var isShuttingDown = false

    var activeCount: Int { downloads.lazy.filter { $0.occupiesSlot }.count }
    var queuedCount: Int { downloads.lazy.filter { $0.isQueued }.count }
    var isRunning: Bool { downloads.contains { $0.isPending } }
    var suggestedAccount: String? { downloads.last(where: { $0.isPending })?.account ?? savedAccount }
    var rememberSessionWhileRunning: Bool? { downloads.first(where: { $0.isPending })?.rememberSession }

    init(sessionDirectory: URL = ClientPaths.supportURL.appendingPathComponent("SteamSession", isDirectory: true), maximumConcurrentDownloads: Int = 3) {
        self.sessionDirectory = sessionDirectory
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        savedAccount = WorkshopDownloader.readSavedAccount(at: sessionDirectory)
    }

    func download(for itemID: String?) -> WorkshopDownload? {
        downloads.first { $0.id == (itemID ?? "scene-assets") }
    }

    func start(item: WorkshopItem, username: String, executable: URL, library: URL, rememberSession: Bool = true, onImported: @escaping @MainActor () async throws -> Void) {
        enqueue(item: item, username: username, rememberSession: rememberSession) { worker, account in
            worker.start(item: item, username: account, executable: executable, library: library, rememberSession: rememberSession, onImported: onImported)
        }
    }

    func installAssets(username: String, executable: URL, destination: URL, rememberSession: Bool = true, onInstalled: @escaping @MainActor () throws -> Void) {
        enqueue(item: nil, username: username, rememberSession: rememberSession) { worker, account in
            worker.installAssets(username: account, executable: executable, destination: destination, rememberSession: rememberSession, onInstalled: onInstalled)
        }
    }

    func cancel(_ job: WorkshopDownload) {
        guard downloads.contains(where: { $0 === job }), job.isPending else { return }
        if job.isQueued {
            job.isQueued = false
            job.wasCancelled = true
            job.begin = nil
            startQueuedDownloads()
        } else {
            job.worker.cancel()
        }
    }

    func forgetSavedAccount() {
        guard !isRunning else {
            errorMessage = "Wait for active and queued downloads to finish before changing saved sign-in settings."
            return
        }
        do {
            try WorkshopDownloader.removeSession(at: sessionDirectory)
            savedAccount = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not forget the saved Steam sign-in: \(error.localizedDescription)"
        }
    }

    func shutdown() async {
        isShuttingDown = true
        // Cancel every child before awaiting any one of them. Completion must not
        // launch queued work while the app is waiting for staging cleanup.
        for job in downloads where job.isPending { cancel(job) }
        for job in downloads where job.occupiesSlot { await job.worker.shutdown() }
    }

    private func enqueue(item: WorkshopItem?, username: String, rememberSession: Bool, begin: @escaping (WorkshopDownloader, String) -> Void) {
        guard !isShuttingDown, download(for: item?.id)?.isPending != true else { return }
        guard let account = WorkshopDownloader.normalizedAccount(username) else {
            errorMessage = "Enter your Steam account login name (not your display name). An account that owns Wallpaper Engine is required."
            return
        }
        if let current = rememberSessionWhileRunning, current != rememberSession {
            errorMessage = "Wait for active and queued downloads to finish before changing saved sign-in settings."
            return
        }
        if !rememberSession && !isRunning {
            forgetSavedAccount()
            guard errorMessage == nil else { return }
        }
        errorMessage = nil
        let job = WorkshopDownload(item: item, account: account, rememberSession: rememberSession, sessionDirectory: sessionDirectory)
        job.begin = { [weak job] in
            guard let job else { return }
            begin(job.worker, account)
        }
        job.worker.onFinished = { [weak self, weak job] in
            guard let self, let job else { return }
            job.occupiesSlot = false
            self.savedAccount = WorkshopDownloader.readSavedAccount(at: self.sessionDirectory)
            self.startQueuedDownloads()
        }
        downloads.removeAll { $0.id == job.id }
        downloads.append(job)
        startQueuedDownloads()
    }

    private func startQueuedDownloads() {
        guard !isShuttingDown else { return }
        var available = maximumConcurrentDownloads - activeCount
        for job in downloads where job.isQueued {
            guard available > 0 else { break }
            job.isQueued = false
            job.occupiesSlot = true
            let begin = job.begin
            job.begin = nil
            begin?()
            if job.worker.isRunning {
                available -= 1
            } else {
                // Invalid input can fail synchronously without starting a task.
                job.occupiesSlot = false
            }
        }
    }
}
