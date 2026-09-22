import AppKit
import Combine
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The page is app-owned. WKWebView supplies the reply-capable script bridge that
/// WebPage does not expose; renderer content is never loaded into this web view.
struct WebControlPanel: NSViewRepresentable {
  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let updater: AppUpdateStore

  func makeCoordinator() -> WebPanelController {
    let controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop, updater: updater)
    // Discover previews start caching the moment Steam's page arrives, and the following page
    // is fetched behind the one on show, so neither waits for the web view to ask.
    workshop.prefetchesNextPage = true
    workshop.onPreviewsAvailable = { [cache = controller.assets.thumbnailCache] in cache.warm($0) }
    return controller
  }

  func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
  func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.scheduleUpdate() }
  static func dismantleNSView(_ view: WKWebView, coordinator: WebPanelController) {
    coordinator.stop()
  }
}

/// A `file` or `directory` property's chosen path, reduced to what the page shows.
///
/// `matches` and `truncated` describe a folder: how many files inside it the importer
/// would take, and whether it holds more than the import limit. Both are nil / false for
/// a single file, and `matches` stays nil for a folder that could not be read.
struct WebPanelPropertyAsset: Equatable {
  let path: String
  let name: String
  var matches: Int?
  var truncated = false
}

@MainActor
final class WebPanelController: NSObject, WKNavigationDelegate {
  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let updater: AppUpdateStore
  let theme: AppThemeStore
  let appLanguage: AppLanguageStore
  let displayTitles: DisplayTitleResolver
  weak var webView: WKWebView?
  let assets: WebPanelAssets
  /// BCP 47 tag of the localization the page renders in: the user's in-app choice, or the
  /// language macOS resolves for the bundle so the panel and native strings agree.
  var language: String { Self.pageLanguage(appLanguage.effective.tag) }
  var subscriptions = Set<AnyCancellable>()
  var isReady = false
  var stopped = false
  var updateTask: Task<Void, Never>?
  var updatePending = false
  var pageGeneration: UInt64 = 0
  let isPresentationVisible: (@MainActor () -> Bool)?
  var observationInstalled = false
  var commandBusy = false
  var actionError: String?
  var importTask: Task<Void, Never>?
  var importStatus = ""
  var importReport: WallpaperImportService.Report?
  var remembersSession = true
  var favoriteIDs: Set<String>
  /// Each library page (`discover`, `installed`) hides its filter sidebar when the user
  /// closes it with the toolbar's Filter button; the choice outlives the page.
  var filtersCollapsed: [String: Bool]
  /// Whether the first-run welcome has been dismissed. The page shows the welcome over
  /// the content while this is false and reports `welcomeSeen` once the user has read or
  /// skipped it, or started using the app; it is never shown again on its own.
  var welcomeSeen: Bool
  /// Folder sizes and dates for Installed's sort menu, measured off the main thread.
  let libraryMetrics: LibraryMetricsService
  let defaults: UserDefaults
  var displayOptions: [String: BridgeWallpaperOptionsSnapshot] = [:]
  var displayOptionsRevision: UInt64?
  var displayOptionsTask: Task<Void, Never>?
  var displayOptionsGeneration: UInt64 = 0
  /// Measured `file` / `directory` property paths, by wallpaper then property id.
  var propertyAssets: [String: [String: WebPanelPropertyAsset]] = [:]
  /// Why choosing or clearing a path failed, by wallpaper then property id. It belongs
  /// beside the control the user just used, not in the window-wide error banner.
  var propertyPathErrors: [String: [String: String]] = [:]
  /// Bytes the last cache purge released, or nil when none has run this session.
  /// Nil and zero are different answers — "not run" versus "nothing to release" —
  /// so the page is given the distinction rather than a substituted 0.
  var userAssetsReleasedBytes: UInt64?
  var recoveryAttempted = false
  var dismissedErrorRevision: UInt64 = 0
  var dismissedLibraryError: String?
  var dismissedDownloadError: String?
  static let favoriteKey = "WallpaperMachine.favoriteWallpaperIDs"
  /// Where each page's sidebar choice is stored; Discover keeps the key earlier builds used.
  static let filtersCollapsedKeys = [
    "discover": "WallpaperMachine.workshopFiltersCollapsed",
    "installed": "WallpaperMachine.installedFiltersCollapsed",
  ]
  static let welcomeSeenKey = "WallpaperMachine.welcomeSeen"
  /// Earlier builds stored a dragged inspector width here; the width now follows the
  /// window alone, so the key is cleared rather than read.
  static let legacyInspectorWidthKey = "WallpaperMachine.inspectorWidth"

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    updater: AppUpdateStore? = nil,
    isPresentationVisible: (@MainActor () -> Bool)? = nil,
    theme: AppThemeStore? = nil,
    displayTitles: DisplayTitleResolver = .system,
    defaults: UserDefaults = .standard,
    libraryMetrics: LibraryMetricsService? = nil,
    assets: WebPanelAssets? = nil,
    appLanguage: AppLanguageStore? = nil
  ) {
    self.store = store
    self.assets = assets ?? WebPanelAssets()
    self.appLanguage = appLanguage ?? .shared
    self.navigation = navigation
    self.workshop = workshop
    self.updater =
      updater ?? AppUpdateStore(currentVersion: "0.0.0", client: DisabledAppUpdateClient())
    self.displayTitles = displayTitles
    self.isPresentationVisible = isPresentationVisible
    self.theme = theme ?? .shared
    self.defaults = defaults
    filtersCollapsed = Self.filtersCollapsedKeys.mapValues { defaults.bool(forKey: $0) }
    welcomeSeen = defaults.bool(forKey: Self.welcomeSeenKey)
    self.libraryMetrics = libraryMetrics ?? LibraryMetricsService()
    defaults.removeObject(forKey: Self.legacyInspectorWidthKey)
    favoriteIDs = Set(
      (try? JSONDecoder().decode(
        [String].self, from: UserDefaults.standard.data(forKey: Self.favoriteKey) ?? Data())) ?? [])
    super.init()
    self.libraryMetrics.onChange = { [weak self] in self?.scheduleUpdate() }
  }

  func makeWebView() -> WKWebView {
    let content = WKUserContentController()
    content.addScriptMessageHandler(
      WebPanelMessageProxy(owner: self), contentWorld: .page, name: "native")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = content
    configuration.setURLSchemeHandler(assets, forURLScheme: "mwe-ui")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.underPageBackgroundColor = .windowBackgroundColor
    view.allowsBackForwardNavigationGestures = false
    #if DEBUG
      view.isInspectable = true
    #endif
    webView = view
    theme.$preferences.sink { [weak self] preferences in
      self?.applyTheme(preferences)
    }.store(in: &subscriptions)
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
    ] {
      NotificationCenter.default.publisher(for: name)
        .sink { [weak self] note in
          MainActor.assumeIsolated {
            guard let self, let window = note.object as? NSWindow,
              window === self.webView?.window
            else { return }
            self.scheduleUpdate()
          }
        }
        .store(in: &subscriptions)
    }
    navigation.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.scheduleUpdate() }
    }.store(in: &subscriptions)
    view.load(URLRequest(url: WebPanelAssets.indexURL))
    observeState()
    return view
  }

  /// This is the panel's only user script. It is replaced whenever the theme or language
  /// changes so every reload, including WebContent recovery, starts with the latest saved
  /// choices before first paint.
  func installUserScript(theme preferences: AppThemePreferences? = nil) {
    guard let view = webView else { return }
    // `$preferences` publishes before the store's value changes, so the sink passes its own.
    let preferences = preferences ?? theme.preferences
    let content = view.configuration.userContentController
    content.removeAllUserScripts()
    // Mode/tone/icon are closed enums, accent is validated as six hexadecimal digits and the
    // language tag is reduced to letters, digits and hyphens by pageLanguage.
    content.addUserScript(
      WKUserScript(
        source:
          "window.__appTheme = {mode:'\(preferences.mode.rawValue)',accent:'\(preferences.accent)',tone:'\(preferences.tone.rawValue)',icon:'\(preferences.icon.rawValue)'};window.__appLanguage='\(language)';",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }

  private func applyTheme(_ preferences: AppThemePreferences) {
    guard let view = webView else { return }
    view.appearance = preferences.mode.appearance
    installUserScript(theme: preferences)
    guard isReady, !stopped else { return }
    Task { @MainActor [weak self, weak view] in
      guard let self, !self.stopped, let view else { return }
      do {
        _ = try await view.callAsyncJavaScript(
          "window.appTheme?.apply(theme)", arguments: ["theme": self.theme.preferences.snapshot],
          in: nil, contentWorld: .page)
      } catch {
        self.actionError = String(
          localized: "The appearance could not update: \(error.localizedDescription)")
      }
      self.scheduleUpdate()
    }
  }

  /// A tag safe to splice into the user script; anything else falls back to English.
  static func pageLanguage(_ tag: String?) -> String {
    guard let tag, !tag.isEmpty,
      tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    else { return "en" }
    return tag
  }

  func stop() {
    stopped = true
    pageGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    updatePending = false
    cancelDisplayOptions()
    subscriptions.removeAll()
    importTask?.cancel()
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: "native", contentWorld: .page)
    webView?.navigationDelegate = nil
    webView?.stopLoading()
  }

  func observeState() {
    guard !stopped, !observationInstalled else { return }
    observationInstalled = true
    withObservationTracking {
      trackSnapshotDependencies()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observationInstalled = false
        self.scheduleUpdate()
        self.observeState()
      }
    }
  }

  func presentationAllowsUpdates() -> Bool {
    if let isPresentationVisible { return isPresentationVisible() }
    guard let window = webView?.window else { return false }
    return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
  }

  private var needsDisplayOptions: Bool {
    switch navigation.selection {
    case .settings, .display: true
    default: false
    }
  }

  func scheduleUpdate() {
    guard !stopped else { return }
    updatePending = true
    // Native continuation must not wait for an in-flight page Promise.
    workshop.resumeDownloadRequests(bridge: store)
    reconcileDismissedErrors()
    if !presentationAllowsUpdates() || !needsDisplayOptions
      || displayOptionsRevision != store.snapshotRevision
    {
      cancelDisplayOptions()
    }
    guard updateTask == nil else { return }
    let generation = pageGeneration
    updateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pageGeneration == generation { self.updateTask = nil }
      }
      while self.updatePending && !Task.isCancelled && self.pageGeneration == generation {
        guard !self.stopped, self.isReady, let view = self.webView,
          self.presentationAllowsUpdates()
        else {
          self.cancelDisplayOptions()
          return
        }
        self.refreshDisplayOptions()
        self.updatePending = false
        let state = self.snapshot()
        do {
          _ = try await view.callAsyncJavaScript(
            "return window.wallpaperUI.receive(state)", arguments: ["state": state], in: nil,
            contentWorld: .page)
        } catch {
          guard !Task.isCancelled, self.pageGeneration == generation else { return }
          self.actionError = String(
            localized: "The interface could not update: \(error.localizedDescription)")
          self.updatePending = true
          return
        }
      }
    }
  }

  private func cancelDisplayOptions() {
    displayOptionsGeneration &+= 1
    displayOptionsTask?.cancel()
    displayOptionsTask = nil
    displayOptionsRevision = nil
    displayOptions.removeAll(keepingCapacity: true)
  }

  func refreshDisplayOptions() {
    guard !stopped, presentationAllowsUpdates(), needsDisplayOptions else {
      cancelDisplayOptions()
      return
    }
    let revision = store.snapshotRevision
    guard displayOptionsRevision != revision else { return }
    cancelDisplayOptions()
    displayOptionsRevision = revision
    var ids = Set<String>()
    for row in store.monitorInformationSnapshot.rows
    where row.mirrorTargetDisplayId == nil && !row.wallpaperId.isEmpty
      && row.wallpaperId != store.wallpaperOptionsSnapshot?.wallpaperId
    {
      ids.insert(row.wallpaperId)
    }
    guard !ids.isEmpty else { return }
    let generation = displayOptionsGeneration
    displayOptionsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.displayOptionsGeneration == generation { self.displayOptionsTask = nil }
      }
      var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
      for id in ids {
        guard !Task.isCancelled, !self.stopped, self.displayOptionsGeneration == generation,
          self.store.snapshotRevision == revision, self.presentationAllowsUpdates(),
          self.needsDisplayOptions
        else { return }
        let value = try? await self.store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
        guard !Task.isCancelled, !self.stopped, self.displayOptionsGeneration == generation,
          self.store.snapshotRevision == revision, self.presentationAllowsUpdates(),
          self.needsDisplayOptions
        else { return }
        if let value { options[id] = value }
      }
      guard !self.stopped, self.store.snapshotRevision == revision,
        self.presentationAllowsUpdates(), self.needsDisplayOptions
      else { return }
      self.displayOptions = options
      self.scheduleUpdate()
    }
  }

  func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
    guard message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.protocol == "mwe-ui",
      message.frameInfo.securityOrigin.host == "app",
      message.webView === webView,
      let body = message.body as? [String: Any], let action = body["action"] as? String
    else {
      reply(nil, String(localized: "This page is not allowed to control the application."))
      return
    }
    // Title-bar gestures reply immediately: a drag must start on the mouse event that
    // caused it, and neither gesture changes any state worth pushing back to the page.
    if action == "dragWindow" || action == "titleDoubleClick" {
      handleTitleBarGesture(action)
      reply(nil, nil)
      return
    }
    Task { @MainActor in
      do {
        try await perform(action, body: body)
        reconcileDismissedErrors()
        reply(snapshot(), nil)
      } catch {
        actionError = error.localizedDescription
        reply(nil, error.localizedDescription)
      }
      scheduleUpdate()
    }
  }

  private func handleTitleBarGesture(_ action: String) {
    guard let window = webView?.window, window.titleVisibility == .hidden,
      !window.styleMask.contains(.fullScreen)
    else { return }
    switch action {
    case "dragWindow":
      guard let event = NSApp.currentEvent,
        event.window === window,
        event.type == .leftMouseDown || event.type == .leftMouseDragged
      else { return }
      window.performDrag(with: event)
    case "titleDoubleClick":
      // Mirror the Desktop & Dock preference that native title bars follow.
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "None": break
      case "Minimize": window.miniaturize(nil)
      case "Fill": window.zoom(nil)
      default: window.zoom(nil)
      }
    default: break
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard action.targetFrame?.isMainFrame == true, action.request.url == WebPanelAssets.indexURL
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isReady = false
    pageGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    updatePending = true
    cancelDisplayOptions()
    guard !recoveryAttempted else {
      showLoadFailure(
        String(
          localized:
            "The interface stopped unexpectedly. Close and reopen the control panel to retry."))
      return
    }
    recoveryAttempted = true
    webView.load(URLRequest(url: WebPanelAssets.indexURL))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    showLoadFailure(error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showLoadFailure(error.localizedDescription)
  }

  private func showLoadFailure(_ message: String) {
    guard let view = webView else { return }
    // Native recovery remains available even when JavaScript cannot start.
    let alert = NSAlert()
    alert.messageText = String(localized: "Couldn’t load the interface")
    alert.informativeText = message
    alert.addButton(withTitle: String(localized: "Reload"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard let window = view.window else {
      actionError = message
      return
    }
    alert.beginSheetModal(for: window) { [weak self, weak view] response in
      if response == .alertFirstButtonReturn {
        self?.recoveryAttempted = false
        view?.load(URLRequest(url: WebPanelAssets.indexURL))
      }
    }
  }
}

@MainActor
private final class WebPanelMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
  weak var owner: WebPanelController?
  init(owner: WebPanelController) { self.owner = owner }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard let owner else {
      replyHandler(nil, String(localized: "The control panel has closed."))
      return
    }
    owner.receive(message, reply: replyHandler)
  }
}

@MainActor
final class WebPanelAssets: NSObject, WKURLSchemeHandler {
  static let indexURL = URL(string: "mwe-ui://app/index.html")!
  /// Library preview files by wallpaper id, served as `mwe-ui://preview/<id>`.
  var previews: [String: URL] = [:]
  /// Workshop preview URLs by item id, served as still thumbnails at `mwe-ui://thumbnail/<id>`
  /// and relayed with their animation at `mwe-ui://animated/<id>`.
  var thumbnails: [String: URL] = [:]
  let thumbnailCache: WorkshopThumbnailCache
  /// In-flight loads by scheme task identity. WebKit frees a stopped task, and a new one can
  /// land on the same address, so each entry carries a unique ticket: a finished job may only
  /// act when the entry for its key still belongs to it.
  private var tasks: [ObjectIdentifier: (ticket: UInt64, job: Task<Void, Never>)] = [:]
  private var nextTicket: UInt64 = 0
  private static let files: Set<String> = [
    "index.html", "panel.js", "panel.css", "settings.js", "settings.css", "welcome.js",
    "welcome.css", "theme.js", "icons.js", "i18n.js",
    "app-icons/minimal.png", "app-icons/day.png", "app-icons/night.png",
  ]
  /// One catalog module per shipped language, served as `mwe-ui://app/locales/<tag>.js`.
  private static let localeFiles: Set<String> = Set(
    AppLanguage.supported.filter { $0.tag != AppLanguage.english.tag }.map {
      "locales/\($0.tag).js"
    })

  enum Route: Equatable {
    case file(URL)
    case thumbnail(URL)
    case animated(URL)
  }

  init(thumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache()) {
    self.thumbnailCache = thumbnailCache
    super.init()
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let key = ObjectIdentifier(task)
    guard let url = task.request.url, let route = route(url) else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    nextTicket += 1
    let ticket = nextTicket
    let job = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let data: Data
        var headers = [
          "Access-Control-Allow-Origin": "mwe-ui://app", "X-Content-Type-Options": "nosniff",
        ]
        switch route {
        case .file(let file):
          data = try await Task.detached(priority: .utility) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            return try Data(contentsOf: file, options: .mappedIfSafe)
          }.value
          headers["Content-Type"] = Self.mimeType(for: file)
        case .thumbnail(let preview):
          data = try await thumbnailCache.thumbnail(for: preview)
          headers["Content-Type"] = "image/jpeg"
          // The disk cache is the source of truth; this only lets WebKit skip re-asking for
          // tiles that scroll in and out of view within one session.
          headers["Cache-Control"] = "max-age=86400"
        case .animated(let preview):
          data = try await thumbnailCache.animatedPreview(for: preview)
          headers["Content-Type"] = WorkshopThumbnailCache.mimeType(of: data)
          headers["Cache-Control"] = "max-age=86400"
        }
        guard finish(key, ticket: ticket) else { return }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
      } catch {
        guard finish(key, ticket: ticket) else { return }
        task.didFailWithError(error)
      }
    }
    tasks.updateValue((ticket, job), forKey: key)?.job.cancel()
  }

  /// Releases the entry for a completed job. Returns false when WebKit already stopped the
  /// task or the key now belongs to a newer task, in which case the task must not be touched.
  private func finish(_ key: ObjectIdentifier, ticket: UInt64) -> Bool {
    guard !Task.isCancelled, tasks[key]?.ticket == ticket else { return false }
    tasks.removeValue(forKey: key)
    return true
  }

  private static func mimeType(for file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "html": "text/html"
    case "js": "text/javascript"
    case "css": "text/css"
    default:
      UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
    }
  }

  func route(_ url: URL) -> Route? {
    if let file = resourceURL(url) { return .file(file) }
    guard url.scheme == "mwe-ui", let host = url.host, url.user == nil, url.password == nil,
      url.port == nil, let preview = thumbnails[String(url.path.dropFirst())],
      preview.scheme == "https"
    else { return nil }
    switch host {
    case "thumbnail": return .thumbnail(preview)
    case "animated": return .animated(preview)
    default: return nil
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(task))?.job.cancel()
  }

  func resourceURL(_ url: URL) -> URL? {
    guard url.scheme == "mwe-ui", url.user == nil, url.password == nil, url.port == nil else {
      return nil
    }
    let name = String(url.path.dropFirst())
    if url.host == "app", Self.files.contains(name) || Self.localeFiles.contains(name) {
      return Bundle.main.resourceURL?.appendingPathComponent("WebUI", isDirectory: true)
        .appendingPathComponent(name)
    }
    if url.host == "preview", let file = previews[name] {
      let resolved = file.resolvingSymlinksInPath().standardizedFileURL
      let root = ClientPaths.libraryURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
      guard resolved.path.hasPrefix(root),
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff"].contains(
          resolved.pathExtension.lowercased())
      else { return nil }
      return resolved
    }
    return nil
  }
}
