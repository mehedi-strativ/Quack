# Mouse Settings Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Mouse" settings tab providing pointer-sensitivity override, Mos-style smooth scrolling for discrete wheel mice, and custom actions for mouse buttons 4/5.

**Architecture:** Three independent units behind one `Feature.mouse` umbrella service: `MouseSensitivityService` (no tap — CFPreferences + private HID client), `ScrollSmootherService` (active `scrollWheel` tap + pure `ScrollAnimator` in QuackKit), `MouseButtonService` (active `otherMouseDown/Up` tap + `MouseActionPerformer`). Both taps use the existing `EventTapThread` and the MonitorControl stop/recreate lifecycle.

**Tech Stack:** Swift 5 / SwiftPM, SwiftUI settings Form, CoreGraphics event taps, IOKit (dlsym'd private HID symbols), Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-07-05-mouse-settings-design.md`

## Global Constraints

- **CGEvent tap freeze-safety (CLAUDE.md — mandatory):** every tap on a dedicated thread via `EventTapThread` (never `CFRunLoopGetMain()`); stop AND recreate the tap (new instance) 0.1 s after every `com.apple.accessibility.api` distributed notification; never gate recreation on `AXIsProcessTrusted()`; never re-enable on `tapDisabledByUserInput`; slow work off the tap thread. `EventTapThread` already implements the thread + disable semantics — services must implement the observe/recreate part (copy `HotkeyMonitor`).
- Tap callbacks must be fast: no allocation-heavy work, no AX/DDC/HID calls, no main-thread hops for the pass-through decision.
- All new `QuackSettings` fields need defaults so existing persisted JSON decodes (the custom `init(from:)` pattern).
- Tests use Swift Testing, not XCTest. Run with `swift test`.
- Build check: `swift build`. The running app is `/Applications/Quack.app` — manual verification requires `./Scripts/install.sh`.
- QuackKit stays pure: no AppKit/CoreGraphics imports in new QuackKit files.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `MouseButtonAction` + `MouseShortcut` models (QuackKit)

**Files:**
- Create: `Sources/QuackKit/Models/MouseButtonAction.swift`
- Test: `Tests/QuackKitTests/MouseModelTests.swift`

**Interfaces:**
- Produces: `public enum MouseButtonAction: String, CaseIterable, Codable, Sendable` with cases `default_` (raw `"default"`), `missionControl`, `appExpose`, `showDesktop`, `playPause`, `nextTrack`, `previousTrack`, `volumeUp`, `volumeDown`, `mute`, `customShortcut`, `disabled` (raw `"none"`); `static func from(_ raw: String) -> MouseButtonAction`; `var title: String`.
- Produces: `public struct MouseShortcut: Codable, Equatable, Sendable { public var keyCode: Int; public var modifiers: Int; public init(keyCode:modifiers:); public var display: String }`. Modifier bits: bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧ (same as `windowShortcutModifiers`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/MouseModelTests.swift
import Testing
@testable import QuackKit

@Suite struct MouseButtonActionTests {
    @Test func rawValueRoundTrip() {
        for action in MouseButtonAction.allCases {
            #expect(MouseButtonAction.from(action.rawValue) == action)
        }
    }
    @Test func unknownRawFallsBackToDefault() {
        #expect(MouseButtonAction.from("garbage") == .default_)
        #expect(MouseButtonAction.from("") == .default_)
    }
    @Test func stableRawValues() {
        // Persisted in settings JSON — must never change.
        #expect(MouseButtonAction.default_.rawValue == "default")
        #expect(MouseButtonAction.disabled.rawValue == "none")
        #expect(MouseButtonAction.customShortcut.rawValue == "customShortcut")
    }
    @Test func titlesNonEmpty() {
        for action in MouseButtonAction.allCases { #expect(!action.title.isEmpty) }
    }
}

@Suite struct MouseShortcutTests {
    @Test func codableRoundTrip() throws {
        let s = MouseShortcut(keyCode: 40, modifiers: 0b1001)   // ⌘⇧K
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(MouseShortcut.self, from: data) == s)
    }
    @Test func displayShowsModifiersAndKey() {
        // Canonical macOS modifier order: ⌃⌥⇧⌘.
        #expect(MouseShortcut(keyCode: 40, modifiers: 0b1001).display == "⇧⌘K")
        #expect(MouseShortcut(keyCode: 126, modifiers: 0b0100).display == "⌃↑")
    }
    @Test func displayFallsBackForUnknownKey() {
        #expect(MouseShortcut(keyCode: 999, modifiers: 0b0001).display == "⌘key999")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MouseModelTests`
Expected: compile FAILURE — `MouseButtonAction` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/QuackKit/Models/MouseButtonAction.swift
import Foundation

/// What a remapped extra mouse button (4 or 5) does. Raw values are persisted
/// in `QuackSettings` — never change them.
public enum MouseButtonAction: String, CaseIterable, Codable, Sendable {
    case default_ = "default"      // pass through untouched (browser back/forward)
    case missionControl
    case appExpose
    case showDesktop
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
    case customShortcut
    case disabled = "none"         // swallow the click, do nothing

    public static func from(_ raw: String) -> MouseButtonAction {
        MouseButtonAction(rawValue: raw) ?? .default_
    }

    public var title: String {
        switch self {
        case .default_: return "Default (back / forward)"
        case .missionControl: return "Mission Control"
        case .appExpose: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .customShortcut: return "Keyboard Shortcut…"
        case .disabled: return "Do Nothing"
        }
    }
}

/// A recorded keyboard shortcut for `MouseButtonAction.customShortcut`.
/// `modifiers` uses the same bitmask convention as `windowShortcutModifiers`:
/// bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧.
public struct MouseShortcut: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Human-readable form, e.g. "⌘⇧K". Symbol order matches macOS: ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if modifiers & 0b0100 != 0 { s += "⌃" }
        if modifiers & 0b0010 != 0 { s += "⌥" }
        if modifiers & 0b1000 != 0 { s += "⇧" }
        if modifiers & 0b0001 != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Names for common virtual key codes (ANSI layout). Unknown codes render
    /// as "key<code>" — ugly but unambiguous.
    private static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "key\(code)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MouseModelTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Models/MouseButtonAction.swift Tests/QuackKitTests/MouseModelTests.swift
git commit -m "feat(mouse): MouseButtonAction + MouseShortcut models

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `QuackSettings` mouse fields

**Files:**
- Modify: `Sources/QuackKit/Models/QuackSettings.swift`
- Test: `Tests/QuackKitTests/SettingsStoreTests.swift` (append)

**Interfaces:**
- Produces (on `QuackSettings`): `mouseSensitivityEnabled: Bool` (false), `mouseSensitivity: Double` (1.0), `savedSystemMouseScaling: Double?` (nil), `smoothScrollEnabled: Bool` (false), `mouseButton4Action: String` ("default"), `mouseButton5Action: String` ("default"), `mouseButton4Shortcut: MouseShortcut?` (nil), `mouseButton5Shortcut: MouseShortcut?` (nil).

- [ ] **Step 1: Write the failing test**

Append to `Tests/QuackKitTests/SettingsStoreTests.swift`:

```swift
@Suite struct MouseSettingsDecodingTests {
    @Test func mouseFieldsDefaultWhenMissing() throws {
        // A pre-mouse settings blob must decode with mouse defaults.
        let old = #"{"calendarEnabled": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(QuackSettings.self, from: old)
        #expect(s.mouseSensitivityEnabled == false)
        #expect(s.mouseSensitivity == 1.0)
        #expect(s.savedSystemMouseScaling == nil)
        #expect(s.smoothScrollEnabled == false)
        #expect(s.mouseButton4Action == "default")
        #expect(s.mouseButton5Action == "default")
        #expect(s.mouseButton4Shortcut == nil)
        #expect(s.mouseButton5Shortcut == nil)
    }
    @Test func mouseFieldsRoundTrip() throws {
        var s = QuackSettings()
        s.mouseSensitivityEnabled = true
        s.mouseSensitivity = 2.5
        s.savedSystemMouseScaling = 0.6875
        s.smoothScrollEnabled = true
        s.mouseButton4Action = MouseButtonAction.missionControl.rawValue
        s.mouseButton5Action = MouseButtonAction.customShortcut.rawValue
        s.mouseButton5Shortcut = MouseShortcut(keyCode: 40, modifiers: 0b0001)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(QuackSettings.self, from: data)
        #expect(back == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MouseSettingsDecodingTests`
Expected: compile FAILURE — `mouseSensitivityEnabled` not a member.

- [ ] **Step 3: Add the fields**

In `Sources/QuackKit/Models/QuackSettings.swift`, four edits following the existing pattern exactly:

1. Properties (after the `// MARK: Appearance` block, before `public init(`):

```swift
    // MARK: Mouse
    /// Override the system pointer tracking speed.
    public var mouseSensitivityEnabled: Bool
    /// Pointer speed 0…3 (com.apple.mouse.scaling's practical range).
    public var mouseSensitivity: Double
    /// System scaling captured before Quack first overrode it; restored on
    /// disable / quit. nil = never overridden.
    public var savedSystemMouseScaling: Double?
    /// Animate discrete scroll-wheel ticks into smooth pixel scrolling.
    public var smoothScrollEnabled: Bool
    /// Raw values of `MouseButtonAction` for mouse buttons 4 and 5.
    public var mouseButton4Action: String
    public var mouseButton5Action: String
    /// Recorded combo used when the action is `customShortcut`.
    public var mouseButton4Shortcut: MouseShortcut?
    public var mouseButton5Shortcut: MouseShortcut?
```

2. `init` parameters (append before the closing paren, after `appearance:`):

```swift
        appearance: String = AppAppearance.system.rawValue,
        mouseSensitivityEnabled: Bool = false,
        mouseSensitivity: Double = 1.0,
        savedSystemMouseScaling: Double? = nil,
        smoothScrollEnabled: Bool = false,
        mouseButton4Action: String = "default",
        mouseButton5Action: String = "default",
        mouseButton4Shortcut: MouseShortcut? = nil,
        mouseButton5Shortcut: MouseShortcut? = nil
```

3. `init` body assignments (append after `self.appearance = appearance`):

```swift
        self.mouseSensitivityEnabled = mouseSensitivityEnabled
        self.mouseSensitivity = mouseSensitivity
        self.savedSystemMouseScaling = savedSystemMouseScaling
        self.smoothScrollEnabled = smoothScrollEnabled
        self.mouseButton4Action = mouseButton4Action
        self.mouseButton5Action = mouseButton5Action
        self.mouseButton4Shortcut = mouseButton4Shortcut
        self.mouseButton5Shortcut = mouseButton5Shortcut
```

4. `init(from decoder:)` (append after `appearance = v(...)`). The `v` helper
   returns non-optional `T`, so optional fields decode with `T = Double?` /
   `T = MouseShortcut?` — that works because `Optional: Decodable`:

```swift
        mouseSensitivityEnabled = v(.mouseSensitivityEnabled, d.mouseSensitivityEnabled)
        mouseSensitivity = v(.mouseSensitivity, d.mouseSensitivity)
        savedSystemMouseScaling = v(.savedSystemMouseScaling, d.savedSystemMouseScaling)
        smoothScrollEnabled = v(.smoothScrollEnabled, d.smoothScrollEnabled)
        mouseButton4Action = v(.mouseButton4Action, d.mouseButton4Action)
        mouseButton5Action = v(.mouseButton5Action, d.mouseButton5Action)
        mouseButton4Shortcut = v(.mouseButton4Shortcut, d.mouseButton4Shortcut)
        mouseButton5Shortcut = v(.mouseButton5Shortcut, d.mouseButton5Shortcut)
```

Note: `QuackSettings` synthesizes `CodingKeys` — new properties get keys
automatically; no `CodingKeys` edit exists to make (it's compiler-synthesized).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MouseSettingsDecodingTests && swift test --filter SettingsStoreTests`
Expected: all PASS (old suites too — decode-with-defaults untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Models/QuackSettings.swift Tests/QuackKitTests/SettingsStoreTests.swift
git commit -m "feat(mouse): settings fields for sensitivity, smooth scroll, button actions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `Feature.mouse`

**Files:**
- Modify: `Sources/QuackKit/Coordinator/ManagedService.swift`
- Test: `Tests/QuackKitTests/MouseModelTests.swift` (append)

**Interfaces:**
- Produces: `Feature.mouse` case; enabled when any of: `mouseSensitivityEnabled`, `smoothScrollEnabled`, `mouseButton4Action != "default"`, `mouseButton5Action != "default"`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/QuackKitTests/MouseModelTests.swift`:

```swift
@Suite struct MouseFeatureTests {
    @Test func disabledByDefault() {
        #expect(Feature.mouse.isEnabled(in: QuackSettings()) == false)
    }
    @Test func anySubFeatureEnables() {
        var s = QuackSettings(); s.mouseSensitivityEnabled = true
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.smoothScrollEnabled = true
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.mouseButton4Action = MouseButtonAction.missionControl.rawValue
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.mouseButton5Action = MouseButtonAction.disabled.rawValue
        #expect(Feature.mouse.isEnabled(in: s))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MouseFeatureTests`
Expected: compile FAILURE — `Feature` has no member `mouse`.

- [ ] **Step 3: Implement**

In `Sources/QuackKit/Coordinator/ManagedService.swift` add the case after `case notch`:

```swift
    case mouse
```

and in `isEnabled(in:)` after the `.notch` line:

```swift
        case .mouse:
            return settings.mouseSensitivityEnabled
                || settings.smoothScrollEnabled
                || settings.mouseButton4Action != MouseButtonAction.default_.rawValue
                || settings.mouseButton5Action != MouseButtonAction.default_.rawValue
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MouseFeatureTests && swift test --filter PermissionAndCoordinatorTests`
Expected: PASS. (`swift build` will still fail until Task 9 registers the
service — no: `AppEnvironment`'s service map simply won't include `.mouse` yet,
which is legal; the coordinator dictionary doesn't require every case. Verify
with `swift build` — expected: success.)

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Coordinator/ManagedService.swift Tests/QuackKitTests/MouseModelTests.swift
git commit -m "feat(mouse): Feature.mouse umbrella flag

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ScrollAnimator` (pure QuackKit)

**Files:**
- Create: `Sources/QuackKit/Mouse/ScrollAnimator.swift`
- Test: `Tests/QuackKitTests/ScrollAnimatorTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ScrollAnimator: Sendable {
    public struct Frame: Equatable, Sendable { public var dx: Double; public var dy: Double }
    public init(tailSeconds: Double = 0.25)
    public var isIdle: Bool { get }
    public mutating func add(dx: Double, dy: Double)   // pixels to travel
    public mutating func step(dt: Double) -> Frame?    // nil when idle
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/ScrollAnimatorTests.swift
import Testing
@testable import QuackKit

@Suite struct ScrollAnimatorTests {
    /// Steps at 60 Hz until idle; returns total emitted per axis.
    private func drain(_ a: inout ScrollAnimator, maxSeconds: Double = 2) -> (x: Double, y: Double) {
        var x = 0.0, y = 0.0, t = 0.0
        let dt = 1.0 / 60.0
        while !a.isIdle && t < maxSeconds {
            if let f = a.step(dt: dt) { x += f.dx; y += f.dy }
            t += dt
        }
        return (x, y)
    }

    @Test func startsIdle() {
        var a = ScrollAnimator()
        #expect(a.isIdle)
        #expect(a.step(dt: 1.0 / 60.0) == nil)
    }

    @Test func emitsExactlyWhatWasAdded() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: -120)
        let total = drain(&a)
        #expect(abs(total.y - (-120)) < 0.001)
        #expect(total.x == 0)
        #expect(a.isIdle)
    }

    @Test func consecutiveTicksAccumulate() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: 40)
        let first = a.step(dt: 1.0 / 60.0)!.dy   // partially drained…
        a.add(dx: 0, dy: 40)                      // …then another tick lands
        let rest = drain(&a).y
        // Everything added eventually comes out.
        #expect(abs(first + rest - 80) < 0.001)
    }

    @Test func axesAreIndependent() {
        var a = ScrollAnimator()
        a.add(dx: 30, dy: -50)
        let total = drain(&a)
        #expect(abs(total.x - 30) < 0.001)
        #expect(abs(total.y - (-50)) < 0.001)
    }

    @Test func reachesIdleWithinTail() {
        var a = ScrollAnimator(tailSeconds: 0.25)
        a.add(dx: 0, dy: 400)
        var t = 0.0
        while !a.isIdle { _ = a.step(dt: 1.0 / 60.0); t += 1.0 / 60.0 }
        #expect(t < 0.5)   // decays well before 2× the tail
    }

    @Test func earlyFramesAreLargest() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: -300)
        let f1 = a.step(dt: 1.0 / 60.0)!
        let f2 = a.step(dt: 1.0 / 60.0)!
        #expect(abs(f1.dy) > abs(f2.dy))   // ease-out: big first, then decaying
    }

    @Test func zeroAddIsNoOp() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: 0)
        #expect(a.isIdle)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScrollAnimatorTests`
Expected: compile FAILURE — `ScrollAnimator` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/QuackKit/Mouse/ScrollAnimator.swift
import Foundation

/// Turns discrete scroll-wheel ticks into a smooth ease-out stream of pixel
/// deltas. Pure math — the caller owns timing and event synthesis.
///
/// Model: added distance goes into a per-axis "pending" pool. Each `step(dt:)`
/// emits `pending * (1 - e^(-dt/τ))` and shrinks the pool, an exponential
/// ease-out. τ is derived from `tailSeconds` so the pool is ~98% drained at
/// the tail (τ = tail/4). Sub-pixel remainders are flushed when the pool drops
/// below half a pixel, so totals are exact and the animation provably ends.
public struct ScrollAnimator: Sendable {
    public struct Frame: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
    }

    private var pendingX = 0.0
    private var pendingY = 0.0
    private let tau: Double

    public init(tailSeconds: Double = 0.25) {
        self.tau = max(0.01, tailSeconds) / 4
    }

    public var isIdle: Bool { pendingX == 0 && pendingY == 0 }

    /// Queue additional travel (pixels). Consecutive ticks pile up, so fast
    /// flicks glide further.
    public mutating func add(dx: Double, dy: Double) {
        pendingX += dx
        pendingY += dy
    }

    /// Advance by `dt` seconds. Returns the pixel delta to emit this frame,
    /// or nil when idle.
    public mutating func step(dt: Double) -> Frame? {
        if isIdle { return nil }
        let factor = 1 - exp(-dt / tau)
        var outX = pendingX * factor
        var outY = pendingY * factor
        pendingX -= outX
        pendingY -= outY
        // Flush sub-pixel tails so the animation ends and totals stay exact.
        if abs(pendingX) < 0.5 { outX += pendingX; pendingX = 0 }
        if abs(pendingY) < 0.5 { outY += pendingY; pendingY = 0 }
        return Frame(dx: outX, dy: outY)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScrollAnimatorTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Mouse/ScrollAnimator.swift Tests/QuackKitTests/ScrollAnimatorTests.swift
git commit -m "feat(mouse): ScrollAnimator — ease-out pixel-delta engine for smooth scrolling

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `MouseSensitivityService`

**Files:**
- Create: `Sources/Quack/Mouse/MouseSensitivityService.swift`
- Modify: `Sources/Quack/Log.swift` (add `mouse` logger)

**Interfaces:**
- Consumes: `SettingsStore` (`settings.settings`, `.update {}`, `.$settings` publisher), `Log`.
- Produces: `@MainActor final class MouseSensitivityService` with `func start()`, `func stop()`. No `ManagedService` conformance — the Task 9 umbrella owns lifecycle.

No unit tests (CFPreferences + private HID API — manual verification in Task 11).

- [ ] **Step 1: Add the logger**

In `Sources/Quack/Log.swift` after the `notch` line:

```swift
    static let mouse = Logger(subsystem: "com.quack.menubar", category: "mouse")
```

- [ ] **Step 2: Implement the service**

```swift
// Sources/Quack/Mouse/MouseSensitivityService.swift
import Foundation
import Combine
import QuackKit

/// Overrides the system pointer tracking speed. No event tap.
///
/// Two-part apply (the LinearMouse approach):
///  1. Persist `com.apple.mouse.scaling` in the global prefs domain so System
///     Settings stays in sync and the value survives reboot/replug.
///  2. Push `HIDMouseAcceleration` (fixed-point, ×65536) into the HID event
///     system via the private `IOHIDEventSystemClient` API so the change
///     applies instantly.
///
/// If the private API is unavailable (symbols missing / client rejected), the
/// prefs write still happens and `liveApplyAvailable` turns false — the UI
/// shows a "takes effect after replug/login" caption.
@MainActor
final class MouseSensitivityService: ObservableObject {
    /// False when the private HID client couldn't be used (prefs-only mode).
    @Published private(set) var liveApplyAvailable = true

    private let settings: SettingsStore
    private var cancellable: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?
    private var started = false

    // MARK: private HID API (dlsym'd — no headers for these)
    private typealias CreateSimpleClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetProperty = @convention(c) (AnyObject, CFString, CFTypeRef) -> Void
    private let hidClient: AnyObject?
    private let hidSetProperty: SetProperty?

    init(settings: SettingsStore) {
        self.settings = settings
        // Resolve the private symbols once. IOKit is already linked; use
        // RTLD_DEFAULT-style lookup via dlopen(nil).
        let handle = dlopen(nil, RTLD_NOW)
        if let createSym = dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient"),
           let setSym = dlsym(handle, "IOHIDEventSystemClientSetProperty") {
            let create = unsafeBitCast(createSym, to: CreateSimpleClient.self)
            hidSetProperty = unsafeBitCast(setSym, to: SetProperty.self)
            hidClient = create(kCFAllocatorDefault)?.takeRetainedValue()
        } else {
            hidClient = nil
            hidSetProperty = nil
        }
    }

    func start() {
        guard !started else { return }
        started = true

        if settings.settings.mouseSensitivityEnabled { apply() }

        // Debounced live apply on slider / toggle changes.
        cancellable = settings.$settings
            .map { (enabled: $0.mouseSensitivityEnabled, value: $0.mouseSensitivity) }
            .removeDuplicates(by: ==)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                if state.enabled { self?.apply() } else { self?.restore() }
            }

        // Quitting with an override active must not leave the Mac stuck on
        // Quack's value.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.settings.settings.mouseSensitivityEnabled else { return }
                self.restore()
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        cancellable = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        restore()
    }

    // MARK: apply / restore

    private func apply() {
        // Capture the pre-Quack system value once, so disable can restore it.
        if settings.settings.savedSystemMouseScaling == nil {
            let current = Self.readSystemScaling() ?? 0.6875   // macOS default (mid slider)
            settings.update { $0.savedSystemMouseScaling = current }
        }
        setScaling(settings.settings.mouseSensitivity)
    }

    private func restore() {
        guard let saved = settings.settings.savedSystemMouseScaling else { return }
        setScaling(saved)
        settings.update { $0.savedSystemMouseScaling = nil }
    }

    private func setScaling(_ value: Double) {
        // 1. Persist for System Settings + reboot.
        CFPreferencesSetValue("com.apple.mouse.scaling" as CFString,
                              NSNumber(value: value),
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
        // 2. Live apply through the HID event system.
        if let client = hidClient, let setProp = hidSetProperty {
            let fixed = NSNumber(value: Int(value * 65536))
            setProp(client, "HIDMouseAcceleration" as CFString, fixed)
            if !liveApplyAvailable { liveApplyAvailable = true }
        } else {
            liveApplyAvailable = false
            Log.mouse.error("HID live apply unavailable — wrote prefs only (takes effect after replug/login)")
        }
        Log.mouse.log("Pointer scaling set to \(value, privacy: .public)")
    }

    private static func readSystemScaling() -> Double? {
        let v = CFPreferencesCopyValue("com.apple.mouse.scaling" as CFString,
                                       kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost)
        return (v as? NSNumber)?.doubleValue
    }
}
```

Add `import AppKit` at the top (for `NSApplication.willTerminateNotification`).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success (service not yet referenced anywhere — that's Task 9).

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Mouse/MouseSensitivityService.swift Sources/Quack/Log.swift
git commit -m "feat(mouse): pointer-sensitivity service (prefs + live HID apply)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `MouseActionPerformer`

**Files:**
- Create: `Sources/Quack/Mouse/MouseActionPerformer.swift`

**Interfaces:**
- Consumes: `MouseButtonAction`, `MouseShortcut` (QuackKit).
- Produces: `@MainActor enum MouseActionPerformer { static func perform(_ action: MouseButtonAction, shortcut: MouseShortcut?) }`.

- [ ] **Step 1: Implement**

```swift
// Sources/Quack/Mouse/MouseActionPerformer.swift
import AppKit
import CoreGraphics
import QuackKit

/// Executes a remapped mouse-button action. Always called on the main actor
/// (dispatched from the tap thread) — never on the tap thread itself.
@MainActor
enum MouseActionPerformer {
    static func perform(_ action: MouseButtonAction, shortcut: MouseShortcut?) {
        switch action {
        case .default_, .disabled:
            break   // default never reaches here; disabled = swallow silently
        case .missionControl:
            postKeystroke(keyCode: 126, flags: .maskControl)          // ⌃↑
        case .appExpose:
            postKeystroke(keyCode: 125, flags: .maskControl)          // ⌃↓
        case .showDesktop:
            postKeystroke(keyCode: 103, flags: [])                    // F11 (default binding)
        case .playPause:
            postMediaKey(16)    // NX_KEYTYPE_PLAY
        case .nextTrack:
            postMediaKey(17)    // NX_KEYTYPE_NEXT
        case .previousTrack:
            postMediaKey(18)    // NX_KEYTYPE_PREVIOUS
        case .volumeUp:
            postMediaKey(0)     // NX_KEYTYPE_SOUND_UP
        case .volumeDown:
            postMediaKey(1)     // NX_KEYTYPE_SOUND_DOWN
        case .mute:
            postMediaKey(7)     // NX_KEYTYPE_MUTE
        case .customShortcut:
            guard let shortcut else { return }
            postKeystroke(keyCode: CGKeyCode(shortcut.keyCode),
                          flags: Self.flags(from: shortcut.modifiers))
        }
    }

    /// Synthesizes a full keyDown+keyUp pair with modifiers.
    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Synthesizes an NX_SYSDEFINED media-key press pair (subtype 8) — the
    /// same mechanism the keyboard's media keys use, so it reaches whichever
    /// app owns Now Playing (Music, Spotify, browsers…).
    private static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0x0a : 0x0b
            let data1 = Int((key << 16) | (state << 8))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Same bitmask convention as `windowShortcutModifiers` / `MouseShortcut`:
    /// bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧.
    private static func flags(from mask: Int) -> CGEventFlags {
        var flags = CGEventFlags()
        if mask & 0b0001 != 0 { flags.insert(.maskCommand) }
        if mask & 0b0010 != 0 { flags.insert(.maskAlternate) }
        if mask & 0b0100 != 0 { flags.insert(.maskControl) }
        if mask & 0b1000 != 0 { flags.insert(.maskShift) }
        return flags
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/Mouse/MouseActionPerformer.swift
git commit -m "feat(mouse): action performer — system keys, media keys, custom shortcuts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `MouseButtonService` (button 4/5 tap)

**Files:**
- Create: `Sources/Quack/Mouse/MouseButtonService.swift`
- Modify: `Sources/Quack/Windows/InputTaps.swift`

**Interfaces:**
- Consumes: `EventTapThread`, `InputTaps.mouseButtons`, `SettingsStore`, `PermissionsManager`, `MouseActionPerformer`, `MouseButtonAction`, `MouseShortcut`.
- Produces: `@MainActor final class MouseButtonService` with `start()` / `stop()`.

- [ ] **Step 1: Add the tap switch**

In `Sources/Quack/Windows/InputTaps.swift` add to the enum:

```swift
    static let mouseButtons = true  // buttons 4/5 remap
    static let smoothScroll = true  // wheel-tick smoothing
```

- [ ] **Step 2: Implement the service** (mirror of `HotkeyMonitor` — same lifecycle, different events)

```swift
// Sources/Quack/Mouse/MouseButtonService.swift
import AppKit
import CoreGraphics
import Combine
import QuackKit

/// Remaps mouse buttons 4 and 5 (`buttonNumber` 3 / 4 — zero-based) to custom
/// actions. The tap runs on a dedicated thread; on a match both the down and
/// up events are consumed and the action fires on the main actor from the
/// down event. Buttons left on "default" pass through untouched, so browser
/// back/forward keeps working. Requires Accessibility permission.
@MainActor
final class MouseButtonService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager

    private var tap: EventTapThread?
    private var started = false
    private var settingsCancellable: AnyCancellable?
    private var axObserver: NSObjectProtocol?

    /// Snapshot of the configured actions, read on the tap thread.
    private struct Config {
        var action4 = MouseButtonAction.default_
        var action5 = MouseButtonAction.default_
        var shortcut4: MouseShortcut?
        var shortcut5: MouseShortcut?
    }
    private let configLock = NSLock()
    nonisolated(unsafe) private var config = Config()

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
    }

    func start() {
        guard !started else { return }
        started = true
        refreshConfigSnapshot()
        settingsCancellable = settings.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.refreshConfigSnapshot() } }

        if permissions.status(for: .accessibility) == .granted {
            reinstallTap()
        } else {
            permissions.requestAccessibilityAccess()
        }

        // Stop + recreate on any Accessibility change (MonitorControl's proven
        // pattern — see CursorBrightnessService / CLAUDE.md).
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
        settingsCancellable = nil
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        tap?.stop()
        tap = nil
    }

    private func refreshConfigSnapshot() {
        let s = settings.settings
        let c = Config(
            action4: MouseButtonAction.from(s.mouseButton4Action),
            action5: MouseButtonAction.from(s.mouseButton5Action),
            shortcut4: s.mouseButton4Shortcut,
            shortcut5: s.mouseButton5Shortcut
        )
        configLock.lock(); config = c; configLock.unlock()
    }

    /// Fully tears down any existing tap and creates a fresh one. Ungated:
    /// `tapCreate` succeeds only when Accessibility is actually trusted.
    private func reinstallTap() {
        guard InputTaps.mouseButtons, started else { return }
        tap?.stop()
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let t = EventTapThread(
            mask: mask,
            options: .defaultTap,
            label: "com.quack.mouseButtonTap"
        ) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        tap = t
        t.start()
    }

    /// Runs on the tap thread. Decides synchronously whether to consume; the
    /// action itself is dispatched to the main actor.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard type == .otherMouseDown || type == .otherMouseUp else { return passthrough }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        configLock.lock(); let c = config; configLock.unlock()

        let action: MouseButtonAction
        let shortcut: MouseShortcut?
        switch button {
        case 3: action = c.action4; shortcut = c.shortcut4
        case 4: action = c.action5; shortcut = c.shortcut5
        default: return passthrough
        }
        guard action != .default_ else { return passthrough }

        if type == .otherMouseDown {
            DispatchQueue.main.async {
                MouseActionPerformer.perform(action, shortcut: shortcut)
            }
        }
        return nil   // consume both down and up
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Mouse/MouseButtonService.swift Sources/Quack/Windows/InputTaps.swift
git commit -m "feat(mouse): button 4/5 remap tap

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `ScrollSmootherService` (scroll tap + emitter)

**Files:**
- Create: `Sources/Quack/Mouse/ScrollSmootherService.swift`

**Interfaces:**
- Consumes: `EventTapThread`, `InputTaps.smoothScroll`, `ScrollAnimator` (Task 4), `SettingsStore`, `PermissionsManager`.
- Produces: `@MainActor final class ScrollSmootherService` with `start()` / `stop()`.

- [ ] **Step 1: Implement**

```swift
// Sources/Quack/Mouse/ScrollSmootherService.swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/Mouse/ScrollSmootherService.swift
git commit -m "feat(mouse): smooth-scrolling tap — wheel ticks become eased pixel scrolls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: `MouseService` umbrella + AppEnvironment wiring

**Files:**
- Create: `Sources/Quack/Mouse/MouseService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`

**Interfaces:**
- Consumes: the three unit services (Tasks 5, 7, 8), `ManagedService`, `Feature.mouse`, `SettingsStore`.
- Produces: `@MainActor final class MouseService: ManagedService` exposing `let sensitivity: MouseSensitivityService` (the settings UI reads `liveApplyAvailable` through it).

- [ ] **Step 1: Implement the umbrella**

```swift
// Sources/Quack/Mouse/MouseService.swift
import Foundation
import Combine
import QuackKit

/// Umbrella service for `Feature.mouse`. The coordinator starts/stops it when
/// the umbrella flag flips (any mouse sub-feature on); internally each unit
/// tracks its own toggle, so e.g. enabling smooth scrolling never installs
/// the button tap.
@MainActor
final class MouseService: ManagedService {
    let sensitivity: MouseSensitivityService
    private let smoother: ScrollSmootherService
    private let buttons: MouseButtonService

    private let settings: SettingsStore
    private var cancellable: AnyCancellable?
    private var started = false

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.sensitivity = MouseSensitivityService(settings: settings)
        self.smoother = ScrollSmootherService(settings: settings, permissions: permissions)
        self.buttons = MouseButtonService(settings: settings, permissions: permissions)
    }

    func start() {
        guard !started else { return }
        started = true
        applyFlags()
        cancellable = settings.$settings
            .map { (sens: $0.mouseSensitivityEnabled,
                    scroll: $0.smoothScrollEnabled,
                    b4: $0.mouseButton4Action, b5: $0.mouseButton5Action) }
            .removeDuplicates(by: ==)
            .sink { [weak self] _ in Task { @MainActor in self?.applyFlags() } }
    }

    func stop() {
        guard started else { return }
        started = false
        cancellable = nil
        sensitivity.stop()
        smoother.stop()
        buttons.stop()
    }

    private func applyFlags() {
        let s = settings.settings
        s.mouseSensitivityEnabled ? sensitivity.start() : sensitivity.stop()
        s.smoothScrollEnabled ? smoother.start() : smoother.stop()
        let buttonsWanted = s.mouseButton4Action != MouseButtonAction.default_.rawValue
            || s.mouseButton5Action != MouseButtonAction.default_.rawValue
        buttonsWanted ? buttons.start() : buttons.stop()
    }
}
```

(Note: `sensitivity.stop()` calls `restore()` internally, so turning the
toggle off restores the system tracking speed — both paths, the umbrella's
`applyFlags` and the unit's own settings sink, are idempotent via the
`started` guards.)

- [ ] **Step 2: Wire into AppEnvironment**

In `Sources/Quack/AppEnvironment.swift`:

1. Property, after `private let notchService: NotchService`:

```swift
    private let mouseService: MouseService
```

2. Construction, after `self.notchService = NotchService(...)`:

```swift
        self.mouseService = MouseService(settings: settings, permissions: permissions)
```

3. Service map — add to the `services` dictionary:

```swift
            .mouse: mouseService,
```

4. Expose the sensitivity unit for the settings pane. Add near
   `claudeIntegrationInstalled()`:

```swift
    /// The pointer-sensitivity unit (settings UI reads `liveApplyAvailable`).
    var mouseSensitivity: MouseSensitivityService { mouseService.sensitivity }
```

- [ ] **Step 3: Build + run full tests**

Run: `swift build && swift test`
Expected: build success, all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Mouse/MouseService.swift Sources/Quack/AppEnvironment.swift
git commit -m "feat(mouse): umbrella service wired into the coordinator

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Settings UI — Mouse tab

**Files:**
- Modify: `Sources/Quack/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsTab`/`SidebarGroup` enums, `SettingsPane` switch, `env.settingsStore.binding(_:)` (from `SettingsBinding.swift`), `env.permissions`, `env.mouseSensitivity.liveApplyAvailable`, `MouseButtonAction`, `MouseShortcut`.
- Produces: `SettingsTab.mouse`; `MousePointerSection`, `MouseScrollSection`, `MouseButtonsSection`, `ShortcutRecorderField` views.

- [ ] **Step 1: Add the tab**

In `SettingsTab` (top of `SettingsView.swift`):

- case list: `case general, calendar, temperature, display, windows, mouse, notch, settings`
- `title`: `case .mouse: return "Mouse"`
- `icon`: `case .mouse: return "computermouse"`
- `SidebarGroup.controls`: `return [.display, .windows, .mouse, .notch]`

In `SettingsPane.body`'s inner switch, after `case .windows:`:

```swift
                case .mouse:
                    MousePointerSection()
                    MouseScrollSection()
                    MouseButtonsSection()
```

- [ ] **Step 2: Add the sections** (append near the other section views, e.g. after `DockGesturesSection`)

```swift
// MARK: - Mouse

private struct MousePointerSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Pointer") {
            Toggle("Override tracking speed", isOn: s.binding(\.mouseSensitivityEnabled))
            Text("Sets the system-wide pointer speed. Turning this off restores the speed you had before.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if s.settings.mouseSensitivityEnabled {
                HStack {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: s.binding(\.mouseSensitivity), in: 0...3)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                if !env.mouseSensitivity.liveApplyAvailable {
                    Text("Live apply unavailable on this macOS — changes take effect after replugging the mouse or logging in again.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct MouseScrollSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Scrolling") {
            Toggle("Smooth scrolling", isOn: s.binding(\.smoothScrollEnabled))
            Text("Animates scroll-wheel ticks into smooth motion, like a trackpad. Trackpads and Magic Mouse are unaffected.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if s.settings.smoothScrollEnabled,
               env.permissions.status(for: .accessibility) != .granted {
                HStack {
                    Text("Requires Accessibility permission.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Button("Grant") { env.permissions.requestAccessibilityAccess() }
                }
            }
        }
    }
}

private struct MouseButtonsSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        let anyRemapped = s.settings.mouseButton4Action != MouseButtonAction.default_.rawValue
            || s.settings.mouseButton5Action != MouseButtonAction.default_.rawValue
        Section("Extra buttons") {
            buttonRow(label: "Button 4",
                      action: \.mouseButton4Action, shortcut: \.mouseButton4Shortcut)
            buttonRow(label: "Button 5",
                      action: \.mouseButton5Action, shortcut: \.mouseButton5Shortcut)
            Text("Buttons 4 and 5 are the side (back/forward) buttons on most mice.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if anyRemapped, env.permissions.status(for: .accessibility) != .granted {
                HStack {
                    Text("Requires Accessibility permission.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Button("Grant") { env.permissions.requestAccessibilityAccess() }
                }
            }
        }
    }

    @ViewBuilder
    private func buttonRow(label: String,
                           action: WritableKeyPath<QuackSettings, String>,
                           shortcut: WritableKeyPath<QuackSettings, MouseShortcut?>) -> some View {
        let s = env.settingsStore
        let actionBinding = Binding<MouseButtonAction>(
            get: { MouseButtonAction.from(s.settings[keyPath: action]) },
            set: { new in s.update { $0[keyPath: action] = new.rawValue } }
        )
        Picker(label, selection: actionBinding) {
            ForEach(MouseButtonAction.allCases, id: \.self) { a in
                Text(a.title).tag(a)
            }
        }
        if actionBinding.wrappedValue == .customShortcut {
            ShortcutRecorderField(shortcut: s.binding(shortcut))
        }
    }
}

/// Click-to-record keyboard shortcut field. Recording uses a local NSEvent
/// monitor (only sees keys while Quack's settings window is focused) — no
/// event tap, no extra permissions. Esc cancels.
private struct ShortcutRecorderField: View {
    @Binding var shortcut: MouseShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press keys… (⎋ cancels)" : (shortcut?.display ?? "Record Shortcut"))
                    .frame(minWidth: 140)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc — cancel, keep old value
            var mask = 0
            if event.modifierFlags.contains(.command) { mask |= 0b0001 }
            if event.modifierFlags.contains(.option) { mask |= 0b0010 }
            if event.modifierFlags.contains(.control) { mask |= 0b0100 }
            if event.modifierFlags.contains(.shift) { mask |= 0b1000 }
            shortcut = MouseShortcut(keyCode: Int(event.keyCode), modifiers: mask)
            return nil   // consume — don't let the combo trigger anything
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 3: Build + full tests**

Run: `swift build && swift test`
Expected: success / all PASS. (`SettingsTab` is `CaseIterable` — the Dashboard
and sidebar loops pick the new case up automatically; the `.mouse` pane is
explicit in the switch so nothing falls through to `EmptyView`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(mouse): Mouse settings tab — pointer, scrolling, extra buttons

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Install + manual verification

**Files:** none (verification only).

- [ ] **Step 1: Full build + tests**

Run: `swift build && swift test`
Expected: success, all suites PASS.

- [ ] **Step 2: Install the bundle**

Run: `./Scripts/install.sh`
Expected: rebuilds and relaunches `/Applications/Quack.app`. Per CLAUDE.md, if
Accessibility was re-granted just before this step, skip the rebuild and only
`open /Applications/Quack.app`.

- [ ] **Step 3: Manual checklist** (needs a mouse with a scroll wheel + buttons 4/5)

Report each result to the user; stop and debug on any failure:

1. Settings window shows **Mouse** tab between Windows and Notch, mouse icon.
2. **Pointer**: enable override, drag slider → cursor speed changes live (or
   the orange prefs-only caption appears and System Settings → Mouse shows the
   moved slider). Disable → speed returns to the original.
3. **Scrolling**: enable, scroll a wheel in a long page → motion glides
   instead of jumping lines. Trackpad scroll unchanged. Shift+wheel still
   scrolls horizontally where apps support it.
4. **Buttons**: set Button 4 → Mission Control → pressing it opens Mission
   Control; set Button 5 → Custom shortcut, record ⌘T in a browser → opens a
   tab. Set both back to Default → back/forward works again in the browser.
5. **Freeze-safety regression drill** (CLAUDE.md): with smooth scrolling and a
   button remap active, toggle Quack's Accessibility off and on in System
   Settings → input must keep flowing (no freeze); features resume after
   re-grant.
6. Quit Quack with sensitivity override on → System Settings shows the
   original tracking speed restored.

- [ ] **Step 4: Update README feature list** (if the verification passes)

`README.md` has a feature list — add one line for the Mouse tab following its
existing tone. Read the file first; match style.

- [ ] **Step 5: Final commit + push**

```bash
git add README.md
git commit -m "docs: README entry for the Mouse tab

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin mouse-action-buttons
```
