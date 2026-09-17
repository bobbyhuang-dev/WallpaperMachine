import Foundation

/// Which wallpaper surface a counter belongs to. Display identity is the stable
/// `CGDirectDisplayID`; `generation` separates two surfaces that reused one
/// display id across a hot-plug or a wallpaper switch.
struct RuntimeSurfaceKey: Hashable, Sendable {
    enum Kind: String, Sendable {
        case desktopScene
        case desktopWeb
        case lockScreen
        case preview
    }

    let kind: Kind
    let displayID: UInt32
    let generation: UInt64

    init(kind: Kind, displayID: UInt32, generation: UInt64 = 0) {
        self.kind = kind
        self.displayID = displayID
        self.generation = generation
    }
}

/// The events this project counts to decide whether invisible work actually
/// stopped. Every case is incremented by production code; there are no
/// placeholders for metrics nothing reports yet.
enum RuntimeCounter: String, CaseIterable, Sendable {
    /// An effective-suspend decision was delivered to the renderer or page.
    case presentationSuspended
    /// An effective-resume decision was delivered.
    case presentationResumed
    /// A page was asked to suspend media playback through the host API.
    case webMediaSuspended
    case webMediaResumed
    /// A web view left the window tree so WebKit can apply its inactive policy.
    case webDetached
    case webAttached
    /// A `WKWebView` was constructed for a display.
    case webPageCreated
    /// Committed host state was replayed into a new document generation.
    case webStateReplayed
    /// A content-process termination started a restart.
    case webRecoveryStarted
    /// The restart budget rejected a further restart within its window.
    case webRecoveryBudgetExhausted
    /// A pointer sample reached a surface.
    case pointerDelivered
    /// A lock-screen or preview surface was allowed to keep presenting.
    case presentationAuthorized
    /// A surface produced the one frame a readiness or snapshot request needs,
    /// which is deliberately not the same as being allowed to keep presenting.
    case readinessFrameRendered
}

/// Time-limited, aggregated runtime counters. Off by default: recording happens
/// only inside an explicitly opened diagnostic session, so release builds carry
/// no per-frame bookkeeping. Counts are per surface and the surface table is
/// bounded; overflow is reported rather than silently growing.
///
/// This is the observability half of the power work: a claim that hidden
/// surfaces stopped working has to be readable from `snapshot()` rather than
/// inferred from CPU graphs. It is compiled into both the application and the
/// lock-screen extension, so the two processes count the same events the same
/// way instead of growing separate vocabularies.
@MainActor
final class RuntimeCounters {
    static let shared = RuntimeCounters()

    static let maximumTrackedSurfaces = 16

    struct Snapshot: Equatable, Sendable {
        var isRecording = false
        var sessionElapsed: Duration = .zero
        var surfaces: [RuntimeSurfaceKey: [RuntimeCounter: UInt64]] = [:]
        /// Increments recorded for surfaces evicted by the table bound.
        var droppedSurfaceEvents: UInt64 = 0

        func value(_ counter: RuntimeCounter, for surface: RuntimeSurfaceKey) -> UInt64 {
            surfaces[surface]?[counter] ?? 0
        }

        func total(_ counter: RuntimeCounter) -> UInt64 {
            surfaces.values.reduce(0) { $0 + ($1[counter] ?? 0) }
        }
    }

    private let now: @MainActor () -> ContinuousClock.Instant
    private var sessionStart: ContinuousClock.Instant?
    private var sessionDuration: Duration = .zero
    private var counts: [RuntimeSurfaceKey: [RuntimeCounter: UInt64]] = [:]
    /// Insertion order, so the bound evicts the least recently seen surface.
    private var order: [RuntimeSurfaceKey] = []
    private var droppedSurfaceEvents: UInt64 = 0

    init(now: (@MainActor () -> ContinuousClock.Instant)? = nil) {
        self.now = now ?? { ContinuousClock.now }
    }

    /// Opens a recording session that expires on its own. A session is bounded
    /// so a forgotten diagnostic switch cannot keep counting forever.
    func startSession(duration: Duration) {
        guard duration > .zero else { return }
        counts.removeAll()
        order.removeAll()
        droppedSurfaceEvents = 0
        sessionStart = now()
        sessionDuration = duration
    }

    func endSession() {
        sessionStart = nil
        sessionDuration = .zero
    }

    var isRecording: Bool {
        guard let sessionStart else { return false }
        return now() - sessionStart < sessionDuration
    }

    func record(_ counter: RuntimeCounter, for surface: RuntimeSurfaceKey, by amount: UInt64 = 1) {
        guard amount > 0, isRecording else { return }
        if counts[surface] == nil {
            if order.count >= Self.maximumTrackedSurfaces {
                let evicted = order.removeFirst()
                droppedSurfaceEvents += counts.removeValue(forKey: evicted)?.values.reduce(0, +) ?? 0
            }
            order.append(surface)
            counts[surface] = [:]
        }
        counts[surface, default: [:]][counter, default: 0] += amount
    }

    func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.isRecording = isRecording
        if let sessionStart { snapshot.sessionElapsed = now() - sessionStart }
        snapshot.surfaces = counts
        snapshot.droppedSurfaceEvents = droppedSurfaceEvents
        return snapshot
    }

    /// One aggregated line per surface, in the field order
    /// [docs/testing/power-benchmark.md](../../../docs/testing/power-benchmark.md)
    /// documents. Never emitted per frame.
    func aggregatedReport() -> [String] {
        order.compactMap { surface in
            guard let values = counts[surface], !values.isEmpty else { return nil }
            let fields = RuntimeCounter.allCases
                .compactMap { counter -> String? in
                    guard let value = values[counter], value > 0 else { return nil }
                    return "\(counter.rawValue)=\(value)"
                }
            return "surface=\(surface.kind.rawValue)/\(surface.displayID)"
                + "/gen\(surface.generation) " + fields.joined(separator: " ")
        }
    }
}
