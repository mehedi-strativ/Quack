import AppKit
import CoreGraphics

/// Owns the F1/F2 brightness-key event tap on a DEDICATED background thread.
///
/// An active session event tap intercepts every input event; if it lives on the
/// main run loop, a busy main thread (or Accessibility being revoked) stalls the
/// whole input pipeline and freezes the Mac. Running it on its own thread keeps
/// input flowing no matter what the main thread is doing.
///
/// The tap consumes a brightness key only when the cursor is on a DDC display
/// (decided via the thread-safe `ddcDisplayAt`); otherwise the key passes
/// through to the built-in display.
final class BrightnessKeyTap {
    struct Hit { let id: String; let name: String; let number: CGDirectDisplayID }

    /// The DDC display under `point` (Cocoa coords), or nil. Called on the tap
    /// thread — must be thread-safe.
    var ddcDisplayAt: ((CGPoint) -> Hit?)?
    /// Invoked (on the tap thread) when a brightness key is consumed.
    var onKey: ((_ increase: Bool, _ hit: Hit) -> Void)?

    private var thread: Thread?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let stateLock = NSLock()
    private var runLoopRef: CFRunLoop?
    private var running = false

    // System-defined (NSEvent type 14) brightness key codes.
    private static let brightnessUp: Int32 = 2
    private static let brightnessDown: Int32 = 3
    private static let auxButtonsSubtype = 8

    func start() {
        stateLock.lock(); let already = running; running = true; stateLock.unlock()
        if already { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.quack.brightnessKeyTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        stateLock.lock(); running = false; let rl = runLoopRef; stateLock.unlock()
        if let rl { CFRunLoopStop(rl) }   // wakes threadMain so it tears down
        thread = nil
    }

    private func threadMain() {
        let mask: CGEventMask = 1 << 14   // NSSystemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.brightness.error("Failed to create brightness key tap (Accessibility not effective?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        stateLock.lock(); runLoopRef = rl; stateLock.unlock()
        Log.brightness.log("Brightness key tap installed (dedicated thread)")

        CFRunLoopRun()   // blocks here until stop() calls CFRunLoopStop

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CFMachPortInvalidate(tap)   // fully dead — can't be reactivated on re-grant
        self.tap = nil
        self.source = nil
        stateLock.lock(); runLoopRef = nil; running = false; stateLock.unlock()
        Log.brightness.log("Brightness key tap removed")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // callback was slow; safe to re-enable
            return passthrough
        }
        if type == .tapDisabledByUserInput {
            // Accessibility was revoked. FULLY tear the tap down (don't leave it
            // disabled-but-alive): a lingering tap gets reactivated when access is
            // re-granted, and that reactivation during the TCC transition freezes
            // input. Stopping the run loop runs threadMain's teardown.
            stateLock.lock(); let rl = runLoopRef; stateLock.unlock()
            if let rl { CFRunLoopStop(rl) }
            return passthrough
        }

        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.auxButtonsSubtype else { return passthrough }
        let data1 = ns.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let isKeyDown = ((data1 & 0x0000FF00) >> 8) == 0x0A
        guard keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else { return passthrough }

        // Only route when the cursor is on a DDC-capable external display.
        guard let hit = ddcDisplayAt?(NSEvent.mouseLocation) else { return passthrough }
        if isKeyDown { onKey?(keyCode == Self.brightnessUp, hit) }
        return nil   // consume both key-down and key-up
    }
}
