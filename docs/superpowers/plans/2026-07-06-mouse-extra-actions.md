# Mouse Extra-Button Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Desktop Next/Previous as mouse-button actions, and stop the shortcut recorder from silently failing on OS-reserved key combos.

**Architecture:** Two independent, additive changes to the existing Mouse settings feature — no new files, no new types. (1) Two new `MouseButtonAction` cases wired straight into the existing synthetic-keystroke dispatch in `MouseActionPerformer`. (2) A static SwiftUI caption added to the existing custom-shortcut row in `SettingsView.swift`.

**Tech Stack:** Swift 5.9, SwiftPM (no Xcode project), SwiftUI + AppKit, `swift-testing` (`@Test`/`@Suite`, not XCTest).

**Spec:** `docs/superpowers/specs/2026-07-06-mouse-extra-actions-design.md`

## Global Constraints

- Do not touch the CGEvent input-tap lifecycle (`Sources/Quack/Windows/InputTaps.swift`, `EventTapThread`, or anything under the "tap must not freeze the Mac" rules in `CLAUDE.md`). Both tasks below are output-only (`CGEvent.post`) or static UI copy — neither listens for input.
- Desktop Next = ⌃→ → `postKeystroke(keyCode: 124, flags: .maskControl)`. Desktop Previous = ⌃← → `postKeystroke(keyCode: 123, flags: .maskControl)`. These are the macOS default Spaces-navigation bindings — exact values, do not substitute other keycodes.
- New `MouseButtonAction` cases use **implicit** raw values (case name = persisted string, matching `missionControl`/`appExpose`/etc.) — do not give them explicit `= "..."` raw values.
- New cases are declared after `showDesktop` and before `playPause` (drives dropdown order via `CaseIterable`).
- Recorder hint copy is verbatim: `"System shortcuts like ⌃+Arrow or ⌘Space can't be recorded here — use the action list above if there's a match."`
- Caption styling matches existing captions in `SettingsView.swift`: `.font(.system(size: 12)).foregroundStyle(.secondary)`.
- Do not change `ShortcutRecorderField`'s capture logic (the ⌘⌥⌃⇧ mask-building in its `NSEvent` monitor) — it already works correctly for anything that isn't OS-reserved.
- Full-project build command is `swift build` (builds the `Quack` executable target, which is NOT covered by `swift test` — `QuackKitTests` only depends on the `QuackKit` library target). Both tasks touch app-target files (`Sources/Quack/...`), so both need an explicit `swift build` verification, not just `swift test`.

---

### Task 1: Desktop Next/Previous mouse-button action

**Files:**
- Modify: `Sources/QuackKit/Models/MouseButtonAction.swift:9-10` (insert cases), `:28-29` (insert titles)
- Modify: `Sources/Quack/Mouse/MouseActionPerformer.swift:18-19` (insert dispatch arms)
- Test: `Tests/QuackKitTests/MouseModelTests.swift` (add assertion to `MouseButtonActionTests`)

**Interfaces:**
- Consumes: `MouseButtonAction` (existing `enum`, `String`/`CaseIterable`/`Codable`/`Sendable`), `MouseActionPerformer.postKeystroke(keyCode:flags:)` (existing `private static` helper, signature `(CGKeyCode, CGEventFlags) -> Void`).
- Produces: `MouseButtonAction.desktopNext`, `MouseButtonAction.desktopPrevious` — consumed by Task 2's dropdown (no code change needed there; `Picker` already iterates `allCases`) and by `MouseActionPerformer.perform(_:shortcut:)`.

- [ ] **Step 1: Write the failing test**

Add this test to the `MouseButtonActionTests` suite in `Tests/QuackKitTests/MouseModelTests.swift` (insert after the existing `titlesNonEmpty` test, i.e. after line 23's closing brace, before line 24's `}`):

```swift
    @Test func desktopNavigationCases() {
        #expect(MouseButtonAction.desktopNext.title == "Desktop Next")
        #expect(MouseButtonAction.desktopPrevious.title == "Desktop Previous")
        #expect(MouseButtonAction.desktopNext.rawValue == "desktopNext")
        #expect(MouseButtonAction.desktopPrevious.rawValue == "desktopPrevious")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MouseButtonActionTests`
Expected: FAIL to compile — `type 'MouseButtonAction' has no member 'desktopNext'`

- [ ] **Step 3: Implement — add the enum cases and titles**

In `Sources/QuackKit/Models/MouseButtonAction.swift`, change:

```swift
    case showDesktop
    case playPause
```

to:

```swift
    case showDesktop
    case desktopNext
    case desktopPrevious
    case playPause
```

And change:

```swift
        case .showDesktop: return "Show Desktop"
        case .playPause: return "Play / Pause"
```

to:

```swift
        case .showDesktop: return "Show Desktop"
        case .desktopNext: return "Desktop Next"
        case .desktopPrevious: return "Desktop Previous"
        case .playPause: return "Play / Pause"
```

- [ ] **Step 4: Implement — add the dispatch arms (required for the app target to compile)**

In `Sources/Quack/Mouse/MouseActionPerformer.swift`, change:

```swift
        case .showDesktop:
            postKeystroke(keyCode: 103, flags: [])                    // F11 (default binding)
        case .playPause:
```

to:

```swift
        case .showDesktop:
            postKeystroke(keyCode: 103, flags: [])                    // F11 (default binding)
        case .desktopNext:
            postKeystroke(keyCode: 124, flags: .maskControl)          // ⌃→
        case .desktopPrevious:
            postKeystroke(keyCode: 123, flags: .maskControl)          // ⌃←
        case .playPause:
```

(Both edits land together: `MouseButtonAction` and `MouseActionPerformer`'s `switch` must change atomically — the switch has no `default:` clause, so adding the enum cases alone leaves `Sources/Quack` non-exhaustive and the app target won't build.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MouseButtonActionTests`
Expected: PASS — all `MouseButtonActionTests` tests pass, including `rawValueRoundTrip` and `titlesNonEmpty` (both `allCases`-parametrized, so they now exercise the two new cases automatically with no edits needed).

- [ ] **Step 6: Verify the app target builds**

Run: `swift build`
Expected: exit 0, no errors (confirms `MouseActionPerformer`'s switch is exhaustive again).

- [ ] **Step 7: Commit**

```bash
git add Sources/QuackKit/Models/MouseButtonAction.swift Sources/Quack/Mouse/MouseActionPerformer.swift Tests/QuackKitTests/MouseModelTests.swift
git commit -m "feat(mouse): Desktop Next/Previous button actions"
```

---

### Task 2: Recorder hint for OS-reserved shortcuts

**Files:**
- Modify: `Sources/Quack/Settings/SettingsView.swift:1286-1289`

**Interfaces:**
- Consumes: `actionBinding.wrappedValue` (existing local `Binding<MouseButtonAction>` in `buttonRow`), `MouseButtonAction.customShortcut` (existing case).
- Produces: nothing consumed elsewhere — this is a leaf UI-only change.

No new test: this is static SwiftUI copy with no logic branch beyond the existing `if actionBinding.wrappedValue == .customShortcut` check already covered by manual QA of that row (there's no snapshot/UI test harness in this codebase — `Tests/QuackKitTests` only covers `QuackKit`, which has no UI). Verification is a build + manual check instead of a unit test.

- [ ] **Step 1: Implement**

In `Sources/Quack/Settings/SettingsView.swift`, change:

```swift
        if actionBinding.wrappedValue == .customShortcut {
            ShortcutRecorderField(shortcut: s.binding(shortcut),
                                   recorderID: id, activeRecorder: $activeRecorder)
        }
```

to:

```swift
        if actionBinding.wrappedValue == .customShortcut {
            ShortcutRecorderField(shortcut: s.binding(shortcut),
                                   recorderID: id, activeRecorder: $activeRecorder)
            Text("System shortcuts like ⌃+Arrow or ⌘Space can't be recorded here — use the action list above if there's a match.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
```

- [ ] **Step 2: Verify the app target builds**

Run: `swift build`
Expected: exit 0, no errors.

- [ ] **Step 3: Manual verification**

Run: `./Scripts/install.sh`
Then: open Quack Settings → Mouse tab → Extra buttons → set Button 4 (or 5) to "Keyboard Shortcut…".
Expected: the new caption ("System shortcuts like ⌃+Arrow or ⌘Space can't be recorded here…") appears under the Shortcut row, styled the same (small, secondary/gray) as the "Buttons 4 and 5 are the side (back/forward) buttons on most mice." caption above it. Switching the action away from "Keyboard Shortcut…" hides it again.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Settings/SettingsView.swift
git commit -m "fix(mouse): hint that OS-reserved shortcuts can't be recorded"
```

---

## Self-Review

**Spec coverage:**
- Spec Goal 1 (Desktop Next/Previous, ⌃→/⌃←, positioned after `showDesktop`) → Task 1. ✓
- Spec Goal 2 (recorder hint, exact copy, shown only for `.customShortcut`) → Task 2. ✓
- Spec Non-goal (no global tap, no capture-logic change) → respected in Global Constraints; neither task touches `ShortcutRecorderField`'s monitor or any tap file. ✓
- Spec Testing section (existing parametrized tests auto-cover new cases; performer arms left untested like their siblings) → Task 1 adds one small explicit assertion (title/rawValue) on top of the free `allCases` coverage, consistent with spec intent; Task 2 has no automated test, matching the spec's stated convention. ✓

**Placeholder scan:** no TBD/TODO; every step has complete, exact code. ✓

**Type consistency:** `MouseButtonAction.desktopNext`/`.desktopPrevious` (Task 1) are the exact tokens referenced in Task 2's dependency note and nowhere else renamed. `postKeystroke(keyCode:flags:)` signature matches its existing declaration (`CGKeyCode`, `CGEventFlags`) used by every other arm in the same `switch`. ✓
