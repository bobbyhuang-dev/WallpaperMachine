import CoreServices
import Foundation

/// A stoppable source of "this folder settled after changing" notifications.
///
/// Not `@MainActor`: `stop()` has to be reachable from a deinitializer.
protocol DirectoryWatching: AnyObject {
    func stop()
}

/// Watches one directory with FSEvents and reports a single settled change per burst.
///
/// File-level events are requested so a rewritten file is noticed too, not only an
/// added or deleted name: a staged entry that is a byte copy (the cross-volume case)
/// would otherwise keep serving stale content. There is no polling anywhere — the
/// stream is a kernel notification, and the debounce only collapses a burst that has
/// already arrived.
final class DirectoryWatcher: DirectoryWatching {
    /// FSEvents coalesces a little on its own; this collapses the rest of a burst, such
    /// as a folder being populated by a copy, into one diff.
    static let defaultDebounce: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "app.mac-wallpaper-engine.user-assets.watch")
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var stopped = false

    /// True when the stream is running. False means the folder will not report changes;
    /// already staged files stay valid.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    init(url: URL, debounce: TimeInterval = DirectoryWatcher.defaultDebounce, onChange: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        // FSEvents owns a reference for the lifetime of the stream and drops it through the
        // release callback, so a callback in flight can never see a deallocated watcher.
        // The cost is that `stop()` is what ends this object's life, not ARC alone.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil)
        // Deliberately not `IgnoreSelf`: a folder shared with this process must still
        // report its changes, and nothing here ever writes into a watched source folder.
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().scheduleSettle()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0, flags) else {
            Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
            AppLog.warn("user assets: cannot watch \(url.lastPathComponent) for changes")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            AppLog.warn("user assets: cannot start the change stream for \(url.lastPathComponent)")
            return
        }
        self.stream = stream
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        pending?.cancel()
        pending = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        // Invalidate runs the release callback, which may be this object's last reference.
        // Nothing may touch `self` after this point.
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func scheduleSettle() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        pending?.cancel()
        let handler = onChange
        let item = DispatchWorkItem {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
