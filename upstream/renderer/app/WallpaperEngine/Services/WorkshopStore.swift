import Foundation
import Observation

@MainActor
@Observable
final class WorkshopStore {
    var searchText = ""
    var kind: WorkshopKind = .scene
    var sort: WorkshopSort = .trending
    private(set) var items: [WorkshopItem] = []
    private(set) var page = 1
    private(set) var totalPages = 1
    private(set) var totalCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?
    var applyMessage: String?
    private(set) var applyingID: String?
    let downloader = WorkshopDownloader()
    @ObservationIgnored private let service = WorkshopService()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var browseURL: URL { WorkshopService.browseURL(search: searchText, kind: kind, sort: sort, page: page) }

    func search(page requestedPage: Int = 1) {
        searchTask?.cancel()
        let requestID = UUID()
        generation = requestID
        isLoading = true
        errorMessage = nil
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind
        let sort = sort
        searchTask = Task {
            do {
                let result = try await service.browse(search: search, kind: kind, sort: sort, page: requestedPage)
                guard generation == requestID, !Task.isCancelled else { return }
                items = result.items
                page = result.page
                totalPages = result.totalPages
                totalCount = result.totalCount
                hasLoaded = true
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            if generation == requestID { isLoading = false }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        generation = UUID()
        isLoading = false
    }

    func apply(id: String, bridge: BridgeStore) {
        guard applyingID == nil else { return }
        applyingID = id
        applyMessage = nil
        errorMessage = nil
        Task {
            defer { applyingID = nil }
            do {
                try await bridge.refreshLibraryAsync()
                try await bridge.selectWallpaperAsync(id: id)
                guard let options = bridge.wallpaperOptionsSnapshot, options.wallpaperId == id, options.supported else {
                    throw WorkshopFailure(message: "This wallpaper is downloaded, but its type is not supported by the current renderer. Choose a Scene wallpaper or review it in Library.")
                }
                guard options.displayConfigurations.contains(where: { $0.displayId == "primary" }) else {
                    throw WorkshopFailure(message: "No primary display configuration is available. Refresh displays in Settings and retry.")
                }
                try await bridge.setDisplayConfigEnabledAsync(wallpaperId: id, displayId: "primary", enabled: true)
                try await bridge.applyWallpaperOptionsAsync(wallpaperId: id)
                applyMessage = "Applied to your primary display"
            } catch { errorMessage = "Could not apply wallpaper: \(error.localizedDescription)" }
        }
    }
}
