import AppKit
import CoreGraphics
import QuackKit

/// Mos-style smooth scrolling: discrete scroll-wheel ticks are swallowed and
/// re-emitted as an ease-out stream of continuous pixel-scroll events.
///
/// Freeze-safety: the tap lives on a dedicated `EventTapThread`; the 60 Hz
/// emitter runs on its own utility queue (never the main thread, no slow
/// calls). Trackpad / Magic Mouse events (continuous), momentum events, and
/// our own synthesized events pass through untouched.
@MainActor
final class ScrollSmootherService {
    /// Marks Quack-synthesized scroll events so the tap never re-processes
    /// them (feedback loop). Arbitrary magic, just needs to be unlikely.
    /// Applied via the emitting `CGEventSource`'s `userData` (the Mos
    /// technique — the field is stamped onto every event the source posts)
    /// AND set directly on the event, belt and suspenders.
    private static let magicUserData: Int64 = 0x0051_ACC5

    private static let pixelsPerLine = 40.0
    private static let frameInterval = DispatchTimeInterval.milliseconds(16)  // ~60 Hz

    private let settings: SettingsStore
    private let permissions: PermissionsManager

    private var tap: EventTapThread?
    private var started = false
    private var axObserver: NSObjectProtocol?

    // Animator state — shared between the tap thread (add) and the emitter
    // queue (step). Guarded by `animLock`.
    private let animLock = NSLock()
    nonisolated(unsafe) private var animator = ScrollAnimator()
    nonisolated(unsafe) private var lastFlags = CGEventFlags()
    nonisolated(unsafe) private var timerRunning = false
    private nonisolated let emitQueue = DispatchQueue(label: "com.quack.scrollEmit", qos: .userInteractive)
    nonisolated(unsafe) private var timer: DispatchSourceTimer?

    /// Event source for synthesized scrolls; carries the magic marker in its
    /// `userData` so every posted event is identifiable in the tap. Created
    /// lazily on the emit queue.
    nonisolated(unsafe) private var emitSource: CGEventSource?

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
    }

    func start() {
        guard !started else { return }
        started = true

        if permissions.status(for: .accessibility) == .granted {
            reinstallTap()
        } else {
            permissions.requestAccessibilityAccess()
        }

        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in self?.reinstallTap() }
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        tap?.stop()
        tap = nil
        emitQueue.async { [weak self] in self?.cancelTimerOnQueue() }
        animLock.lock(); animator = ScrollAnimator(); animLock.unlock()
    }

    private func reinstallTap() {
        guard InputTaps.smoothScroll, started else { return }
        tap?.stop()
        let t = EventTapThread(
            mask: 1 << CGEventType.scrollWheel.rawValue,
            options: .defaultTap,
            label: "com.quack.scrollTap"
        ) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        tap = t
        t.start()
    }

    /// Runs on the tap thread — fast path only.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard type == .scrollWheel else { return passthrough }

        // Our own synthesized events: pass through, never re-smooth.
        if event.getIntegerValueField(.eventSourceUserData) == Self.magicUserData {
            return passthrough
        }
        // Trackpads / Magic Mouse emit continuous events; momentum likewise.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return passthrough }
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return passthrough }

        let lines1 = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))  // vertical
        let lines2 = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))  // horizontal
        if lines1 == 0 && lines2 == 0 { return passthrough }

        animLock.lock()
        animator.add(dx: lines2 * Self.pixelsPerLine, dy: lines1 * Self.pixelsPerLine)
        lastFlags = event.flags
        let needTimer = !timerRunning
        if needTimer { timerRunning = true }
        animLock.unlock()

        if needTimer { emitQueue.async { [weak self] in self?.startTimerOnQueue() } }
        return nil   // swallow the coarse tick — the emitter replaces it
    }

    // MARK: emitter (runs entirely on emitQueue)

    private nonisolated func startTimerOnQueue() {
        cancelTimerOnQueue()
        let t = DispatchSource.makeTimerSource(queue: emitQueue)
        t.schedule(deadline: .now(), repeating: Self.frameInterval)
        t.setEventHandler { [weak self] in self?.emitFrame() }
        timer = t
        t.resume()
    }

    private nonisolated func cancelTimerOnQueue() {
        timer?.cancel()
        timer = nil
    }

    private nonisolated func emitFrame() {
        animLock.lock()
        let frame = animator.step(dt: 0.016)
        let flags = lastFlags
        let done = animator.isIdle
        if done { timerRunning = false }
        animLock.unlock()

        if let frame, frame.dx != 0 || frame.dy != 0 {
            postPixelScroll(dx: frame.dx, dy: frame.dy, flags: flags)
        }
        if done { cancelTimerOnQueue() }
    }

    /// Synthesizes a continuous (pixel-unit) scroll event carrying our magic
    /// marker and the original modifier flags.
    private nonisolated func postPixelScroll(dx: Double, dy: Double, flags: CGEventFlags) {
        if emitSource == nil {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.userData = Self.magicUserData
            emitSource = src
        }
        guard let ev = CGEvent(scrollWheelEvent2Source: emitSource,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(dy.rounded()),
                               wheel2: Int32(dx.rounded()),
                               wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.eventSourceUserData, value: Self.magicUserData)
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
}
