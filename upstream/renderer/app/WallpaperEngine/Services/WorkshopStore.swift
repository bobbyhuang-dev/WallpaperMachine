import Foundation
import Observation

struct WorkshopQuery: Equatable, Sendable {
    let text: String
    let kind: WorkshopKind
    let sort: WorkshopSort
}

struct WorkshopRequest: Equatable, Sendable {
    let query: WorkshopQuery
    let page: Int
}

@MainActor
@Observable
final class WorkshopStore {
    var searchText = ""
    var kind: WorkshopKind = .scene
    var sort: WorkshopSort = .trending
    var selectedItem: WorkshopItem?
    private(set) var sceneAssetsReady = ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL)

    func refreshSceneAssetsReadiness() {
        sceneAssetsReady = ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL)
    }
    private(set) var items: [WorkshopItem] = []
    private(set) var page = 1
    private(set) var totalPages = 1
    private(set) var totalCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?
    let downloader: WorkshopDownloadManager
    let steamCMDSetup: SteamCMDSetupStore
    @ObservationIgnored private let service: WorkshopService
    var username = ""
    var ownsWallpaperEngine = false
    var selectedDownloadID: String?
    var showsDownloadDetails = false
    private(set) var downloadErrorMessage: String?

    var hasDownloadActivity: Bool { !downloader.downloads.isEmpty }
    var selectedDownload: WorkshopDownload? {
        downloader.downloads.first { $0.id == selectedDownloadID }
            ?? downloader.downloads.first { $0.isPending }
            ?? downloader.downloads.last
    }

    convenience init(service: WorkshopService = WorkshopService()) {
        self.init(service: service, downloader: WorkshopDownloadManager())
    }

    init(service: WorkshopService = WorkshopService(), downloader: WorkshopDownloadManager,
         supportDirectory: URL = ClientPaths.supportURL, defaults: UserDefaults = .standard) {
        self.service = service
        self.downloader = downloader
        self.steamCMDSetup = SteamCMDSetupStore(downloader: downloader, supportDirectory: supportDirectory, defaults: defaults)
    }

    func showDownload(_ job: WorkshopDownload) {
        guard downloader.downloads.contains(where: { $0 === job }) else { return }
        selectedDownloadID = job.id
        showsDownloadDetails = true
    }

    func startDownload(item: WorkshopItem?, username: String, rememberSession: Bool, bridge: BridgeStore) {
        if let job = downloader.download(for: item?.id), job.isPending {
            showDownload(job)
            return
        }
        guard !steamCMDSetup.isBusy else {
            downloadErrorMessage = String(localized: "Wait for SteamCMD setup to finish before downloading.")
            return
        }
        guard let runtime = steamCMDSetup.selectedRuntime else {
            downloadErrorMessage = String(localized: "Install SteamCMD or locate an existing installation before downloading.")
            return
        }
        let account = Self.normalizedAccount(username)
        let saved = rememberSession && downloader.savedAccount.map { Self.normalizedAccount($0) == account } == true
        guard !account.isEmpty, ownsWallpaperEngine || saved else {
            downloadErrorMessage = String(localized: "Enter your Steam account login name and confirm that it owns Wallpaper Engine.")
            return
        }
        downloadErrorMessage = nil
        if let item {
            downloader.start(item: item, username: username, executable: runtime.executableURL,
                             library: ClientPaths.libraryURL, rememberSession: rememberSession) {
                try await bridge.refreshLibraryAsync()
            }
        } else {
            let destination = ClientPaths.managedAssetsURL
            downloader.installAssets(username: username, executable: runtime.executableURL,
                                     destination: destination, rememberSession: rememberSession) {
                try ClientPaths.configureAssetsFolder(at: destination)
                self.refreshSceneAssetsReadiness()
            }
        }
        if downloader.errorMessage == nil, let job = downloader.download(for: item?.id) {
            selectedDownloadID = job.id
        }
    }

    func clearDownloadActivity() {
        downloader.clearCompleted()
        if !downloader.downloads.contains(where: { $0.id == selectedDownloadID }) { selectedDownloadID = nil }
        downloadErrorMessage = nil
        if !hasDownloadActivity { showsDownloadDetails = false }
    }

    static func normalizedAccount(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private(set) var committedQuery: WorkshopQuery?
    private(set) var failedRequest: WorkshopRequest?

    private var draftQuery: WorkshopQuery {
        WorkshopQuery(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, sort: sort)
    }

    var browseURL: URL {
        let query = committedQuery ?? draftQuery
        return WorkshopService.browseURL(search: query.text, kind: query.kind, sort: query.sort, page: page)
    }

    func search() { load(WorkshopRequest(query: draftQuery, page: 1)) }

    func loadPage(_ page: Int) {
        guard let committedQuery, page >= 1, page <= totalPages else { return }
        load(WorkshopRequest(query: committedQuery, page: page))
    }

    func retrySearch() {
        guard let failedRequest else { return }
        load(failedRequest)
    }

    private func load(_ request: WorkshopRequest) {
        searchTask?.cancel()
        let requestID = UUID()
        generation = requestID
        isLoading = true
        errorMessage = nil
        searchTask = Task {
            do {
                let result = try await service.browse(search: request.query.text, kind: request.query.kind,
                                                      sort: request.query.sort, page: request.page)
                guard generation == requestID, !Task.isCancelled else { return }
                items = result.items
                page = result.page
                totalPages = result.totalPages
                totalCount = result.totalCount
                hasLoaded = true
                committedQuery = request.query
                failedRequest = nil
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                failedRequest = request
            }
            if generation == requestID { isLoading = false }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        generation = UUID()
        isLoading = false
    }

}
