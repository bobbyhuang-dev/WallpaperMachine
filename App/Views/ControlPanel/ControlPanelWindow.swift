import AppKit

/// Builds the control-panel window and owns its size floor.
///
/// `contentMinSize` alone does not hold: once the SwiftUI hosting controller attaches, it
/// resets the window's content minimum to zero even with `sizingOptions = []`, so the
/// window delegate clamps every user resize through `clampedFrameSize` instead.
@MainActor
enum ControlPanelWindow {
    /// Smallest content area the bundled panel lays out without overflow; the web page's
    /// `body` min-width and the panel layout tests use the same figure.
    static let minimumContentSize = NSSize(width: 760, height: 560)
    static let initialContentSize = NSSize(width: 1240, height: 800)
    static let frameAutosaveName = "WallpaperMachineMainWindow"

    static func make(contentViewController: NSViewController, delegate: NSWindowDelegate?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMachine"
        // The bundled page draws its own top bar in the title-bar strip. An empty unified
        // toolbar only sizes that strip so the traffic lights sit on the tab row; the page
        // reads their inset from the snapshot and handles dragging itself.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let titlebarSpacer = NSToolbar(identifier: "WallpaperMachineTitlebar")
        titlebarSpacer.showsBaselineSeparator = false
        window.toolbar = titlebarSpacer
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.contentViewController = contentViewController
        window.contentMinSize = minimumContentSize
        return window
    }

    /// The frame size the window may not shrink below: the minimum content size plus
    /// window chrome, capped by the visible frame of the screen it is on.
    static func minimumFrameSize(for window: NSWindow) -> NSSize {
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize))
        guard let visible = visibleFrame(for: window) else { return minimumFrame.size }
        return NSSize(width: min(minimumFrame.width, visible.width),
                      height: min(minimumFrame.height, visible.height))
    }

    /// Clamps a proposed frame size to the size floor; used from `windowWillResize`.
    static func clampedFrameSize(_ proposed: NSSize, for window: NSWindow) -> NSSize {
        let minimum = minimumFrameSize(for: window)
        return NSSize(width: max(proposed.width, minimum.width),
                      height: max(proposed.height, minimum.height))
    }

    /// Re-asserts the size floor and keeps the whole frame on the visible screen.
    static func constrainToScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let visible = visibleFrame(for: window) else { return }
        let minimumSize = minimumFrameSize(for: window)
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumSize)).size
        var frame = window.frame
        frame.size.width = min(max(frame.width, minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, minimumSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private static func visibleFrame(for window: NSWindow) -> NSRect? {
        (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }
}
