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

  func makeCoordinator() -> WebPanelController {
    WebPanelController(store: store, navigation: navigation, workshop: workshop)
  }

  func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
  func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.scheduleUpdate() }
  static func dismantleNSView(_ view: WKWebView, coordinator: WebPanelController) {
    coordinator.stop()
  }
}

@MainActor
final class WebPanelController: NSObject, WKNavigationDelegate {
  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  weak var webView: WKWebView?
  let assets = WebPanelAssets()
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
  var displayOptions: [String: BridgeWallpaperOptionsSnapshot] = [:]
  var displayOptionsRevision: UInt64?
  var displayOptionsTask: Task<Void, Never>?
  var displayOptionsGeneration: UInt64 = 0
  var recoveryAttempted = false
  var dismissedErrorRevision: UInt64 = 0
  var dismissedLibraryError: String?
  var dismissedDownloadError: String?
  static let favoriteKey = "MacWallpaperEngine.favoriteWallpaperIDs"

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    isPresentationVisible: (@MainActor () -> Bool)? = nil
  ) {
    self.store = store
    self.navigation = navigation
    self.workshop = workshop
    self.isPresentationVisible = isPresentationVisible
    favoriteIDs = Set(
      (try? JSONDecoder().decode(
        [String].self, from: UserDefaults.standard.data(forKey: Self.favoriteKey) ?? Data())) ?? [])
    super.init()
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
    view.underPageBackgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
    view.allowsBackForwardNavigationGestures = false
    #if DEBUG
      view.isInspectable = true
    #endif
    webView = view
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
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
          self.actionError = "The interface could not update: \(error.localizedDescription)"
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
      reply(nil, "This page is not allowed to control the application.")
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
        "The interface stopped unexpectedly. Close and reopen the control panel to retry.")
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
    alert.messageText = "Couldn’t load the interface"
    alert.informativeText = message
    alert.addButton(withTitle: "Reload")
    alert.addButton(withTitle: "Cancel")
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
      replyHandler(nil, "The control panel has closed.")
      return
    }
    owner.receive(message, reply: replyHandler)
  }
}

@MainActor
final class WebPanelAssets: NSObject, WKURLSchemeHandler {
  static let indexURL = URL(string: "mwe-ui://app/index.html")!
  var previews: [String: URL] = [:]
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private static let files: Set<String> = [
    "index.html", "panel.js", "panel.css", "settings.js", "settings.css",
  ]

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let key = ObjectIdentifier(task)
    guard let url = task.request.url, let file = resourceURL(url) else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    tasks[key] = Task { @MainActor in
      do {
        let data = try await Task.detached(priority: .utility) {
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 32 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
          return try Data(contentsOf: file, options: .mappedIfSafe)
        }.value
        guard tasks.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        default:
          mime =
            UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        }
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": mime, "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "mwe-ui://app", "X-Content-Type-Options": "nosniff",
          ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
      } catch {
        guard tasks.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
        task.didFailWithError(error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }

  func resourceURL(_ url: URL) -> URL? {
    guard url.scheme == "mwe-ui", url.user == nil, url.password == nil, url.port == nil else {
      return nil
    }
    let name = String(url.path.dropFirst())
    if url.host == "app", Self.files.contains(name) {
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
