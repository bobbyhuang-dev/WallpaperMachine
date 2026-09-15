import Foundation
import Observation

struct WorkshopQuery: Equatable, Sendable {
  let text: String
  let kind: WorkshopKind
  let sort: WorkshopSort
  var tags: [String] = []
}

struct WorkshopRequest: Equatable, Sendable {
  let query: WorkshopQuery
  let page: Int
}

/// Prerequisites are resolved in this order; a request reports the first one it still needs.
enum WorkshopDownloadStage: String, Sendable {
  case setup, account, resources, ready
}

/// A retained download intent. One click keeps the wallpaper the user asked for while
/// the runtime, the Steam account, and shared scene assets are resolved in turn.
struct WorkshopDownloadRequest: Identifiable, Sendable {
  /// Workshop item id, or `WorkshopStore.sceneAssetsRequestID` for the shared assets download.
  let id: String
  let item: WorkshopItem?
  var account: String
  var rememberSession: Bool
  /// Explicit consent to download Wallpaper Engine's multi-gigabyte shared assets.
  var includesResources: Bool
  /// The downloader rejected these inputs; only a fresh continuation may retry them, so
  /// automatic resumption cannot spin on the same rejected account.
  var refused = false
}

@MainActor
@Observable
final class WorkshopStore {
  var searchText = ""
  var kind: WorkshopKind = .scene
  var sort: WorkshopSort = .trending
  var tags: [String] = []
  var selectedItem: WorkshopItem?
  private(set) var sceneAssetsReady: Bool
  @ObservationIgnored private let sceneAssetsAvailable: @MainActor () -> Bool

  func refreshSceneAssetsReadiness() {
    sceneAssetsReady = sceneAssetsAvailable()
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
  var selectedDownloadID: String?
  var showsDownloadDetails = false
  private(set) var downloadRequests: [WorkshopDownloadRequest] = []

  static let sceneAssetsRequestID = "scene-assets"

  var hasDownloadActivity: Bool { !downloader.downloads.isEmpty || !downloadRequests.isEmpty }
  var selectedDownload: WorkshopDownload? {
    downloader.downloads.first { $0.id == selectedDownloadID }
      ?? downloader.downloads.first { $0.isPending }
      ?? downloader.downloads.last
  }

  /// A finished wallpaper download stays valid even when the shared assets job fails, so the
  /// missing scene readiness needs its own standing warning instead of a transient job error.
  var sceneAssetsFailure: String? {
    guard !sceneAssetsReady, let job = downloader.download(for: nil), !job.isPending else {
      return nil
    }
    if job.isCancelled {
      return String(
        localized: "Shared scene assets were not installed, so scene wallpapers cannot play yet.")
    }
    return job.worker.errorMessage.map {
      String(
        localized:
          "Shared scene assets are still missing, so scene wallpapers cannot play yet: \($0)")
    }
  }

  convenience init(service: WorkshopService = WorkshopService()) {
    self.init(service: service, downloader: WorkshopDownloadManager())
  }

  init(
    service: WorkshopService = WorkshopService(), downloader: WorkshopDownloadManager,
    supportDirectory: URL = ClientPaths.supportURL, defaults: UserDefaults = .standard,
    runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
    sceneAssetsAvailable: @escaping @MainActor () -> Bool = {
      ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL)
    }
  ) {
    self.service = service
    self.downloader = downloader
    self.sceneAssetsAvailable = sceneAssetsAvailable
    sceneAssetsReady = sceneAssetsAvailable()
    self.steamCMDSetup = SteamCMDSetupStore(
      downloader: downloader, supportDirectory: supportDirectory,
      defaults: defaults, runtimeProvider: runtimeProvider)
  }

  func showDownload(_ job: WorkshopDownload) {
    guard downloader.downloads.contains(where: { $0 === job }) else { return }
    selectedDownloadID = job.id
    showsDownloadDetails = true
  }

  /// The entry point for a single click: start immediately when every prerequisite is met,
  /// otherwise retain the intent and report which prerequisite it is waiting on.
  func requestDownload(item: WorkshopItem?, rememberSession: Bool, bridge: BridgeStore) {
    let id = item?.id ?? Self.sceneAssetsRequestID
    if let job = downloader.download(for: item?.id), job.isPending {
      showDownload(job)
      return
    }
    let existing = downloadRequests.first { $0.id == id }
    let retained = existing?.account ?? ""
    resolve(
      WorkshopDownloadRequest(
        id: id, item: item ?? existing?.item,
        account: retained.isEmpty ? suggestedAccount : retained,
        // A retained request keeps the choice it was continued with.
        rememberSession: existing?.rememberSession ?? rememberSession,
        includesResources: existing?.includesResources ?? false),
      bridge: bridge)
  }

  /// Supplies the account and the consent a retained request is waiting on, then resumes it.
  /// Returns `false` when the id names neither a retained request nor a known Workshop item.
  @discardableResult
  func continueDownload(
    id: String, account: String, rememberSession: Bool,
    includeResources: Bool, bridge: BridgeStore
  ) -> Bool {
    let existing = downloadRequests.first { $0.id == id }
    let item = id == Self.sceneAssetsRequestID ? nil : existing?.item ?? workshopItem(id: id)
    guard id == Self.sceneAssetsRequestID || item != nil else { return false }
    username = account
    resolve(
      WorkshopDownloadRequest(
        id: id, item: item, account: account,
        rememberSession: rememberSession,
        includesResources: existing?.includesResources == true || includeResources),
      bridge: bridge)
    return true
  }

  func removeDownloadRequest(id: String) {
    downloadRequests.removeAll { $0.id == id }
  }

  /// "Change account" stops exactly this job and keeps its wallpaper as an intent with no
  /// account, so nothing signs in again under the name the user rejected. Consent already
  /// given for shared assets is preserved; other queued jobs are untouched.
  func changeDownloadAccount(id: String) async {
    guard let job = downloader.downloads.first(where: { $0.id == id }) else { return }
    let item = job.item
    let rememberSession = downloader.rememberSessionWhileRunning ?? true
    downloader.cancel(job)
    await job.worker.shutdown()
    // The rejected name must not survive as the suggestion for this or any new intent.
    if Self.normalizedAccount(username) == Self.normalizedAccount(job.account) { username = "" }
    upsert(
      WorkshopDownloadRequest(
        id: id, item: item, account: "",
        rememberSession: rememberSession, includesResources: true,
        refused: true))
  }

  /// Driven by the control panel's observation loop: prerequisites change outside any user
  /// action, so a request that becomes startable continues without a second click.
  func resumeDownloadRequests(bridge: BridgeStore) {
    for request in downloadRequests {
      var request = request
      let suggestion = suggestedAccount
      // A rejected account must not be refilled from the saved or typed suggestion.
      if !request.refused, request.account.isEmpty, !suggestion.isEmpty {
        request.account = suggestion
        upsert(request)
      }
      if stage(for: request) == .ready { resolve(request, bridge: bridge) }
    }
  }

  func stage(for request: WorkshopDownloadRequest) -> WorkshopDownloadStage {
    if steamCMDSetup.isBusy || steamCMDSetup.selectedRuntime == nil { return .setup }
    if request.refused || Self.normalizedAccount(request.account).isEmpty { return .account }
    if !request.includesResources, needsResources(request) { return .resources }
    return .ready
  }

  /// Resolves an item id against browsing results, the retained selection, retained requests,
  /// and running jobs, so an intent survives searching and paging away from the item.
  func workshopItem(id: String) -> WorkshopItem? {
    if let item = items.first(where: { $0.id == id }) { return item }
    if let selectedItem, selectedItem.id == id { return selectedItem }
    if let item = downloadRequests.first(where: { $0.id == id })?.item { return item }
    return downloader.downloads.first { $0.item?.id == id }?.item
  }

  /// A running session pins the account every queued job reuses; a name typed elsewhere must
  /// not seed an intent that would sign in as somebody else.
  var suggestedAccount: String {
    if let active = downloader.downloads.last(where: { $0.isPending })?.account { return active }
    let typed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? downloader.savedAccount ?? "" : typed
  }

  private var sharedAssetsPending: Bool { downloader.download(for: nil)?.isPending == true }

  /// Downloading Wallpaper Engine's shared assets is always an explicit choice, even when a
  /// copy is already installed. A scene only needs that consent while the assets are missing
  /// and no shared job is already running for it to ride.
  private func needsResources(_ request: WorkshopDownloadRequest) -> Bool {
    guard let item = request.item else { return true }
    return item.kind == .scene && !sceneAssetsReady && !sharedAssetsPending
  }

  private func needsSharedAssets(_ item: WorkshopItem) -> Bool {
    item.kind == .scene && !sceneAssetsReady
  }

  private func upsert(_ request: WorkshopDownloadRequest) {
    if let index = downloadRequests.firstIndex(where: { $0.id == request.id }) {
      downloadRequests[index] = request
    } else {
      downloadRequests.append(request)
    }
  }

  private func resolve(_ request: WorkshopDownloadRequest, bridge: BridgeStore) {
    guard stage(for: request) == .ready, let runtime = steamCMDSetup.selectedRuntime else {
      upsert(request)
      return
    }
    downloadRequests.removeAll { $0.id == request.id }
    if let item = request.item {
      // Shared assets are queued first and only once: other scenes ride the same job.
      if needsSharedAssets(item), !sharedAssetsPending {
        installAssets(request, runtime: runtime)
      }
      downloader.start(
        item: item, username: request.account, executable: runtime.executableURL,
        library: ClientPaths.libraryURL, rememberSession: request.rememberSession
      ) {
        try await bridge.refreshLibraryAsync()
      }
    } else {
      installAssets(request, runtime: runtime)
    }
    if let job = downloader.download(for: request.item?.id), job.isPending {
      selectedDownloadID = job.id
    } else if downloader.errorMessage != nil {
      // The downloader refused the inputs; keep the intent so the user can correct them.
      var refused = request
      refused.refused = true
      upsert(refused)
    }
  }

  private func installAssets(_ request: WorkshopDownloadRequest, runtime: SteamCMDRuntime) {
    let destination = ClientPaths.managedAssetsURL
    downloader.installAssets(
      username: request.account, executable: runtime.executableURL,
      destination: destination, rememberSession: request.rememberSession
    ) {
      try ClientPaths.configureAssetsFolder(at: destination)
      self.refreshSceneAssetsReadiness()
    }
  }

  func clearDownloadActivity() {
    downloader.clearCompleted()
    if !downloader.downloads.contains(where: { $0.id == selectedDownloadID }) {
      selectedDownloadID = nil
    }
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
    WorkshopQuery(
      text: searchText.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, sort: sort,
      tags: tags)
  }

  var browseURL: URL {
    let query = committedQuery ?? draftQuery
    return WorkshopService.browseURL(
      search: query.text, kind: query.kind, sort: query.sort, page: page, tags: query.tags)
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
        let result = try await service.browse(
          search: request.query.text, kind: request.query.kind,
          sort: request.query.sort, page: request.page, tags: request.query.tags)
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
