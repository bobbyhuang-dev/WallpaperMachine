import AppKit

/// Decides which web wallpaper window, if any, receives a desktop pointer
/// event. Pure state machine over window numbers so the policy is testable
/// without AppKit windows or a live pointer.
///
/// The desktop is everything the window server stacks beneath ordinary
/// application windows: the system wallpaper, Finder's icon window, desktop
/// widgets and our own wallpaper windows all report a negative window layer.
/// A press that was forwarded keeps its drags and release even when the pointer
/// wanders over an application window, so pages see complete gestures.
struct WebWallpaperMouseRouting {
    enum Kind: Equatable {
        case move
        case scroll
        case down(button: Int)
        case drag(button: Int)
        case up(button: Int)
    }

    enum Decision: Equatable {
        case ignore
        case deliver(to: Int)
        /// The pointer left `exit`; nothing else receives this event.
        case exit(Int)
        /// The pointer moved from one wallpaper window straight onto another.
        case exitThenDeliver(exit: Int, to: Int)
    }

    /// Wallpaper windows deliberately ignore mouse events, so the window the
    /// system reports under the pointer is normally Finder's desktop or the
    /// system wallpaper; both sit below layer 0.
    static let desktopLayerCeiling = 0

    private(set) var hoveredWindow: Int?
    private var pressTargets: [Int: Int] = [:]

    var isPressed: Bool { !pressTargets.isEmpty }

    mutating func reset() {
        hoveredWindow = nil
        pressTargets = [:]
    }

    /// - Parameters:
    ///   - wallpaperWindow: our window covering the pointer, if any.
    ///   - frontWindow: the window number the window server would hit with a mouse down.
    ///   - layer: resolves a front window's `kCGWindowLayer`; `nil` for unknown windows.
    mutating func route(
        _ kind: Kind, wallpaperWindow: Int?, frontWindow: Int, layer: (Int) -> Int?
    ) -> Decision {
        switch kind {
        case .drag(let button), .up(let button):
            guard let target = pressTargets[button] else { return .ignore }
            if case .up = kind { pressTargets[button] = nil }
            return .deliver(to: target)
        case .move, .scroll, .down:
            break
        }
        let onDesktop: Int? = {
            guard let wallpaperWindow else { return nil }
            if frontWindow == wallpaperWindow { return wallpaperWindow }
            guard let layer = layer(frontWindow), layer < Self.desktopLayerCeiling else { return nil }
            return wallpaperWindow
        }()
        guard let target = onDesktop else {
            if case .scroll = kind { return .ignore }
            guard let previous = hoveredWindow else { return .ignore }
            hoveredWindow = nil
            return .exit(previous)
        }
        if case .down(let button) = kind { pressTargets[button] = target }
        if case .scroll = kind { return .deliver(to: target) }
        let previous = hoveredWindow
        hoveredWindow = target
        if let previous, previous != target { return .exitThenDeliver(exit: previous, to: target) }
        return .deliver(to: target)
    }
}

/// Mirrors desktop pointer input into web wallpaper pages. The wallpaper
/// windows stay mouse-transparent so Finder keeps owning icons and the system
/// keeps its own click handling; a global event monitor observes the same
/// events and replays them into the page under the pointer. Nothing is
/// consumed, so no Accessibility or Input Monitoring grant is involved.
@MainActor
final class WebWallpaperMouseForwarder {
    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .scrollWheel,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    ]

    private let windows: @MainActor () -> [WebWallpaperWindow]
    private var monitor: Any?
    private var routing = WebWallpaperMouseRouting()
    private var layers: [Int: Int] = [:]

    init(windows: @escaping @MainActor () -> [WebWallpaperWindow]) {
        self.windows = windows
    }

    var isActive: Bool { monitor != nil }

    func setActive(_ active: Bool) {
        if active {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            routing.reset()
            layers.removeAll()
        }
    }

    private func handle(_ event: NSEvent) {
        guard let kind = Self.kind(of: event) else { return }
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let windows = windows()
        let under = windows.first { $0.frame.contains(screenPoint) }
        let front = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        let decision = routing.route(kind, wallpaperWindow: under?.windowNumber, frontWindow: front) { [self] in layer(of: $0) }
        switch decision {
        case .ignore:
            break
        case .deliver(let number):
            deliver(event, screenPoint: screenPoint, to: number, in: windows)
        case .exit(let number):
            windows.first { $0.windowNumber == number }?.page.deliverMouseExit()
        case .exitThenDeliver(let exit, let number):
            windows.first { $0.windowNumber == exit }?.page.deliverMouseExit()
            deliver(event, screenPoint: screenPoint, to: number, in: windows)
        }
    }

    private func deliver(_ event: NSEvent, screenPoint: NSPoint, to number: Int, in windows: [WebWallpaperWindow]) {
        guard let window = windows.first(where: { $0.windowNumber == number }) else { return }
        let local = window.convertPoint(fromScreen: screenPoint)
        if let synthesized = Self.rebase(event, to: window, at: local) {
            window.page.deliverMouse(synthesized)
        }
    }

    /// Rebuilds the observed event as if the wallpaper window had received it.
    /// Scroll events cannot be created through `NSEvent`, so their `CGEvent`
    /// is copied with a location chosen so AppKit's window-less conversion
    /// (`x`, primary display height − `y`) lands on the wallpaper-local point.
    static func rebase(_ event: NSEvent, to window: NSWindow, at local: NSPoint) -> NSEvent? {
        if event.type == .scrollWheel {
            guard let copy = event.cgEvent?.copy() else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            copy.location = CGPoint(x: local.x, y: primaryHeight - local.y)
            return NSEvent(cgEvent: copy)
        }
        return NSEvent.mouseEvent(
            with: event.type, location: local, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.type == .mouseMoved ? 0 : event.clickCount, pressure: event.pressure)
    }

    static func kind(of event: NSEvent) -> WebWallpaperMouseRouting.Kind? {
        switch event.type {
        case .mouseMoved: return .move
        case .scrollWheel: return .scroll
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .down(button: event.buttonNumber)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .drag(button: event.buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .up(button: event.buttonNumber)
        default: return nil
        }
    }

    /// Window numbers are session-unique and the desktop windows are long
    /// lived, so a bounded cache makes the per-move lookup free.
    private func layer(of windowNumber: Int) -> Int? {
        if let cached = layers[windowNumber] { return cached }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return nil }
        if layers.count >= 256 { layers.removeAll(keepingCapacity: true) }
        layers[windowNumber] = layer
        return layer
    }
}
