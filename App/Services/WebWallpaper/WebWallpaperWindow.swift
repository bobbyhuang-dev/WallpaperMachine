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
        // The web view is a subview of a stable container rather than the
        // content view itself: suspension removes it from the window tree, and
        // the desktop poster sync identifies this surface by the content
        // layer, which must survive that.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        contentView = container
        page.attach(to: container)
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
    /// How often a crashing page may be restarted, and what earns the budget
    /// back. A page that keeps dying after a successful load must stop being
    /// restarted; only a stable run clears its history.
    struct RecoveryPolicy {
        var maximumRestarts = 3
        var window: Duration = .seconds(120)
        var stableRun: Duration = .seconds(60)
        var initialBackoff: Duration = .seconds(2)
        var maximumBackoff: Duration = .seconds(30)
    }

    /// Everything the host has committed to this wallpaper. A reloaded document
    /// starts with none of it, so the whole snapshot is replayed on each new
    /// document generation rather than only the values that changed since.
    private struct CommittedState {
        var propertiesJSON: String?
        var fps: UInt32?
        var userPaused = false
        var presentationSuspended = false

        /// The page pauses when the user paused playback or the presentation
        /// policy suspended rendering; either alone is sufficient.
        var isPaused: Bool { userPaused || presentationSuspended }
    }

    let webView: WKWebView
    let projectURL: URL
    let entryURL: URL
    /// Symlink-resolved entry path, used for identity only: two descriptors name
    /// the same page when this matches, whatever spelling the entry file used.
    let canonicalEntryURL: URL
    private(set) var isLoaded = false
    /// Increments on every `load()`. Async host calls carry the generation they
    /// were issued for, so a late completion cannot write into a newer document.
    private(set) var documentGeneration: UInt64 = 0
    private var committed = CommittedState()
    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    private let recovery: RecoveryPolicy
    private let now: @MainActor () -> ContinuousClock.Instant
    private let wait: @Sendable (Duration) async throws -> Void
    private var restartHistory: [ContinuousClock.Instant] = []
    private var restartTask: Task<Void, Never>?
    /// When the current document finished loading, so a crash can tell a page
    /// that ran stably from one that died shortly after every load.
    private var lastLoadFinished: ContinuousClock.Instant?
    private weak var container: NSView?
    private var placeholder: NSImageView?
    private var hostSuspended = false
    /// Invalidates an in-flight suspension poster when the decision changes.
    private var suspensionGeneration: UInt64 = 0
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

    /// Resolves a project-relative entry file to the path identity used for
    /// comparison, or nil when it leaves the project folder once symlinks are
    /// resolved. Comparing only the last path component instead makes a nested
    /// entry such as `sub/index.html` never equal to itself, which rebuilds the
    /// page on every reconcile.
    static func canonicalEntryURL(projectURL: URL, entryFile: String) -> URL? {
        // A manifest entry is always relative to its project. An absolute path
        // would otherwise be appended as a component and silently resolve to a
        // file inside the project that the author never named.
        guard !entryFile.isEmpty, !entryFile.hasPrefix("/") else { return nil }
        let root = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let entry = projectURL.appendingPathComponent(entryFile)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        guard entry.pathComponents.count > rootComponents.count,
              Array(entry.pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return entry
    }

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this initializer rather than in a caller-evaluated default argument.
    init(
        projectURL: URL,
        entryFile: String,
        surface: RuntimeSurfaceKey = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 0),
        counters: RuntimeCounters? = nil,
        recovery: RecoveryPolicy = RecoveryPolicy(),
        now: (@MainActor () -> ContinuousClock.Instant)? = nil,
        wait: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.projectURL = projectURL
        self.entryURL = projectURL.appendingPathComponent(entryFile)
        self.canonicalEntryURL = Self.canonicalEntryURL(projectURL: projectURL, entryFile: entryFile)
            ?? self.entryURL.standardizedFileURL
        self.surface = surface
        self.counters = counters ?? .shared
        self.recovery = recovery
        self.now = now ?? { ContinuousClock.now }
        self.wait = wait ?? { try await Task.sleep(for: $0) }
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
        // Lets WebKit throttle this page's own work once it leaves the window
        // tree. Media playback and capture are documented exceptions, which is
        // why suspension also suspends media explicitly.
        configuration.preferences.inactiveSchedulingPolicy = .suspend
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
        documentGeneration += 1
        lastLoadFinished = nil
        webView.loadFileURL(entryURL, allowingReadAccessTo: projectURL)
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        lastLoadFinished = nil
        // Invalidate any host call still in flight for the document being torn
        // down, so it cannot reach the blank page that replaces it.
        documentGeneration += 1
        isLoaded = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// `propertiesJSON` is the bridge's `{ id: { value } }` payload.
    func applyUserProperties(json propertiesJSON: String) {
        committed.propertiesJSON = propertiesJSON
        deliverUserProperties()
    }

    func applyGeneralProperties(fps: UInt32) {
        committed.fps = fps
        deliverGeneralProperties()
    }

    func setPaused(_ paused: Bool) {
        committed.userPaused = paused
        deliverPaused()
    }

    /// Hosts the web view inside its window's container and remembers it, so
    /// suspension can take the view out of the window tree and put it back.
    func attach(to container: NSView) {
        self.container = container
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        guard !hostSuspended else { return }
        container.addSubview(webView)
    }

    func setPresentationSuspended(_ suspended: Bool) {
        committed.presentationSuspended = suspended
        deliverPaused()
        applyHostSuspension(suspended)
    }

    /// Suspension the page cannot opt out of.
    ///
    /// `wallpaperPropertyListener.setPaused` is cooperative: a page that does
    /// not implement it, or that only stops part of its animation, keeps its
    /// timers, workers, WebGL and media running. Two host-side controls do not
    /// depend on the page at all — suspending media playback, and taking the
    /// web view out of the window tree, which is the documented condition for
    /// WebKit's inactive scheduling policy. Neither wraps
    /// `requestAnimationFrame` and neither touches the shared WebContent
    /// process, which other wallpapers and the control panel also use.
    private func applyHostSuspension(_ suspended: Bool) {
        guard suspended != hostSuspended else { return }
        hostSuspended = suspended
        suspensionGeneration += 1
        let generation = suspensionGeneration
        if suspended {
            // Suspend, never pause: unsuspending restores what each element was
            // doing, so media the user had paused stays paused.
            webView.setAllMediaPlaybackSuspended(true)
            counters.record(.webMediaSuspended, for: surface)
            captureDetachPoster(generation: generation)
        } else {
            reattachWebView()
            webView.setAllMediaPlaybackSuspended(false)
            counters.record(.webMediaResumed, for: surface)
        }
    }

    /// Keeps the last frame on screen while the web view is out of the window.
    /// The snapshot is asynchronous, so a resume that arrives first cancels it.
    private func captureDetachPoster(generation: UInt64) {
        guard container != nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self, self.suspensionGeneration == generation, self.hostSuspended else { return }
                if let error {
                    AppLog.debug("""
                        web wallpaper \(self.projectURL.lastPathComponent): \
                        suspension poster unavailable: \(error.localizedDescription)
                        """)
                }
                self.detachWebView(poster: image)
            }
        }
    }

    private func detachWebView(poster: NSImage?) {
        guard let container, webView.superview === container else { return }
        let placeholder = NSImageView(frame: container.bounds)
        placeholder.autoresizingMask = [.width, .height]
        placeholder.imageScaling = .scaleAxesIndependently
        placeholder.image = poster
        placeholder.wantsLayer = true
        container.addSubview(placeholder)
        self.placeholder = placeholder
        webView.removeFromSuperview()
        counters.record(.webDetached, for: surface)
    }

    private func reattachWebView() {
        guard let container else { return }
        if webView.superview !== container {
            webView.frame = container.bounds
            container.addSubview(webView)
            counters.record(.webAttached, for: surface)
        }
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    /// Whether the web view is currently in its window's view tree. WebKit's
    /// inactive scheduling policy keys off exactly this.
    var isInWindowTree: Bool { container != nil && webView.superview === container }

    private func deliverUserProperties() {
        guard isLoaded, let json = committed.propertiesJSON else { return }
        run("window.__mweWallpaperHost.applyUserProperties(JSON.parse(json))", arguments: ["json": json])
    }

    private func deliverGeneralProperties() {
        guard isLoaded, let fps = committed.fps else { return }
        run("window.__mweWallpaperHost.applyGeneralProperties(general)",
            arguments: ["general": ["fps": Int(fps)]])
    }

    private func deliverPaused() {
        guard isLoaded else { return }
        run("window.__mweWallpaperHost.setPaused(paused)", arguments: ["paused": committed.isPaused])
    }

    /// Replays the whole committed snapshot into a freshly loaded document. A
    /// descriptor diff cannot do this: after a crash and reload nothing has
    /// changed, so nothing would be sent and the page would start blank.
    private func replayCommittedState() {
        counters.record(.webStateReplayed, for: surface)
        deliverUserProperties()
        deliverGeneralProperties()
        deliverPaused()
    }

    private func run(_ script: String, arguments: [String: Any]) {
        let generation = documentGeneration
        Task { @MainActor [weak self] in
            guard let self, self.documentGeneration == generation else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            } catch {
                AppLog.warn("web wallpaper \(self.projectURL.lastPathComponent): host call failed: \(error.localizedDescription)")
            }
        }
    }

    /// Replays a pointer event already rebased into the page's window. A
    /// suspended page consumes nothing: delivering to a view outside the window
    /// tree would both restart work and hit-test against stale geometry.
    func deliverMouse(_ event: NSEvent) {
        guard !hostSuspended else { return }
        counters.record(.pointerDelivered, for: surface)
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
        lastLoadFinished = now()
        replayCommittedState()
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
        let moment = now()
        // A load that finishes proves nothing on its own: a page that crashes
        // shortly after every load would otherwise clear its budget forever.
        // Only an uninterrupted run returns the restarts.
        if let finished = lastLoadFinished, moment - finished >= recovery.stableRun {
            restartHistory.removeAll()
        }
        lastLoadFinished = nil
        restartHistory.removeAll { moment - $0 >= recovery.window }
        guard restartHistory.count < recovery.maximumRestarts else {
            counters.record(.webRecoveryBudgetExhausted, for: surface)
            AppLog.error("""
                web wallpaper \(projectURL.lastPathComponent): content process terminated \
                \(restartHistory.count) times; restart budget exhausted
                """)
            onFailure?(String(localized: "The web wallpaper stopped unexpectedly and could not be restarted."))
            return
        }
        // Back off exponentially so a page that dies immediately after loading
        // cannot spin the content process at full speed.
        let attempt = restartHistory.count
        restartHistory.append(moment)
        counters.record(.webRecoveryStarted, for: surface)
        let delay = min(recovery.initialBackoff * (1 << attempt), recovery.maximumBackoff)
        AppLog.warn("""
            web wallpaper \(projectURL.lastPathComponent): content process terminated; \
            restart \(attempt + 1) of \(recovery.maximumRestarts) in \(delay)
            """)
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self, wait] in
            try? await wait(delay)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.load()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?(error.localizedDescription)
    }
}
