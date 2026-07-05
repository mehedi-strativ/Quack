# Mouse Settings Tab — Design Spec

- **Date:** 2026-07-05
- **Status:** Approved (design), not yet implemented
- **Branch:** `mouse-action-buttons` (off `main`)

## Problem

Quack has no mouse-related features. Users with external mice want:

1. **Pointer sensitivity** control (faster/slower than the System Settings
   slider exposes conveniently, adjustable from the menu-bar app).
2. **Smooth scrolling** for discrete-wheel mice — macOS scrolls in coarse
   line-jumps; trackpad users get smooth pixel scrolling, wheel users don't.
3. **Custom actions for extra buttons** — many mice have buttons 4 and 5
   (side/back/forward buttons); macOS offers no remapping.

This spec adds a **Mouse** tab to Settings covering all three.

## Goals (v1)

- New "Mouse" tab in the Settings sidebar (Controls group).
- Sensitivity: slider writing the system pointer speed, applied live.
- Smooth scrolling: toggle; discrete wheel ticks become animated pixel
  scrolling (Mos-style). Trackpads unaffected.
- Buttons 4/5: per-button action picker with these actions:
  - Default (pass through — browser back/forward keeps working)
  - Mission Control, Application Windows (App Exposé), Show Desktop
  - Play/Pause, Next Track, Previous Track
  - Volume Up, Volume Down, Mute
  - Custom keyboard shortcut (user records a combo; Quack synthesizes it)
  - None (swallow the click)

## Non-goals (v1)

- No raw-delta sensitivity scaling via event tap (system pref only; no
  beyond-system range, no per-app sensitivity).
- No acceleration-curve editing.
- No remapping of buttons other than 4 and 5 (no middle-click remap).
- No per-app button profiles.
- No launch-app / window-snap / Launchpad actions.
- No scroll-direction (natural scrolling) override, no scroll speed slider
  beyond the fixed smooth-scroll tuning.

## Architecture

Follows the repo's one-tap-per-feature convention (`InputTaps.brightness` /
`.hotkey` / `.swipe`). Three independent units:

| Unit | Mechanism | Tap? |
|---|---|---|
| `MouseSensitivityService` | CFPreferences + IOHIDEventSystemClient | none |
| `ScrollSmootherService` | active tap on `scrollWheel` | own `EventTapThread` |
| `MouseButtonService` | active tap on `otherMouseDown/Up` | own `EventTapThread` |

Both taps follow the CLAUDE.md freeze-safety rules **exactly**: dedicated
thread, stop-and-recreate on every `com.apple.accessibility.api` distributed
notification (0.1 s delay), never gate on `AXIsProcessTrusted()`, re-enable
only on `tapDisabledByTimeout`, `CFMachPortInvalidate` old ports.

`InputTaps` gains two switches: `smoothScroll`, `mouseButtons`.

### Settings model (QuackKit)

`QuackSettings` additions (all with defaults so old JSON decodes):

```swift
// MARK: Mouse
public var mouseSensitivityEnabled: Bool          // default false
/// Pointer speed 0…3 (matches com.apple.mouse.scaling's practical range).
public var mouseSensitivity: Double               // default 1.0
/// System value captured before Quack first overrode it; restored on disable.
public var savedSystemMouseScaling: Double?       // default nil
public var smoothScrollEnabled: Bool              // default false
/// Raw values of MouseButtonAction.
public var mouseButton4Action: String             // default "default"
public var mouseButton5Action: String             // default "default"
/// Recorded custom shortcut per button (nil until recorded).
public var mouseButton4Shortcut: MouseShortcut?   // default nil
public var mouseButton5Shortcut: MouseShortcut?   // default nil
```

`MouseShortcut` is a small Codable struct: `keyCode: Int`,
`modifiers: Int` (bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧ — same convention as
`windowShortcutModifiers`).

`MouseButtonAction` — a new pure QuackKit enum, `String` raw values:
`default`, `missionControl`, `appExpose`, `showDesktop`, `playPause`,
`nextTrack`, `previousTrack`, `volumeUp`, `volumeDown`, `mute`,
`customShortcut`, `none`. Provides `title` for the picker UI.

`Feature` gains one case: `.mouse`, enabled when
`mouseSensitivityEnabled || smoothScrollEnabled || button4 != default ||
button5 != default`. A thin umbrella `MouseService: ManagedService` owns the
three units and starts/stops each per its own flag (mirrors how `.dockPinch`
covers two flags).

### Unit 1 — MouseSensitivityService

No event tap. Two-part apply (the LinearMouse approach):

1. **Persist:** `CFPreferencesSetValue("com.apple.mouse.scaling", value,
   kCFPreferencesAnyApplication, …)` + synchronize — keeps System Settings'
   slider in sync and survives reboot/replug.
2. **Live apply:** set the `HIDMouseAcceleration` property (fixed-point:
   `Int(value * 65536)`) on `IOHIDEventSystemClient` so changes take effect
   instantly.

Behavior:

- First enable: read and store the current system value into
  `savedSystemMouseScaling` before overriding.
- Toggle off / app quit (`applicationWillTerminate`): restore the saved value
  (both prefs and live), clear `savedSystemMouseScaling`.
- Slider changes debounced ~100 ms.
- `IOHIDEventSystemClient` is private API; if it fails, fall back to
  prefs-write-only and show a caption in the tab: "takes effect after
  replugging the mouse or logging in again". Failure is logged, never fatal.

### Unit 2 — ScrollSmootherService

Active tap on `scrollWheel`, own `EventTapThread`.

Callback (tap thread, fast path only):

- **Pass through untouched:** continuous events
  (`scrollWheelEventIsContinuous != 0` — trackpads, Magic Mouse), momentum
  events (`scrollWheelEventMomentumPhase != 0`), and Quack's own synthesized
  events, recognized by a magic number in `eventSourceUserData`.
- **Discrete wheel tick:** swallow (return nil), convert line deltas to pixels
  (~40 px/line, both axes), feed the animator.

`ScrollAnimator` (pure QuackKit, no CoreGraphics types, unit-testable):

- Accumulates pending distance per axis; consecutive ticks add up so fast
  flicks travel further.
- Ease-out exponential decay with a ~250 ms tail; `step(dt:)` returns the
  pixel delta to emit this frame and reports when idle.

Emission (still on the tap thread — no main-thread work, freeze-rule safe):

- 60 Hz `DispatchSourceTimer` on the tap thread's queue; suspended whenever
  the animator is idle.
- Each frame: build a `CGEvent(scrollWheelEvent2Source:)` with **pixel**
  units, continuous flag set, the original event's modifier flags, and the
  magic `eventSourceUserData`; post to `.cghidEventTap`.

### Unit 3 — MouseButtonService

Active tap on `otherMouseDown` + `otherMouseUp`, own `EventTapThread`.

- `buttonNumber` 3 → button 4, 4 → button 5 (zero-based). All other button
  numbers pass through.
- Configured action `default` → pass through untouched.
- Otherwise swallow **both** down and up; dispatch the action on **down** via
  `DispatchQueue.main.async` (never on the tap thread).

Action execution (`MouseActionPerformer`, main actor):

- **Media/volume** (playPause, next, previous, volumeUp/Down, mute):
  synthesize `NX_SYSDEFINED` media-key event pairs via `NSEvent.otherEvent`
  (the MonitorControl technique).
- **Mission Control / App Exposé / Show Desktop:** synthesize the standard
  system key events via `CGEvent` (Mission Control = ctrl+↑, App Exposé =
  ctrl+↓); Show Desktop falls back to `open -a "Mission Control"`-style
  invocation only if key synthesis proves unreliable — primary route is the
  F11-equivalent system key. Implementation may substitute the most reliable
  documented mechanism per action; the spec fixes the *user-visible effect*,
  not the exact API.
- **Custom shortcut:** synthesize keyDown+keyUp `CGEvent` with the stored
  keyCode + modifiers.
- **None:** nothing.

### Shortcut recorder (Settings UI)

When a button's action is "Custom shortcut", a small recorder field appears:
click it, press a combo, it stores `MouseShortcut` and displays it (e.g.
"⌘⇧K"). Recording uses a **local** `NSEvent` monitor inside the settings
window — no event tap involved. Esc cancels recording.

### Settings UI (Mouse tab)

`SettingsTab.mouse` — title "Mouse", icon `computermouse`, Controls group,
between Windows and Notch. Grouped `Form`, three sections:

1. **Pointer** — toggle "Override tracking speed" + slider (0…3, disabled
   when toggle off). Caption notes it changes the system-wide setting and
   restores the original when turned off.
2. **Scrolling** — toggle "Smooth scrolling" + caption ("Animates scroll-wheel
   ticks into smooth motion. Trackpads are unaffected.").
3. **Extra buttons** — two labeled rows, "Button 4" and "Button 5", each a
   `Picker` over `MouseButtonAction`; the recorder field appears under a row
   when its action is Custom shortcut. Caption notes buttons 4/5 are the side
   buttons on most mice.

Tab shows the standard Accessibility-permission hint (reusing the existing
permission-status pattern from the Windows tab) since both taps need it. The
sensitivity slider does **not** need Accessibility.

### Wiring

- `AppEnvironment` constructs `MouseService` (which owns the three units) and
  registers it under `Feature.mouse` in the coordinator's service map.
- `MouseService.start()`/`stop()` plus internal observation of the settings
  publisher decide which units run (same pattern as other services observing
  `SettingsStore`).
- Button-action changes and slider changes apply live without restarting the
  app.

## Error handling

- Tap creation returns nil (no Accessibility): services stay dormant; the tab
  shows the permission hint. No crash, no retry loop.
- HID private-API failure: prefs-only fallback + caption (see Unit 1).
- Synthesized-event feedback: prevented by the `eventSourceUserData` magic
  check in the scroll tap.
- App quit with sensitivity override active: restore saved system value in
  `applicationWillTerminate`.

## Testing

QuackKit unit tests (no AppKit/CoreGraphics dependencies):

- `ScrollAnimatorTests` — single tick produces total travel ≈ pixels-per-line;
  consecutive ticks accumulate; decay reaches idle within the tail duration;
  axes independent; zero-delta no-op.
- `MouseButtonActionTests` — raw-value round-trip for every case; unknown raw
  value falls back to `default`; titles non-empty.
- `SettingsStoreTests` additions — new fields decode with defaults from
  pre-existing JSON (missing keys); `MouseShortcut` round-trips.
- `FeatureTests` — `.mouse` enablement logic (any of the four conditions).

Tap layers, HID calls, and synthesized events: manual on-hardware
verification via `./Scripts/install.sh` (real mouse with buttons 4/5).

## File plan

| File | Change |
|---|---|
| `Sources/QuackKit/Models/QuackSettings.swift` | new fields + `MouseShortcut` |
| `Sources/QuackKit/Models/MouseButtonAction.swift` | new enum |
| `Sources/QuackKit/Mouse/ScrollAnimator.swift` | new, pure animator |
| `Sources/QuackKit/Coordinator/ManagedService.swift` | `Feature.mouse` |
| `Sources/Quack/Mouse/MouseService.swift` | new umbrella service |
| `Sources/Quack/Mouse/MouseSensitivityService.swift` | new |
| `Sources/Quack/Mouse/ScrollSmootherService.swift` | new tap |
| `Sources/Quack/Mouse/MouseButtonService.swift` | new tap |
| `Sources/Quack/Mouse/MouseActionPerformer.swift` | new |
| `Sources/Quack/Windows/InputTaps.swift` | two new switches |
| `Sources/Quack/Settings/SettingsView.swift` | Mouse tab + pane + recorder |
| `Sources/Quack/AppEnvironment.swift` | construct + register service |
| `Tests/QuackKitTests/…` | new tests per Testing section |
