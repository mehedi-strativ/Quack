import CoreGraphics
import Foundation

/// Runs a `CGEventTap` on a DEDICATED background thread.
///
/// An active event tap intercepts every input event; if it lives on the main run
/// loop, any time the main thread is busy — or while Accessibility is being
/// revoked — the whole input pipeline stalls and the Mac freezes. Running the tap
/// on its own thread keeps input flowing regardless of the main thread.
///
/// The `handler` runs on the tap thread and must return quickly (dispatch slow
/// work to another queue). Tap-disabled notifications are handled internally:
/// a timeout re-enables the tap; an Accessibility revocation (`byUserInput`) is
/// NOT re-enabled (re-enabling there loops and freezes input).
final class EventTapThread {
    private let mask: CGEventMask
    private let options: CGEventTapOptions
    private let label: String
    private let handler: (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private var thread: Thread?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var runLoopRef: CFRunLoop?
    private var running = false

    init(mask: CGEventMask,
         options: CGEventTapOptions,
         label: String,
         handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        self.mask = mask
        self.options = options
        self.label = label
        self.handler = handler
    }

    func start() {
        lock.lock(); let already = running; running = true; lock.unlock()
        if already { return }
        let t = Thread { [weak self] in self?.main() }
        t.name = label
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); running = false; let rl = runLoopRef; lock.unlock()
        if let rl { CFRunLoopStop(rl) }   // wakes main() so it tears down
        thread = nil
    }

    private func main() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventTapThread>.fromOpaque(refcon).takeUnretainedValue().dispatch(type, event)
            },
            userInfo: refcon
        ) else {
            Log.swipe.error("Failed to create event tap '\(self.label, privacy: .public)' (Accessibility not effective?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        lock.lock(); runLoopRef = rl; lock.unlock()
        Log.swipe.log("Event tap '\(self.label, privacy: .public)' installed (dedicated thread)")

        CFRunLoopRun()   // blocks until stop()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CFMachPortInvalidate(tap)   // fully dead — can't be reactivated on re-grant
        self.tap = nil
        self.source = nil
        lock.lock(); runLoopRef = nil; running = false; lock.unlock()
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            // Accessibility revoked — fully tear down (don't leave a stale tap to
            // be reactivated on re-grant). The service also recreates the tap via
            // the accessibility notification.
            lock.lock(); let rl = runLoopRef; lock.unlock()
            if let rl { CFRunLoopStop(rl) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}
