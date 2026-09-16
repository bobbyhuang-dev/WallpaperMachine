import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private let controlPanelNavigation = ControlPanelNavigation()
    private lazy var workshopStore = WorkshopStore()
    private lazy var appUpdater = AppUpdateStore()
    private var displayChangeObserver: NSObjectProtocol?
    private var desktopWallpaperSync: DesktopWallpaperSync?
    private var presentationPolicy: WallpaperPresentationPolicy?
    private var store: BridgeStore?
    private var startupError: Error?
    private var lastError: Error?
    private var playbackSnapshotCurrent = false
    private var shutdownInProgress = false
    private var shutdownComplete = false
    private var themeSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need the executable's types, not its desktop lifecycle.
        // UI tests run in a separate runner, so the real app still starts normally.
        if NSClassFromString("XCTestCase") != nil {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        themeSubscription = AppThemeStore.shared.$preferences
            .map(\.mode).removeDuplicates()
            .sink { mode in NSApp.appearance = mode.appearance }
        logStartup("didFinishLaunching start")
        BridgeEnvironment.configureVulkanICDIfNeeded()
        logStartup("vulkan icd configured")
        do {
            try ClientPaths.prepare()
            store = try BridgeStore()
            AppLog.store = store
            startupError = nil
            playbackSnapshotCurrent = false
            logStartup("BridgeStore created")
        } catch {
            logStartup("BridgeStore FAILED: \(error.localizedDescription)")
            startupError = error
            playbackSnapshotCurrent = false
        }
        // A crash during a download leaves its staging behind, holding the whole downloaded item.
        let stagingRoot = ClientPaths.supportURL
        Task.detached(priority: .utility) {
            WorkshopDownloader.removeAbandonedStaging(in: stagingRoot)
        }

        NSApp.setActivationPolicy(.accessory)
        logStartup("activation policy set to accessory")
        installStatusItem()
        synchronizeStatusItem()
        installDisplayChangeObserver()
        logStartup("display change observer installed")
        installApplicationMenu()
        logStartup("application menu installed")
        if let store {
            let lockScreen = LockScreenWallpaperService(bridge: store.bridge)
            store.lockScreenWallpaper = lockScreen
            lockScreen.beforeActivation = { [weak self] in
                guard let self else { return }
                if self.desktopWallpaperSync == nil {
                    self.desktopWallpaperSync = try DesktopWallpaperSync(
                        folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"))
                }
                self.desktopWallpaperSync?.suspendForNativeProvider()
            }
            lockScreen.afterDeactivation = { [weak self] in
                self?.desktopWallpaperSync = nil
                try self?.startDesktopWallpaperSync()
            }
            store.onSnapshotApplied = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
                if let lockScreen, lockScreen.isRequested, lockScreen.errorMessage == nil {
                    lockScreen.refresh()
                } else if lockScreen?.ownsDesktopProvider != true {
                    // A suspended poster sync must never outlive the native provider.
                    do { try self.startDesktopWallpaperSync() } catch {
                        self.lastError = error
                        AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                    }
                }
            }
            let policy = WallpaperPresentationPolicy { [weak self] suspended, completion in
                guard let self, let store = self.store,
                      !self.shutdownInProgress, !self.shutdownComplete else {
                    completion(.failure(CancellationError()))
                    return
                }
                Task {
                    do {
                        try await store.setPresentationSuspendedAsync(suspended)
                        completion(.success(()))
                    } catch {
                        AppLog.error("presentation suspend failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
            presentationPolicy = policy
            policy.start()
            do {
                try lockScreen.start()
                if !lockScreen.isRequested { try startDesktopWallpaperSync() }
            } catch {
                lastError = error
                logStartup("Native wallpaper recovery failed: \(error.localizedDescription)")
            }
        }
        bootstrapStore()
        logStartup("bootstrap dispatched")
        DispatchQueue.main.async { [weak self] in
            self?.showControlPanel(selection: .wallpaper)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !shutdownInProgress, !shutdownComplete,
              let window = controlPanelWindow, !window.isVisible else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        presentationPolicy?.stop()
        presentationPolicy = nil
        desktopWallpaperSync?.stop()
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
            self.displayChangeObserver = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The test host must not instantiate services against the user's app-support folder.
        if NSClassFromString("XCTestCase") != nil { return .terminateNow }
        guard !shutdownComplete else {
            return .terminateNow
        }
        guard !shutdownInProgress else {
            return .terminateCancel
        }

        shutdownInProgress = true
        desktopWallpaperSync?.suspendForNativeProvider()
        controlPanelWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)

        Task {
            do {
                try await store?.lockScreenWallpaper?.shutdown()
                presentationPolicy?.stop()
                presentationPolicy = nil
                desktopWallpaperSync?.stop()
                desktopWallpaperSync = nil
            } catch {
                lastError = error
                shutdownInProgress = false
                presentationPolicy?.evaluate()
                rebuildMenu()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            appUpdater.cancel()
            await workshopStore.steamCMDSetup.shutdown()
            await workshopStore.downloader.shutdown()
            do {
                try await store?.shutdownAsync()
                lastError = nil
            } catch {
                lastError = error
            }

            shutdownInProgress = false
            shutdownComplete = true
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel(selection: .wallpaper)
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStoreSnapshot()
        rebuildMenu(menu)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === controlPanelWindow else {
            return true
        }
        guard !shutdownInProgress && !shutdownComplete else {
            return true
        }

        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        rebuildMenu()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === controlPanelWindow
        else {
            return
        }

        controlPanelWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Emits a startup-diagnostic line straight to stderr so it is visible when
    /// the app is launched from a terminal. Deliberately bypasses `AppLog`,
    /// whose `guard let store` blind spot silently drops every message until
    /// `BridgeStore` is constructed, and which otherwise writes only to the
    /// Rust file channel rather than stderr.
    private func logStartup(_ message: String) {
        fputs("[WE] \(message)\n", stderr)
    }

    private func startDesktopWallpaperSync() throws {
        guard !shutdownInProgress else { return }
        if let sync = desktopWallpaperSync, !sync.isSuspended {
            sync.refresh()
            return
        }
        let sync = try DesktopWallpaperSync(folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"))
        desktopWallpaperSync = sync
        sync.start()
        sync.refresh()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let button = item.button
        let trayIcon = NSImage(named: "TrayIcon")
        if let button {
            button.image = trayIcon
                ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Wallpaper Engine")
            button.image?.isTemplate = true
        }

        logStartup("statusItem installed: button=\(button != nil) trayIconAssetResolved=\(trayIcon != nil)")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu(menu)
    }

    /// Work around an AppKit/SwiftUI timing issue: when launched via
    /// LaunchServices (Finder double-click) in `.accessory` activation
    /// policy, a status item created in `applicationDidFinishLaunching`
    /// may be created correctly but never rendered because the SwiftUI
    /// Scene phase hasn't stabilized yet. Deferring by one runloop turn
    /// gives the Scene phase time to settle. Re-asserting the activation
    /// policy afterwards forces AppKit to re-register accessory-mode
    /// status items with the Window Server; rebuilding the menu alone
    /// only mutates `NSMenu` items and does not touch the status item's
    /// backing window, so it is insufficient by itself.
    private func synchronizeStatusItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusItem != nil else { return }
            // Re-assert the activation policy to force AppKit to
            // re-register the accessory-mode status item with the
            // Window Server after the SwiftUI Scene phase has settled.
            if self.controlPanelWindow == nil { NSApp.setActivationPolicy(.accessory) }
            self.rebuildMenu()
        }
    }

    private func installDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplaysFromSystemEvent()
            }
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "MacWallpaperEngine")
        let settings = menuItem(titleKey: "Settings…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        applicationMenu.addItem(settings)
        applicationMenu.addItem(menuItem(titleKey: "Check for Updates…", action: #selector(checkForUpdates)))
        applicationMenu.addItem(.separator())
        let quit = menuItem(titleKey: "Quit MacWallpaperEngine", action: #selector(exitApplication))
        quit.keyEquivalent = "q"
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        // Keep standard text editing shortcuts in search and setup fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func rebuildMenu(_ menu: NSMenu? = nil) {
        guard let menu = menu ?? statusItem?.menu else {
            return
        }

        menu.removeAllItems()
        menu.addItem(menuItem(titleKey: "Control Panel", action: #selector(openControlPanel)))

        if let store,
           playbackSnapshotCurrent,
           !store.appSnapshot.activeWallpaperIds.isEmpty
        {
            menu.addItem(.separator())
            let playbackTitleKey = store.appSnapshot.playbackState == .paused ? "Play" : "Pause"
            let playbackItem = menuItem(titleKey: playbackTitleKey, action: #selector(togglePlayback))
            playbackItem.isEnabled = true
            menu.addItem(playbackItem)
        }

        if let error = startupError ?? lastError {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(error.localizedDescription))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(titleKey: "Exit", action: #selector(exitApplication)))
    }

    private func menuItem(titleKey: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: NSLocalizedString(titleKey, comment: ""),
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openControlPanel() {
        showControlPanel(selection: .wallpaper)
    }

    @objc func openSettings() {
        showControlPanel(selection: .settings)
    }

    @objc func checkForUpdates() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
        Task { _ = await appUpdater.checkForUpdates() }
    }

    private func showControlPanel(selection: SidebarSelection) {
        controlPanelNavigation.selection = selection
        NSApp.setActivationPolicy(.regular)

        if let controlPanelWindow {
            constrainControlPanelWindowToScreen(controlPanelWindow)
            controlPanelWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MacWallpaperEngine"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        let controller: NSHostingController<AnyView>
        if let store {
            controller = NSHostingController(
                rootView: AnyView(
                    ControlPanelView(
                        store: store,
                        navigation: controlPanelNavigation,
                        workshop: workshopStore,
                        updater: appUpdater
                    )
                )
            )
        } else {
            controller = NSHostingController(
                rootView: AnyView(BridgeUnavailableView(error: startupError ?? lastError))
            )
        }

        // AppKit owns this resizable window's bounds; content must accept its proposal
        // instead of promoting a long label or a split pane's ideal width to a window minimum.
        controller.sizingOptions = []
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 760, height: 560)
        let frameName = "MacWallpaperEngineMainWindow"
        if !window.setFrameUsingName(frameName) { window.center() }
        constrainControlPanelWindowToScreen(window)
        window.setFrameAutosaveName(frameName)

        controlPanelWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func constrainControlPanelWindowToScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let minimumFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 760, height: 560))
        let minimumSize = NSSize(width: min(minimumFrame.width, visible.width),
                                 height: min(minimumFrame.height, visible.height))
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumSize)).size
        var frame = window.frame
        frame.size.width = min(max(frame.width, minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, minimumSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    @objc private func togglePlayback() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete,
              playbackSnapshotCurrent,
              !store.appSnapshot.activeWallpaperIds.isEmpty
        else {
            return
        }

        Task {
            do {
                if store.appSnapshot.playbackState == .paused {
                    try await store.playAllAsync()
                } else {
                    try await store.pauseAllAsync()
                }
                lastError = nil
                playbackSnapshotCurrent = true
                rebuildMenu()
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
                rebuildMenu()
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func exitApplication() {
        NSApp.terminate(nil)
    }

    private func bootstrapStore() {
        logStartup("bootstrapAsync start")
        guard let store else {
            logStartup("bootstrapAsync skipped: store is nil")
            return
        }

        Task {
            do {
                try await store.bootstrapAsync()
                startupError = nil
                lastError = nil
                playbackSnapshotCurrent = true
                logStartup("bootstrapAsync completed successfully")
            } catch {
                logStartup("bootstrapAsync FAILED: \(error.localizedDescription)")
                lastError = error
                playbackSnapshotCurrent = false
            }
            rebuildMenu()
            if startupError == nil, lastError == nil {
                Task { _ = await appUpdater.checkForUpdates() }
            }
        }
    }

    private func refreshStoreSnapshot() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return
        }

        Task {
            do {
                try await store.refreshAllAsync()
                lastError = nil
                playbackSnapshotCurrent = true
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
            }
            rebuildMenu()
        }
    }

    private func refreshDisplaysFromSystemEvent() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return
        }

        Task {
            do {
                try await store.refreshDisplaysAsync()
                lastError = nil
                playbackSnapshotCurrent = true
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
            }
            rebuildMenu()
        }
    }

}

private struct BridgeUnavailableView: View {
    let error: Error?

    var body: some View {
        ContentUnavailableView(
            "Bridge Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? "The rendering bridge could not be started.")
        )
        .frame(minWidth: 640, minHeight: 420)
    }
}
