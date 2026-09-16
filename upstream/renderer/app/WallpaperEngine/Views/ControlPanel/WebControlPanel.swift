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
  let theme: AppThemeStore
  weak var webView: WKWebView?
  let assets = WebPanelAssets()
  var subscriptions = Set<AnyCancellable>()
  var isReady = false
  var stopped = false
  var updateScheduled = false
  var deferredWhileHidden = false
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
  var recoveryAttempted = false
  var dismissedErrorRevision: UInt64 = 0
  var dismissedLibraryError: String?
  var dismissedDownloadError: String?
  static let favoriteKey = "MacWallpaperEngine.favoriteWallpaperIDs"

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    theme: AppThemeStore? = nil
  ) {
    self.store = store
    self.navigation = navigation
    self.workshop = workshop
    self.theme = theme ?? .shared
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
    view.underPageBackgroundColor = .windowBackgroundColor
    view.allowsBackForwardNavigationGestures = false
    #if DEBUG
      view.isInspectable = true
    #endif
    webView = view
    theme.$preferences.sink { [weak self] preferences in
      self?.applyTheme(preferences)
    }.store(in: &subscriptions)
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.publisher(for: name)
        .sink { [weak self] note in
          MainActor.assumeIsolated {
            guard let self, let window = note.object as? NSWindow,
              window === self.webView?.window, window.isVisible, self.deferredWhileHidden
            else { return }
            self.deferredWhileHidden = false
            self.scheduleUpdate()
          }
        }
        .store(in: &subscriptions)
    }
    navigation.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(
      in: &subscriptions)
    view.load(URLRequest(url: WebPanelAssets.indexURL))
    observeState()
    return view
  }

  private func applyTheme(_ preferences: AppThemePreferences) {
    guard let view = webView else { return }
    view.appearance = preferences.mode.appearance
    // This is the panel's only user script. Replace it so every reload, including
    // WebContent recovery, starts with the latest saved theme before first paint.
    let content = view.configuration.userContentController
    content.removeAllUserScripts()
    // Mode/tone are closed enums and accent is validated as six hexadecimal digits.
    content.addUserScript(
      WKUserScript(
        source:
          "window.__appTheme = {mode:'\(preferences.mode.rawValue)',accent:'\(preferences.accent)',tone:'\(preferences.tone.rawValue)'};",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    guard isReady, !stopped else { return }
    Task { @MainActor [weak self, weak view] in
      guard let self, !self.stopped, let view else { return }
      do {
        _ = try await view.callAsyncJavaScript(
          "window.appTheme?.apply(theme)", arguments: ["theme": self.theme.preferences.snapshot],
          in: nil, contentWorld: .page)
      } catch {
        self.actionError = "The appearance could not update: \(error.localizedDescription)"
      }
      self.scheduleUpdate()
    }
  }

  func stop() {
    stopped = true
    displayOptionsTask?.cancel()
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
      _ = snapshot()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observationInstalled = false
        self.scheduleUpdate()
        self.observeState()
      }
    }
  }

  func scheduleUpdate() {
    guard !stopped, !updateScheduled else { return }
    updateScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.updateScheduled = false
      guard self.isReady, !self.stopped, let view = self.webView else { return }
      // Observation, not the snapshot, drives continuation: a retained intent starts as soon
      // as SteamCMD finishes installing or a saved sign-in appears.
      self.workshop.resumeDownloadRequests(bridge: self.store)
      self.reconcileDismissedErrors()
      guard view.window?.isVisible == true else {
        self.deferredWhileHidden = true
        return
      }
      self.refreshDisplayOptions()
      let state = self.snapshot()
      do {
        _ = try await view.callAsyncJavaScript(
          "window.wallpaperUI.receive(state)", arguments: ["state": state], in: nil,
          contentWorld: .page)
      } catch {
        self.actionError = "The interface could not update: \(error.localizedDescription)"
      }
    }
  }

  func refreshDisplayOptions() {
    guard displayOptionsRevision != store.snapshotRevision, displayOptionsTask == nil else {
      return
    }
    let revision = store.snapshotRevision
    let ids = Set(
      store.monitorInformationSnapshot.rows.filter {
        $0.mirrorTargetDisplayId == nil && !$0.wallpaperId.isEmpty
      }.map(\.wallpaperId))
    displayOptionsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
      for id in ids {
        guard !Task.isCancelled else {
          self.displayOptionsTask = nil
          return
        }
        if let value = try? await self.store.wallpaperOptionsSnapshotAsync(wallpaperId: id) {
          options[id] = value
        }
      }
      self.displayOptionsTask = nil
      guard !self.stopped else { return }
      if self.store.snapshotRevision == revision {
        self.displayOptions = options
        self.displayOptionsRevision = revision
      }
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
    "index.html", "panel.js", "panel.css", "settings.js", "settings.css", "theme.js",
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
