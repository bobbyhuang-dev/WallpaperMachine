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

    /// Which of the page's own media listeners a payload belongs to. Kept as a
    /// plain slot name so this file never has to know what a media property or
    /// a thumbnail actually contains.
    enum MediaSlot: String {
        case status, properties, thumbnail, playback, timeline
    }

    /// What the host must currently do for this page. `listening` is the page's
    /// own registration; `consuming` additionally requires the user's media
    /// integration setting, because a page that asked for the status listener
    /// still has to be told the feature is off without anything being captured.
    struct MediaDemand: Equatable {
        var listening = false
        var consuming = false
    }

    private struct RandomFileReply {
        var requestId: String
        var property: String
        var path: String
    }

    private struct DirectoryChange {
        var property: String
        var added: [String]
        var removed: [String]
    }

    /// Registered by the current document, so a reload or a crash restart starts
    /// from no subscription at all rather than inheriting the old one.
    private var audioListenerRegistered = false
    private var mediaListenerRegistered = false
    private var audioResponseEnabled = false
    private var mediaIntegrationEnabled = false
    private var audioDemand = false
    private var mediaDemand = MediaDemand()
    private var pendingRandomFileRequests: Set<String> = []
    /// Answers and directory deltas that arrived while the page was suspended.
    /// Media and audio are dropped instead: both are re-derived from current
    /// state on resume, whereas a dropped reply strands the page's callback and
    /// a dropped removal leaves a deleted file in its list.
    private var deferredRandomFileReplies: [RandomFileReply] = []
    private var deferredDirectoryChanges: [DirectoryChange] = []
    /// A page cannot be allowed to grow host memory by asking without waiting,
    /// nor to bank an unbounded replay across a long suspension.
    private static let maximumPendingRandomFileRequests = 32
    private static let maximumDeferredDirectoryChanges = 64
    private let messageProxy = ScriptMessageProxy()
    /// Raised when the page's audio subscription actually changes, so the host
    /// can open and close the capture tap on real demand.
    var onAudioDemandChanged: (@MainActor (Bool) -> Void)?
    var onMediaDemandChanged: (@MainActor (MediaDemand) -> Void)?
    var onRandomFileRequest: (@MainActor (_ requestId: String, _ propertyId: String) -> Void)?

    /// Name of the single page-to-host channel. Everything the page initiates —
    /// listener registration and random-file requests — arrives here as one
    /// tagged object, so there is exactly one place that has to distrust the page.
    static let messageHandlerName = "mweWallpaper"

    static let hostScript = """
    (() => {
      if (window.__mweWallpaperHost) return;
      const post = message => {
        try { window.webkit.messageHandlers.\(WebWallpaperPage.messageHandlerName).postMessage(message); }
        catch (error) { console.error("wallpaper host channel unavailable", error); }
      };
      let listener = null;
      let lastUser = null, lastGeneral = null, lastPaused = null;
      // What the host has told this document about each watched directory, so a
      // listener registered after the files arrived still sees them.
      const directories = new Map();
      const call = (name, ...args) => {
        if (listener && typeof listener[name] === "function") {
          try { listener[name](...args); } catch (error) { console.error("wallpaperPropertyListener." + name + " failed", error); }
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
          for (const [property, files] of directories) {
            if (files.length) call("userDirectoryFilesAddedOrChanged", property, files.slice());
          }
        },
      });
      // Right clicks are forwarded to the page, never to WebKit's own context
      // menu: a wallpaper has no Reload or Inspect Element. Page handlers still run.
      window.addEventListener("contextmenu", event => event.preventDefault(), true);

      // Registration replaces, never accumulates: a page that re-registers, or
      // that is reloaded after a crash, must not end up receiving every frame
      // twice. The host is told only when the page crosses between having no
      // listener and having one, so capture opens and closes on real demand.
      let audioListener = null;
      window.wallpaperRegisterAudioListener = value => {
        const next = typeof value === "function" ? value : null;
        const had = audioListener !== null;
        audioListener = next;
        if ((next !== null) !== had) post({ type: next ? "audioSubscribed" : "audioUnsubscribed" });
      };

      const MEDIA_SLOTS = ["status", "properties", "thumbnail", "playback", "timeline"];
      const mediaListeners = {};
      const mediaValue = {};
      const mediaEncoded = {};
      const mediaCount = () => MEDIA_SLOTS.reduce((total, slot) => total + (mediaListeners[slot] ? 1 : 0), 0);
      const fireMedia = (slot, event) => {
        const target = mediaListeners[slot];
        if (!target) return;
        try { target(event); } catch (error) { console.error("wallpaper media listener " + slot + " failed", error); }
      };
      for (const slot of MEDIA_SLOTS) {
        mediaListeners[slot] = null;
        mediaValue[slot] = null;
        mediaEncoded[slot] = null;
        const name = "wallpaperRegisterMedia" + slot.charAt(0).toUpperCase() + slot.slice(1) + "Listener";
        window[name] = value => {
          const next = typeof value === "function" ? value : null;
          const before = mediaCount();
          mediaListeners[slot] = next;
          const after = mediaCount();
          if (before === 0 && after > 0) post({ type: "mediaSubscribed" });
          else if (before > 0 && after === 0) post({ type: "mediaUnsubscribed" });
          if (next && mediaValue[slot] !== null) fireMedia(slot, mediaValue[slot]);
        };
      }
      // The official documentation uses both spellings in its own examples.
      const PLAYING = 0, PAUSED = 1, STOPPED = 2;
      window.wallpaperMediaIntegration = Object.freeze({
        PLAYBACK_PLAYING: PLAYING, PLAYBACK_PAUSED: PAUSED, PLAYBACK_STOPPED: STOPPED,
        playback: Object.freeze({ PLAYING, PAUSED, STOPPED }),
      });

      let randomFileSequence = 0;
      const randomFileCallbacks = new Map();
      window.wallpaperRequestRandomFileForProperty = (property, callback) => {
        if (typeof property !== "string" || property === "" || typeof callback !== "function") return;
        const requestId = "r" + (++randomFileSequence);
        randomFileCallbacks.set(requestId, callback);
        post({ type: "randomFileRequest", requestId, propertyId: property });
      };

      window.__mweWallpaperHost = Object.freeze({
        applyUserProperties(properties) { lastUser = properties; call("applyUserProperties", properties); },
        applyGeneralProperties(properties) { lastGeneral = properties; call("applyGeneralProperties", properties); },
        setPaused(paused) { lastPaused = !!paused; call("setPaused", lastPaused); },
        deliverAudio(bins) {
          if (!audioListener) return;
          try { audioListener(bins); } catch (error) { console.error("wallpaperRegisterAudioListener callback failed", error); }
        },
        // Each media listener fires only when its own part changed. The host
        // already drops unchanged values, but a resume replay and a provider
        // re-emission can still race, so the last payload is compared here too.
        // Compared key by key in sorted order: the host builds these objects
        // from a dictionary, whose key order is not part of the contract.
        deliverMedia(slot, event) {
          if (!MEDIA_SLOTS.includes(slot)) return;
          const encoded = JSON.stringify(Object.keys(event).sort().map(key => [key, event[key]]));
          if (mediaEncoded[slot] === encoded) return;
          mediaEncoded[slot] = encoded;
          mediaValue[slot] = event;
          fireMedia(slot, event);
        },
        deliverRandomFile(requestId, property, filePath) {
          const callback = randomFileCallbacks.get(requestId);
          if (!callback) return;
          randomFileCallbacks.delete(requestId);
          try { callback(property, filePath); } catch (error) { console.error("wallpaperRequestRandomFileForProperty callback failed", error); }
        },
        userDirectoryFilesAddedOrChanged(property, files) {
          const known = directories.get(property) || [];
          directories.set(property, known.concat(files.filter(file => !known.includes(file))));
          call("userDirectoryFilesAddedOrChanged", property, files);
        },
        userDirectoryFilesRemoved(property, files) {
          const known = directories.get(property);
          if (known) directories.set(property, known.filter(file => !files.includes(file)));
          call("userDirectoryFilesRemoved", property, files);
        },
      });
    })();
    """

    /// `WKUserContentController` retains its message handlers, and the page owns
    /// that controller through its web view: conforming the page itself would
    /// make the pair immortal. The proxy owns nothing.
    private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
        weak var page: WebWallpaperPage?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { page?.receiveScriptMessage(body) }
        }
    }

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
        messageProxy.page = self
        // Registered on the web view's own controller rather than the one built
        // above: `WKWebView` copies the configuration it is given, so only this
        // one is guaranteed to be the live object.
        webView.configuration.userContentController.add(messageProxy, name: Self.messageHandlerName)
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
        forgetDocumentState()
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
        forgetDocumentState()
        messageProxy.page = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Drops everything that belonged to the document being replaced. The new
    /// document re-registers its own listeners, so inheriting the old ones would
    /// leave the capture tap open for a page that never asked for it, and would
    /// let a reply to a request the previous document made reach the new one.
    private func forgetDocumentState() {
        audioListenerRegistered = false
        mediaListenerRegistered = false
        pendingRandomFileRequests.removeAll()
        deferredRandomFileReplies.removeAll()
        deferredDirectoryChanges.removeAll()
        refreshDemand()
    }

    /// `propertiesJSON` is the bridge's `{ id: { value, type, … } }` payload,
    /// with any staged `file` value already substituted by the host.
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

    /// The user's per-wallpaper audio-response setting. Audio only reaches the
    /// page when the page asked for it *and* the user allowed it, so a page that
    /// registers a listener on a wallpaper with the setting off opens no tap.
    func setAudioResponseEnabled(_ enabled: Bool) {
        guard enabled != audioResponseEnabled else { return }
        audioResponseEnabled = enabled
        refreshDemand()
    }

    /// The user's per-wallpaper media-integration setting. Unlike audio this
    /// does not gate the status listener: a page is told the feature is off.
    func setMediaIntegrationEnabled(_ enabled: Bool) {
        guard enabled != mediaIntegrationEnabled else { return }
        mediaIntegrationEnabled = enabled
        refreshDemand()
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
        // After the view tree has settled, so a resume flushes into a page that
        // is back where WebKit will run it.
        refreshDemand()
        if !suspended { flushDeferredDeliveries() }
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

    // MARK: - author API delivery

    /// One audio frame: 128 floats, indices 0-63 the left channel and 64-127
    /// the right, as the Wallpaper Engine listener contract specifies.
    func deliverAudio(_ bins: [Float]) {
        guard audioDemand else { return }
        run("window.__mweWallpaperHost.deliverAudio(bins)", arguments: ["bins": bins.map { Double($0) }])
    }

    /// One media listener payload. The host builds the event object, so this
    /// file never has to model what the system knows about the playing track.
    /// Dropped rather than deferred while suspended: the host replays current
    /// state on resume, and a stale event is worse than a late one.
    func deliverMediaEvent(slot: MediaSlot, event: [String: Any]) {
        guard mediaDemand.listening else { return }
        run("window.__mweWallpaperHost.deliverMedia(slot, event)",
            arguments: ["slot": slot.rawValue, "event": event])
    }

    /// Answers a `wallpaperRequestRandomFileForProperty` call. `token` is the
    /// value handed out with the request. A token the current document never
    /// asked for is dropped: the page numbers its own requests from one per
    /// document, so after a reload the previous wallpaper's answer would
    /// otherwise match the new page's first request exactly.
    func deliverRandomFile(requestId token: String, property: String, path: String) {
        guard pendingRandomFileRequests.remove(token) != nil,
              let separator = token.firstIndex(of: ":")
        else { return }
        let reply = RandomFileReply(
            requestId: String(token[token.index(after: separator)...]), property: property, path: path)
        guard isLoaded, !hostSuspended else {
            deferredRandomFileReplies.append(reply)
            return
        }
        send(reply)
    }

    /// A `fetchall` directory delta. Deltas are ordered, so a suspension holds
    /// them rather than dropping them: replaying only the current set would
    /// leave files the user deleted in the page's list.
    func deliverDirectoryFiles(property: String, added: [String], removed: [String]) {
        guard !added.isEmpty || !removed.isEmpty else { return }
        // A new document is sent the whole current set instead, so anything
        // buffered for the old one would arrive twice.
        guard isLoaded else { return }
        let change = DirectoryChange(property: property, added: added, removed: removed)
        guard !hostSuspended else {
            if deferredDirectoryChanges.count >= Self.maximumDeferredDirectoryChanges {
                deferredDirectoryChanges.removeFirst()
                AppLog.debug("""
                    web wallpaper \(projectURL.lastPathComponent): directory changes outran \
                    the suspension buffer; the oldest delta was dropped
                    """)
            }
            deferredDirectoryChanges.append(change)
            return
        }
        send(change)
    }

    private func send(_ reply: RandomFileReply) {
        run("window.__mweWallpaperHost.deliverRandomFile(requestId, property, path)",
            arguments: ["requestId": reply.requestId, "property": reply.property, "path": reply.path])
    }

    private func send(_ change: DirectoryChange) {
        if !change.added.isEmpty {
            run("window.__mweWallpaperHost.userDirectoryFilesAddedOrChanged(property, files)",
                arguments: ["property": change.property, "files": change.added])
        }
        if !change.removed.isEmpty {
            run("window.__mweWallpaperHost.userDirectoryFilesRemoved(property, files)",
                arguments: ["property": change.property, "files": change.removed])
        }
    }

    private func flushDeferredDeliveries() {
        guard isLoaded, !hostSuspended else { return }
        let replies = deferredRandomFileReplies
        deferredRandomFileReplies.removeAll()
        for reply in replies { send(reply) }
        let changes = deferredDirectoryChanges
        deferredDirectoryChanges.removeAll()
        for change in changes { send(change) }
    }

    /// Recomputes what the host owes this page and reports only real changes,
    /// so a reconcile that alters nothing does not reopen the capture tap or
    /// re-add a consumer to the media provider.
    private func refreshDemand() {
        let live = isLoaded && !hostSuspended
        let audio = live && audioListenerRegistered && audioResponseEnabled
        if audio != audioDemand {
            audioDemand = audio
            onAudioDemandChanged?(audio)
        }
        let media = MediaDemand(
            listening: live && mediaListenerRegistered,
            consuming: live && mediaListenerRegistered && mediaIntegrationEnabled)
        if media != mediaDemand {
            mediaDemand = media
            onMediaDemandChanged?(media)
        }
    }

    /// The one place that distrusts the page. Anything that is not a recognised
    /// tagged object with well-formed fields is dropped.
    fileprivate func receiveScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else {
            AppLog.debug("web wallpaper \(projectURL.lastPathComponent): malformed host message dropped")
            return
        }
        switch type {
        case "audioSubscribed": audioListenerRegistered = true
        case "audioUnsubscribed": audioListenerRegistered = false
        case "mediaSubscribed": mediaListenerRegistered = true
        case "mediaUnsubscribed": mediaListenerRegistered = false
        case "randomFileRequest":
            guard let requestId = payload["requestId"] as? String, !requestId.isEmpty,
                  let propertyId = payload["propertyId"] as? String, !propertyId.isEmpty,
                  pendingRandomFileRequests.count < Self.maximumPendingRandomFileRequests
            else {
                AppLog.debug("""
                    web wallpaper \(projectURL.lastPathComponent): random file request dropped \
                    (malformed, or more than \(Self.maximumPendingRandomFileRequests) unanswered)
                    """)
                return
            }
            // The page numbers its requests from one per document, so the id it
            // chose is only unique within that document. The token handed to
            // the host carries the generation, which makes it unique for the
            // life of the page.
            let token = "\(documentGeneration):\(requestId)"
            pendingRandomFileRequests.insert(token)
            onRandomFileRequest?(token, propertyId)
            return
        default:
            AppLog.debug("web wallpaper \(projectURL.lastPathComponent): unknown host message “\(type)” dropped")
            return
        }
        refreshDemand()
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
        // A document that already registered its listeners during load only
        // becomes deliverable now.
        refreshDemand()
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
        // The crashed document's listeners died with it. Restarting inherits
        // nothing, so a page that crashes repeatedly cannot accumulate
        // subscriptions the host would keep feeding.
        forgetDocumentState()
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
