import AppKit
import WebKit

/// What the web host needs from the staged user-asset store: enough to put the
/// user's own files where a page is allowed to read them, and to hear about a
/// watched directory changing. `UserAssetStore` is the production
/// implementation; a test substitutes its own.
@MainActor
protocol WebWallpaperAssetSource: AnyObject {
    var onDirectoryChanged: ((String, [UserAssetImport], [UserAssetImport]) -> Void)? { get set }
    func importFile(at url: URL, propertyId: String, filter: UserAssetFilter) throws -> UserAssetImport
    func importDirectory(at url: URL, propertyId: String, filter: UserAssetFilter, limit: Int) throws -> [UserAssetImport]
    func randomFile(propertyId: String) -> UserAssetImport?
    func isTruncated(propertyId: String) -> Bool
    func clear(propertyId: String)
}

extension UserAssetStore: WebWallpaperAssetSource {}

/// Keeps one desktop web view per display in step with the bridge's committed
/// web wallpapers. The renderer owns assignment, persistence and playback
/// state; this host only mirrors `webWallpapers()` into windows, pushes
/// property values into the pages, and answers desktop-poster requests.
@MainActor
final class WebWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeWebWallpaper]
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    private let frameCenter: NotificationCenter
    private var windows: [UInt32: WebWallpaperWindow] = [:]
    private lazy var mouse = WebWallpaperMouseForwarder { [weak self] in
        guard let self else { return [] }
        return Array(self.windows.values)
    }
    private var descriptors: [UInt32: BridgeWebWallpaper] = [:]
    private var posterObserver: NSObjectProtocol?
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var suspended = false
    /// Displays suspended on their own, kept apart from the global flag so one
    /// occluded screen cannot suspend a page on a visible screen.
    private var suspendedDisplays: Set<UInt32> = []
    private var stopped = false
    private let counters: RuntimeCounters
    /// Distinguishes surfaces that reused one display id across a wallpaper
    /// switch, so their counters are not merged.
    private var surfaceGeneration: UInt64 = 0
    /// Surfaced to the app the same way renderer failures are.
    var onError: (@MainActor (String) -> Void)?
    /// Fired after windows open, close, or finish loading their page, so the
    /// presentation policy and the desktop poster sync re-read the desktop.
    var onSurfacesChanged: (@MainActor () -> Void)?
    private var surfaceChangePending = false
    /// One pump for every display: the audio analysis is process-global.
    private let audioPump: WebWallpaperAudioPump
    private let setAudioSubscribed: @MainActor (_ wallpaperId: String, _ displayId: UInt32, _ subscribed: Bool) async throws -> Void
    /// Subscription changes are chained rather than fired in parallel, so two
    /// rapid transitions cannot land out of order and leave the tap open.
    private var audioSubscriptionTask: Task<Void, Never>?
    private var audioSubscriptions: [UInt32: Bool] = [:]
    private let mediaRelay: WebWallpaperMediaRelay
    /// Pages currently able to receive media events, which is not the same as
    /// the pages consuming the provider: a page whose user turned integration
    /// off still has to be told so.
    private var mediaListeners: Set<ObjectIdentifier> = []
    /// Built per project, and keyed on the stable wallpaper id so the managed store
    /// survives the project being deleted and downloaded again.
    private let makeAssetStore: (@MainActor (URL, String) -> any WebWallpaperAssetSource)?
    private var assetStores: [String: any WebWallpaperAssetSource] = [:]
    /// What each `file`/`directory` property was last staged from, so a
    /// reconcile that changed nothing does not re-link a whole directory.
    private var stagedAssets: [String: [String: StagedAsset]] = [:]
    /// Current staged contents of each watched directory, so a new document can
    /// be handed the whole `fetchall` set it missed.
    private var directoryFiles: [String: [String: [String]]] = [:]
    private var fetchAllProperties: [String: Set<String>] = [:]

    private struct StagedAsset {
        var source: String
        var pageValue: String
    }

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeWebWallpaper],
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        frameCenter: NotificationCenter = .default,
        counters: RuntimeCounters? = nil,
        audioPump: WebWallpaperAudioPump? = nil,
        setAudioSubscribed: (@MainActor (String, UInt32, Bool) async throws -> Void)? = nil,
        mediaProvider: (any SystemMediaProvider)? = nil,
        assetStore: (@MainActor (URL, String) -> any WebWallpaperAssetSource)? = nil
    ) {
        self.fetch = fetch
        self.screens = screens ?? { Self.systemScreens() }
        self.frameCenter = frameCenter
        self.counters = counters ?? .shared
        self.audioPump = audioPump ?? WebWallpaperAudioPump(read: { nil })
        self.setAudioSubscribed = setAudioSubscribed ?? { _, _, _ in }
        self.mediaRelay = WebWallpaperMediaRelay(provider: mediaProvider ?? UnavailableSystemMediaProvider())
        self.makeAssetStore = assetStore
        self.audioPump.onSpectrum = { [weak self] spectrum in self?.broadcast(spectrum) }
        self.mediaRelay.onChange = { [weak self] event in self?.broadcast(event) }
    }

    convenience init(bridge: WallpaperBridge) {
        self.init(
            fetch: { try await bridge.webWallpapers() },
            audioPump: WebWallpaperAudioPump(read: { try bridge.webAudioSpectrum() }),
            setAudioSubscribed: { wallpaperId, displayId, subscribed in
                try await bridge.setWebAudioSubscribed(
                    wallpaperId: wallpaperId, displayId: displayId, subscribed: subscribed)
            },
            mediaProvider: MediaRemoteMediaProvider(),
            assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) })
    }

    static func systemScreens() -> [(id: UInt32, frame: NSRect)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.frame)
        }
    }

    var activeDisplayIDs: Set<UInt32> { Set(windows.keys) }
    var isEmpty: Bool { windows.isEmpty }

    /// Displays whose page has actually registered an audio listener and is
    /// being fed. This is not the user's setting: a wallpaper that never calls
    /// `wallpaperRegisterAudioListener` reacts to nothing however the setting
    /// is left, and the control panel has to be able to say which it is.
    var audioSubscribedDisplayIDs: Set<UInt32> {
        Set(audioSubscriptions.filter(\.value).map(\.key))
    }

    /// Whether a system media provider can supply anything at all, and why not
    /// when it cannot. Distinct again from the user's setting.
    var systemMediaAvailability: SystemMediaAvailability { mediaRelay.availability }

    /// What the control panel needs to tell the user apart: their setting, and
    /// whether anything is actually being delivered. A wallpaper that never
    /// calls the register function reacts to nothing however the setting is
    /// left, and a system with no readable media source supplies nothing
    /// however the toggle is set.
    struct DeliveryStatus: Equatable, Sendable {
        var audioSubscribedDisplayIDs: Set<UInt32> = []
        /// Nil when a provider can supply media; otherwise why it cannot.
        var mediaUnavailableReason: String?
    }

    var deliveryStatus: DeliveryStatus {
        DeliveryStatus(
            audioSubscribedDisplayIDs: audioSubscribedDisplayIDs,
            mediaUnavailableReason: {
                switch systemMediaAvailability {
                case .available: nil
                case let .unavailable(reason): reason
                }
            }())
    }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        stopped = false
    }

    /// Re-reads the committed web wallpapers and diffs them against open windows.
    /// Overlapping calls coalesce into one trailing pass.
    func reconcile() {
        guard !stopped else { return }
        guard !reconcileInFlight else {
            reconcileRequested = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reconcileInFlight = false
                if self.reconcileRequested {
                    self.reconcileRequested = false
                    self.reconcile()
                }
            }
            do {
                let wallpapers = try await self.fetch()
                guard !self.stopped else { return }
                self.apply(wallpapers)
            } catch {
                AppLog.error("web wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeWebWallpaper]) {
        let screens = Dictionary(screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var next: [UInt32: BridgeWebWallpaper] = [:]
        for wallpaper in wallpapers where screens[wallpaper.displayId] != nil {
            next[wallpaper.displayId] = wallpaper
        }
        var changed = false
        for (displayID, window) in windows where next[displayID] == nil {
            close(window)
            windows[displayID] = nil
            descriptors[displayID] = nil
            changed = true
        }
        for (displayID, wallpaper) in next {
            guard let frame = screens[displayID] else { continue }
            let projectURL = URL(fileURLWithPath: wallpaper.projectPath, isDirectory: true)
            // Identity is the resolved entry path, not its last component: a
            // nested entry compared by file name alone never matches itself, so
            // every reconcile would discard a working page and build a new one.
            guard let canonicalEntry = WebWallpaperPage.canonicalEntryURL(
                projectURL: projectURL, entryFile: wallpaper.entryFile) else {
                AppLog.error("""
                    web wallpaper \(wallpaper.wallpaperId): entry file \(wallpaper.entryFile) \
                    resolves outside its project folder
                    """)
                onError?(String(localized: "Web wallpaper “\(wallpaper.title)” could not load: its entry file is outside the project folder."))
                if let window = windows[displayID] {
                    close(window)
                    windows[displayID] = nil
                    descriptors[displayID] = nil
                    changed = true
                }
                continue
            }
            if let window = windows[displayID], window.page.canonicalEntryURL == canonicalEntry {
                if window.frame != frame {
                    window.setFrame(frame, display: true)
                    changed = true
                }
                push(wallpaper, into: window.page, previous: descriptors[displayID])
            } else {
                if let window = windows[displayID] { close(window) }
                surfaceGeneration += 1
                let surface = RuntimeSurfaceKey(
                    kind: .desktopWeb, displayID: displayID, generation: surfaceGeneration)
                let page = WebWallpaperPage(
                    projectURL: projectURL, entryFile: wallpaper.entryFile,
                    surface: surface, counters: counters)
                counters.record(.webPageCreated, for: surface)
                page.onFailure = { [weak self] message in
                    AppLog.error("web wallpaper \(wallpaper.wallpaperId) on display \(displayID): \(message)")
                    self?.onError?(String(localized: "Web wallpaper “\(wallpaper.title)” could not load: \(message)"))
                }
                page.onLoaded = { [weak self] in
                    self?.replayDirectories(displayID: displayID)
                    self?.scheduleSurfaceChange()
                }
                page.onAudioDemandChanged = { [weak self, weak page] subscribed in
                    guard let self, let page else { return }
                    self.setAudioDemand(subscribed, page: page, displayID: displayID)
                }
                page.onMediaDemandChanged = { [weak self, weak page] demand in
                    guard let self, let page else { return }
                    self.setMediaDemand(demand, page: page, displayID: displayID)
                }
                page.onRandomFileRequest = { [weak self, weak page] requestId, propertyId in
                    guard let self, let page else { return }
                    self.answerRandomFile(requestId: requestId, propertyId: propertyId, page: page)
                }
                let window = WebWallpaperWindow(frame: frame, page: page)
                windows[displayID] = window
                push(wallpaper, into: page, previous: nil)
                page.load()
                window.orderFrontRegardless()
                AppLog.info("web wallpaper \(wallpaper.wallpaperId) opened on display \(displayID)")
                changed = true
            }
        }
        pruneAssetState()
        mouse.setActive(!windows.isEmpty)
        if changed { onSurfacesChanged?() }
    }

    /// A page reports `didFinish` before its first meaningful paint, so the
    /// poster is re-read once immediately and once after the page has had time
    /// to render its initial frame.
    private func scheduleSurfaceChange() {
        onSurfacesChanged?()
        guard !surfaceChangePending else { return }
        surfaceChangePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.surfaceChangePending = false
            guard !self.stopped else { return }
            self.onSurfacesChanged?()
        }
    }

    private func push(_ wallpaper: BridgeWebWallpaper, into page: WebWallpaperPage, previous: BridgeWebWallpaper?) {
        // Recorded before anything is pushed: the page reports its own demand
        // back synchronously, and answering it from a stale descriptor would
        // tell the page the previous wallpaper's settings.
        descriptors[wallpaper.displayId] = wallpaper
        let staged = stageAssets(for: wallpaper)
        page.setAudioResponseEnabled(wallpaper.audioResponseEnabled)
        page.setMediaIntegrationEnabled(wallpaper.mediaIntegrationEnabled)
        if previous?.propertiesJson != wallpaper.propertiesJson || staged.restaged {
            page.applyUserProperties(json: staged.json)
        }
        if previous?.fps != wallpaper.fps {
            page.applyGeneralProperties(fps: wallpaper.fps)
        }
        if previous?.paused != wallpaper.paused {
            page.setPaused(wallpaper.paused)
        }
        page.setPresentationSuspended(isSuspended(displayID: wallpaper.displayId))
    }

    private func isSuspended(displayID: UInt32) -> Bool {
        suspended || suspendedDisplays.contains(displayID)
    }

    /// Mirrors `WallpaperPresentationPolicy`: pages suspend while no pixel can
    /// reach any display, without touching the user's play/pause choice.
    func setPresentationSuspended(_ suspended: Bool) {
        self.suspended = suspended
        for (displayID, window) in windows {
            window.page.setPresentationSuspended(isSuspended(displayID: displayID))
        }
    }

    /// Suspends the page on one display only. A window covering the wallpaper
    /// on one screen must not stop the page on another.
    func setPresentationSuspended(_ suspended: Bool, forDisplay displayID: UInt32) {
        if suspended {
            suspendedDisplays.insert(displayID)
        } else {
            suspendedDisplays.remove(displayID)
        }
        windows[displayID]?.page.setPresentationSuspended(isSuspended(displayID: displayID))
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        mouse.setActive(false)
        // Each page drops its own subscriptions as it stops; the sweep after
        // the loop is what guarantees the invariant rather than trusting it.
        for window in windows.values { close(window) }
        windows.removeAll()
        audioPump.removeAllSubscribers()
        mediaRelay.removeAllConsumers()
        mediaListeners.removeAll()
        for (displayID, subscribed) in audioSubscriptions where subscribed {
            guard let wallpaperId = descriptors[displayID]?.wallpaperId else { continue }
            flushAudioSubscription(wallpaperId: wallpaperId, displayID: displayID, subscribed: false)
        }
        audioSubscriptions.removeAll()
        descriptors.removeAll()
        pruneAssetState()
    }

    /// A project nothing displays any more keeps no staged index. The store is
    /// in memory, so holding it would only pin the file list of a wallpaper the
    /// user has moved on from; the staged copies themselves stay on disk and
    /// are removed with the project or by `python3 scripts/clean.py`.
    private func pruneAssetState() {
        let live = Set(windows.values.map { Self.projectKey($0.page.projectURL.path) })
        for project in Array(assetStores.keys) where !live.contains(project) {
            assetStores[project] = nil
            stagedAssets[project] = nil
            directoryFiles[project] = nil
            fetchAllProperties[project] = nil
        }
    }

    private func close(_ window: WebWallpaperWindow) {
        window.page.stop()
        window.orderOut(nil)
        window.close()
    }

    // MARK: - audio

    /// A page's audio subscription changed. The shared pump decides whether any
    /// polling happens at all; the bridge call opens and closes the capture tap
    /// so an idle desktop is not recording the user's output.
    private func setAudioDemand(_ subscribed: Bool, page: WebWallpaperPage, displayID: UInt32) {
        audioPump.setSubscribed(subscribed, for: ObjectIdentifier(page))
        // A display nobody ever subscribed is already unsubscribed: a page that
        // stops without ever having asked must not send the bridge a close for
        // a tap that was never opened.
        guard (audioSubscriptions[displayID] ?? false) != subscribed,
              let wallpaperId = descriptors[displayID]?.wallpaperId else { return }
        audioSubscriptions[displayID] = subscribed
        flushAudioSubscription(wallpaperId: wallpaperId, displayID: displayID, subscribed: subscribed)
    }

    /// Chained rather than fired independently: an unsubscribe overtaking the
    /// subscribe that preceded it would leave the tap open with nobody reading.
    private func flushAudioSubscription(wallpaperId: String, displayID: UInt32, subscribed: Bool) {
        let previous = audioSubscriptionTask
        audioSubscriptionTask = Task { @MainActor [setAudioSubscribed] in
            await previous?.value
            do {
                try await setAudioSubscribed(wallpaperId, displayID, subscribed)
            } catch {
                AppLog.warn("""
                    web wallpaper audio on display \(displayID): subscription could not be \
                    \(subscribed ? "opened" : "closed"): \(error.localizedDescription)
                    """)
            }
        }
    }

    private func broadcast(_ spectrum: BridgeAudioSpectrum) {
        for window in windows.values {
            window.page.deliverAudio(spectrum.bins)
        }
    }

    // MARK: - media

    private func setMediaDemand(_ demand: WebWallpaperPage.MediaDemand, page: WebWallpaperPage, displayID: UInt32) {
        let key = ObjectIdentifier(page)
        mediaRelay.setConsuming(demand.consuming, for: key)
        guard demand.listening else {
            mediaListeners.remove(key)
            return
        }
        mediaListeners.insert(key)
        // A page that has just registered, reloaded or resumed is given the
        // whole current state; the page drops any part of it that has not
        // actually changed since it last saw it.
        let enabled = descriptors[displayID]?.mediaIntegrationEnabled ?? false
        for event in mediaRelay.currentEvents(userEnabled: enabled) {
            page.deliverMediaEvent(slot: event.slot, event: event.payload)
        }
    }

    private func broadcast(_ event: WebWallpaperMediaRelay.Event) {
        let payload = event.payload
        for window in windows.values where mediaListeners.contains(ObjectIdentifier(window.page)) {
            window.page.deliverMediaEvent(slot: event.slot, event: payload)
        }
    }

    // MARK: - file and directory properties

    /// Puts the user's `file` and `directory` selections where the page is
    /// allowed to read them, and rewrites the payload so a `file` property
    /// carries the staged value the page can actually load.
    ///
    /// A `directory` value is left alone: the protocol only uses it so a page
    /// can tell "no directory set" from "one is set", and neither mode loads it
    /// directly — `ondemand` asks for a random file and `fetchall` is told the
    /// contents through the listener.
    func stageAssets(for wallpaper: BridgeWebWallpaper) -> (json: String, restaged: Bool) {
        let properties = Self.pathProperties(in: wallpaper.propertiesJson)
        guard !properties.isEmpty else { return (wallpaper.propertiesJson, false) }
        let project = Self.projectKey(wallpaper.projectPath)
        var restaged = false
        for property in properties {
            // Registered before staging: the import itself announces the files
            // it found, and routing that announcement needs the mode already
            // recorded.
            if property.kind == .directory {
                if property.fetchAll {
                    fetchAllProperties[project, default: []].insert(property.id)
                } else {
                    fetchAllProperties[project]?.remove(property.id)
                }
            }
            if stagedAssets[project]?[property.id]?.source != property.source {
                restage(
                    property, project: project, wallpaperId: wallpaper.wallpaperId,
                    title: wallpaper.title)
                restaged = true
            }
        }
        let staged = properties.filter { $0.kind == .file }.reduce(into: [String: String]()) {
            $0[$1.id] = stagedAssets[project]?[$1.id]?.pageValue ?? ""
        }
        guard !staged.isEmpty else { return (wallpaper.propertiesJson, restaged) }
        return (Self.substituting(staged, in: wallpaper.propertiesJson) ?? wallpaper.propertiesJson, restaged)
    }

    /// The `file` and `directory` properties the bridge's payload declares.
    /// Anything else — including `texture` and `scenetexture`, which are scene
    /// texture pickers with no directory semantics — is not a path property.
    static func pathProperties(in propertiesJson: String) -> [PathProperty] {
        guard let data = propertiesJson.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return root.compactMap { PathProperty(id: $0.key, entry: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// Replaces the `value` of the named properties, leaving every other key in
    /// the payload untouched. Returns nil when the payload is not an object.
    static func substituting(_ values: [String: String], in propertiesJson: String) -> String? {
        guard let data = propertiesJson.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for (id, value) in values {
            var entry = (root[id] as? [String: Any]) ?? [:]
            entry["value"] = value
            root[id] = entry
        }
        // Sorted so two pushes of the same selection produce the same payload
        // rather than differing by dictionary order alone.
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func restage(
        _ property: PathProperty, project: String, wallpaperId: String, title: String
    ) {
        guard let store = assetStore(forProject: project, wallpaperId: wallpaperId) else {
            // Nothing can stage the file, so the page is told the property is
            // unset rather than handed a path it is not allowed to read.
            stagedAssets[project, default: [:]][property.id] = StagedAsset(source: property.source, pageValue: "")
            return
        }
        // Only a genuinely cleared property is cleared in the store. Re-importing the
        // same selection must not discard the app's managed copy and fetch it again.
        if property.source.isEmpty { store.clear(propertyId: property.id) }
        let previousFiles = directoryFiles[project]?[property.id] ?? []
        directoryFiles[project]?[property.id] = nil
        guard !property.source.isEmpty else {
            stagedAssets[project, default: [:]][property.id] = StagedAsset(source: "", pageValue: "")
            if !previousFiles.isEmpty {
                deliverDirectory(project: project, propertyId: property.id, added: [], removed: previousFiles)
            }
            return
        }
        let source = URL(fileURLWithPath: property.source)
        do {
            switch property.kind {
            case .file:
                let staged = try store.importFile(
                    at: source, propertyId: property.id, filter: property.filter)
                stagedAssets[project, default: [:]][property.id] =
                    StagedAsset(source: property.source, pageValue: staged.pageValue)
            case .directory:
                let staged = try store.importDirectory(
                    at: source, propertyId: property.id, filter: property.filter,
                    limit: UserAssetStore.defaultDirectoryFileLimit)
                let files = staged.map(\.pageValue)
                directoryFiles[project, default: [:]][property.id] = files
                stagedAssets[project, default: [:]][property.id] =
                    StagedAsset(source: property.source, pageValue: property.source)
                if store.isTruncated(propertyId: property.id) {
                    let limit = UserAssetStore.defaultDirectoryFileLimit
                    onError?(String(localized: "Web wallpaper “\(title)” uses only the first \(limit) files in the folder you chose."))
                }
                deliverDirectory(project: project, propertyId: property.id, added: files, removed: previousFiles)
            }
        } catch {
            // Never silent: the property stays unset and the reason is surfaced
            // the same way a renderer failure is.
            stagedAssets[project]?[property.id] = nil
            if !previousFiles.isEmpty {
                deliverDirectory(project: project, propertyId: property.id, added: [], removed: previousFiles)
            }
            AppLog.error("web wallpaper \(project): \(property.id) could not be staged: \(error.localizedDescription)")
            onError?(String(localized: "Web wallpaper “\(title)” could not use the file you chose: \(error.localizedDescription)"))
        }
    }

    private func assetStore(
        forProject project: String, wallpaperId: String
    ) -> (any WebWallpaperAssetSource)? {
        if let existing = assetStores[project] { return existing }
        guard let makeAssetStore else { return nil }
        let store = makeAssetStore(URL(fileURLWithPath: project, isDirectory: true), wallpaperId)
        store.onDirectoryChanged = { [weak self] propertyId, added, removed in
            MainActor.assumeIsolated {
                self?.directoryChanged(
                    project: project, propertyId: propertyId,
                    added: added.map(\.pageValue), removed: removed.map(\.pageValue))
            }
        }
        assetStores[project] = store
        return store
    }

    private func directoryChanged(project: String, propertyId: String, added: [String], removed: [String]) {
        var files = directoryFiles[project]?[propertyId] ?? []
        files.removeAll { removed.contains($0) }
        files.append(contentsOf: added.filter { !files.contains($0) })
        directoryFiles[project, default: [:]][propertyId] = files
        deliverDirectory(project: project, propertyId: propertyId, added: added, removed: removed)
    }

    private func deliverDirectory(project: String, propertyId: String, added: [String], removed: [String]) {
        guard fetchAllProperties[project]?.contains(propertyId) == true else { return }
        for window in windows.values where Self.projectKey(window.page.projectURL.path) == project {
            window.page.deliverDirectoryFiles(property: propertyId, added: added, removed: removed)
        }
    }

    /// A new document never saw the files the host already knows about, so the
    /// whole current set is replayed into it as an addition.
    private func replayDirectories(displayID: UInt32) {
        guard let page = windows[displayID]?.page else { return }
        let project = Self.projectKey(page.projectURL.path)
        for propertyId in fetchAllProperties[project] ?? [] {
            let files = directoryFiles[project]?[propertyId] ?? []
            guard !files.isEmpty else { continue }
            page.deliverDirectoryFiles(property: propertyId, added: files, removed: [])
        }
    }

    /// Answers `wallpaperRequestRandomFileForProperty`. A property with no
    /// usable directory answers with an empty path: the page's callback must
    /// run either way, because a wallpaper that waits for it would never draw.
    private func answerRandomFile(requestId: String, propertyId: String, page: WebWallpaperPage) {
        let project = Self.projectKey(page.projectURL.path)
        let path = assetStores[project]?.randomFile(propertyId: propertyId)?.pageValue ?? ""
        page.deliverRandomFile(requestId: requestId, property: propertyId, path: path)
    }

    /// Project paths reach this host from two directions — the descriptor and
    /// the page's own URL — so both are reduced to one spelling before use.
    private static func projectKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// A `file` or `directory` property as the project declared it, resolved
    /// against the path the user currently has selected.
    struct PathProperty: Equatable {
        enum Kind: String { case file, directory }

        var id: String
        var kind: Kind
        var filter: UserAssetFilter
        var fetchAll: Bool
        /// The user's own path, as the bridge persisted it. Empty when unset.
        var source: String

        init?(id: String, entry: Any) {
            guard let entry = entry as? [String: Any],
                  let kind = (entry["type"] as? String).flatMap(Kind.init(rawValue:))
            else { return nil }
            self.id = id
            self.kind = kind
            // An author who declared no file-type option restricted nothing, so
            // neither does the import.
            self.filter = (entry["fileFilter"] as? String).flatMap(UserAssetFilter.init(rawValue:)) ?? .any
            self.fetchAll = kind == .directory && (entry["mode"] as? String) == "fetchall"
            self.source = (entry["value"] as? String) ?? ""
        }
    }

    /// `DesktopWallpaperSync` asks each desktop surface for pixels by its layer.
    /// A web surface answers with a `WKWebView` snapshot in the same RGBA
    /// contract the renderer uses, so Space posters match the live page.
    private func answerPosterRequest(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
              let window = windows.values.first(where: { $0.contentView?.layer === layer }) else { return }
        let webView = window.page.webView
        let center = frameCenter
        webView.takeSnapshot(with: nil) { image, error in
            MainActor.assumeIsolated {
                guard let image else {
                    if let error { AppLog.warn("web wallpaper poster snapshot failed: \(error.localizedDescription)") }
                    return
                }
                guard let frame = Self.rgbaPixels(of: image) else { return }
                center.post(name: Notification.Name("MacWallpaperEngine.desktopPosterReady"), object: layer,
                            userInfo: ["pixels": frame.pixels, "width": frame.width, "height": frame.height, "bgra": false])
            }
        }
    }

    static func rgbaPixels(of image: NSImage) -> (pixels: Data, width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
