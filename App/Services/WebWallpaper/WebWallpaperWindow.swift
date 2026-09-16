import AppKit
import WebKit

/// Borderless desktop-level window hosting one web wallpaper on one display.
/// Mirrors the renderer's `MWEWallpaperDesktopWindow` configuration so the
/// presentation policy and poster sync can treat both kinds alike. The
/// Objective-C name is stable: `WallpaperPresentationPolicy` and
/// `DesktopWallpaperSync` look it up by string.
@objc(MWEWebWallpaperDesktopWindow)
final class WebWallpaperWindow: NSWindow {
    let page: WebWallpaperPage

    init(frame: NSRect, page: WebWallpaperPage) {
        self.page = page
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        isMovable = false
        isRestorable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .black
        contentView = page.webView
        page.webView.frame = NSRect(origin: .zero, size: frame.size)
        page.webView.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// WebKit only hit-tests hover moves for pages whose window is active, and
    /// it derives that from `isKeyWindow`. A desktop window can never really be
    /// key (it must not take keyboard focus from the user's app), so it reports
    /// key to WebKit alone; AppKit never routes events to it either way.
    override var isKeyWindow: Bool { true }

    /// Desktop windows must cover the whole display, including under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One `WKWebView` running a Wallpaper Engine web project, with the host side
/// of the `wallpaperPropertyListener` protocol.
@MainActor
final class WebWallpaperPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let projectURL: URL
    let entryURL: URL
    private(set) var isLoaded = false
    private var recoveryAttempted = false
    private var pendingProperties: String?
    private var pendingGeneral: [String: Any] = [:]
    private var pendingPaused: Bool?
    private var suspended = false
    private var paused = false
    var onFailure: (@MainActor (String) -> Void)?
    var onLoaded: (@MainActor () -> Void)?

    static let hostScript = """
    (() => {
      if (window.__mweWallpaperHost) return;
      let listener = null;
      let lastUser = null, lastGeneral = null, lastPaused = null;
      const call = (name, value) => {
        if (listener && typeof listener[name] === "function") {
          try { listener[name](value); } catch (error) { console.error("wallpaperPropertyListener." + name + " failed", error); }
        }
      };
      // Wallpaper Engine only calls a listener that exists when the page has
      // loaded. Replaying the last values to a late listener is strictly more
      // forgiving, so bundled pages that register asynchronously still start.
      Object.defineProperty(window, "wallpaperPropertyListener", {
        configurable: true,
        get() { return listener; },
        set(value) {
          listener = value;
          if (lastGeneral) call("applyGeneralProperties", lastGeneral);
          if (lastUser) call("applyUserProperties", lastUser);
          if (lastPaused !== null) call("setPaused", lastPaused);
        },
      });
      // Right clicks are forwarded to the page, never to WebKit's own context
      // menu: a wallpaper has no Reload or Inspect Element. Page handlers still run.
      window.addEventListener("contextmenu", event => event.preventDefault(), true);
      window.__mweWallpaperHost = Object.freeze({
        applyUserProperties(properties) { lastUser = properties; call("applyUserProperties", properties); },
        applyGeneralProperties(properties) { lastGeneral = properties; call("applyGeneralProperties", properties); },
        setPaused(paused) { lastPaused = !!paused; call("setPaused", lastPaused); },
      });
    })();
    """

    /// `WKWebView` has no public entry point for hover: moves reach it through a
    /// private tracking-area owner, so hover uses the `_simulateMouseMove:`
    /// family WebKit ships for exactly this purpose. Clicks, drags and scrolls
    /// go through the ordinary responder methods.
    private static let simulateMove = NSSelectorFromString("_simulateMouseMove:")
    private static let simulateExit = NSSelectorFromString("_simulateMouseExit:")
    static var supportsHover: Bool { WKWebView.instancesRespond(to: simulateMove) }
    private static var hoverUnavailableLogged = false

    init(projectURL: URL, entryFile: String) {
        self.projectURL = projectURL
        self.entryURL = projectURL.appendingPathComponent(entryFile)
        let configuration = WKWebViewConfiguration()
        // Persistent: web wallpapers keep their own state (tasks, favourites) in
        // localStorage exactly as they do under Wallpaper Engine.
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Wallpaper Engine loads projects from file:// with sibling-file access;
        // ES modules and fetch() against project assets need the same origin
        // relaxation WebKit only exposes through these preference keys.
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.hostScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = content
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
            webView.isInspectable = true
        #endif
    }

    func load() {
        isLoaded = false
        webView.loadFileURL(entryURL, allowingReadAccessTo: projectURL)
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// `propertiesJSON` is the bridge's `{ id: { value } }` payload.
    func applyUserProperties(json propertiesJSON: String) {
        pendingProperties = propertiesJSON
        flush()
    }

    func applyGeneralProperties(fps: UInt32) {
        pendingGeneral["fps"] = Int(fps)
        flush()
    }

    /// The page pauses when the user paused playback or the presentation policy
    /// suspended rendering; either alone is sufficient.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        pendingPaused = paused || suspended
        flush()
    }

    func setPresentationSuspended(_ suspended: Bool) {
        self.suspended = suspended
        pendingPaused = paused || suspended
        flush()
    }

    private func flush() {
        guard isLoaded else { return }
        if let json = pendingProperties {
            pendingProperties = nil
            run("window.__mweWallpaperHost.applyUserProperties(JSON.parse(json))", arguments: ["json": json])
        }
        if !pendingGeneral.isEmpty {
            let general = pendingGeneral
            pendingGeneral = [:]
            run("window.__mweWallpaperHost.applyGeneralProperties(general)", arguments: ["general": general])
        }
        if let paused = pendingPaused {
            pendingPaused = nil
            run("window.__mweWallpaperHost.setPaused(paused)", arguments: ["paused": paused])
        }
    }

    private func run(_ script: String, arguments: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            } catch {
                AppLog.warn("web wallpaper \(self.projectURL.lastPathComponent): host call failed: \(error.localizedDescription)")
            }
        }
    }

    /// Replays a pointer event already rebased into the page's window.
    func deliverMouse(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            guard Self.supportsHover else {
                if !Self.hoverUnavailableLogged {
                    Self.hoverUnavailableLogged = true
                    AppLog.warn("web wallpaper hover unavailable: WKWebView lacks _simulateMouseMove:")
                }
                return
            }
            webView.perform(Self.simulateMove, with: event)
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .rightMouseDragged: webView.rightMouseDragged(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .otherMouseDragged: webView.otherMouseDragged(with: event)
        case .scrollWheel: webView.scrollWheel(with: event)
        default: break
        }
    }

    /// Clears `:hover` and fires `mouseout` when the pointer leaves the desktop.
    func deliverMouseExit() {
        guard WKWebView.instancesRespond(to: Self.simulateExit),
              let exit = NSEvent.enterExitEvent(
                with: .mouseExited, location: NSPoint(x: -1, y: -1), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        else { return }
        webView.perform(Self.simulateExit, with: exit)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        recoveryAttempted = false
        flush()
        onLoaded?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page may fetch and embed anything it likes, but the top frame stays
        // on the project's own entry page: no wallpaper navigates the desktop away.
        guard action.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(action.request.url?.standardizedFileURL == entryURL.standardizedFileURL ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        guard !recoveryAttempted else {
            onFailure?(String(localized: "The web wallpaper stopped unexpectedly and could not be restarted."))
            return
        }
        recoveryAttempted = true
        AppLog.warn("web wallpaper \(projectURL.lastPathComponent): content process terminated; reloading once")
        load()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?(error.localizedDescription)
    }
}
