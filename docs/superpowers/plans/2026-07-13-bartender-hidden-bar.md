# Bartender-style Hidden Menu Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user hide chosen menu-bar icons off-screen and reveal them in a secondary bar (under the main menu bar) that shows their real glyphs and opens their real menus on click — replacing Quack's notch hidden-icons row.

**Architecture:** A visible chevron `NSStatusItem` plus an empty divider `NSStatusItem`; collapsing the divider to length `10_000` shoves everything to its left off the screen's left edge (public API, no event injection). Hovering the chevron shows a borderless `NSPanel` that renders `CGWindowListCreateImage` captures of the hidden items; clicking one temporarily un-collapses the divider and `AXPress`es the real item so its menu opens at the top. Pure geometry/state logic lives in `QuackKit` (unit-tested); AppKit/CG/AX live in the `Quack` app target (build + manual verification, mirroring how `NotchService` is untested but `NotchGeometry` is).

**Tech Stack:** Swift 5.9, SwiftPM (no Xcode project), AppKit `NSStatusItem`/`NSPanel`, SwiftUI via `NSHostingView`, CoreGraphics `CGWindowListCreateImage` / `CGWindowListCopyWindowInfo` (public), ApplicationServices (AX `AXExtrasMenuBar`/`AXPress`), XCTest in `QuackKitTests`. No private APIs.

## Global Constraints

- Target platform: macOS 26 (Tahoe), notched MacBook Pro. Package floor `.macOS(.v13)`.
- **No new `CGEvent` tap anywhere.** Reveal uses `NSStatusItem` button tracking + the panel's own mouse events. (CLAUDE.md: input taps freeze the Mac; the only safe path is adding none here.)
- **No synthesized ⌘-drag / auto-move** (that path is Tahoe-broken — see spec). Click-forward DOES post a single synthesized left-click at the item's on-screen point — verified necessary during Task 12: `AXPress` reports success but does not open most third-party popovers (TickTick, Notion Calendar), so a real click is required (the Ice/Bartender approach). Posting a click is safe — the freeze rule is about event *taps*, not posting.
- Item arrangement is manual ⌘-drag by the user; Quack never moves other apps' items.
- Pure, testable logic → `Sources/QuackKit/`, tested in `Tests/QuackKitTests/`. System/AppKit code → `Sources/Quack/`.
- **Tests use swift-testing, not XCTest** (repo convention — all 20 existing files use `import Testing` / `@Suite struct` / `@Test func` / `#expect(...)`). The XCTest snippets in Tasks 2–4 below are illustrative — translate to swift-testing (an XCTest file silently runs alone and the swift-testing suite drops to 0 discovered).
- Build/run the real app with `./Scripts/install.sh`; `swift build` only makes the dev binary. Unit tests run with `swift test`.
- Screen Recording permission is **already** wired in `PermissionsManager` (`.screenRecording`, `requestScreenRecording()`, `refreshScreenRecording()`); reuse it, do not add a new permission file.
- Reuse `AXStatusItemScanner.press(_:)` for click-forward; do not reintroduce notch `isHiddenByNotch` scanning for this feature.
- **Identity is AX, not pid (Task 0 finding).** Menu-bar item windows are owned by **Control Center** in the window list, so `kCGWindowOwnerPID` does NOT identify the owning app. The owning app, its icon, its AX element (for clicking), and item frames all come from the **AX tree** (`AXExtrasMenuBar`, as the existing scanner does). Window capture supplies **only** the glyph image, associated to an AX item by matching X frame while the item is on-screen.
- **Capture only on-screen (Task 0 finding).** Off-screen items capture as nil. Capture and classify the hidden set at **warm time** (items on-screen); render that remembered set at reveal. Never enumerate/capture off-screen frames.

---

## File structure

**New — `Sources/QuackKit/HiddenBar/` (pure, unit-tested):**
- `HiddenBarLayout.swift` — zone classification (hidden vs shown from item X vs chevron X) and secondary-bar panel geometry.
- `HiddenBarReveal.swift` — hover/pin reveal state machine (pure reducer).
- `ChevronPlacement.swift` — the chevron-must-sit-right-of-notch check.

**New — `Sources/Quack/MenuBar/HiddenBar/` (app target):**
- `ControlItemManager.swift` — owns `chevron` + `hiddenDivider` `NSStatusItem`s; length toggle; hover callbacks.
- `MenuBarAXScanner.swift` — AX-tree scan of all apps' `AXExtrasMenuBar` (real app/icon/element/frame); the identity source.
- `StatusWindowList.swift` — on-screen layer-25 window `(id, frame)` list, for matching a windowID to an AX item by X during capture.
- `MenuBarItemImageCache.swift` — `CGWindowListCreateImage` glyph capture (on-screen only), keyed by AX id, scaled by backing factor.
- `HiddenBarGeometry.swift` — `MenuBarBand` and `NotchProbe` helpers.
- `HiddenBarPanel.swift` — the `NSPanel`, geometry, hover lifecycle, pin-on-click.
- `HiddenBarView.swift` — SwiftUI replica strip + permission-missing banner.
- `HiddenBarService.swift` — `ManagedService` orchestrator: warm-at-hide capture, cache render, AXPress click-forward, permission gating.

**Modified:**
- `Sources/QuackKit/Models/QuackSettings.swift` — add `hiddenBarEnabled`.
- `Sources/QuackKit/Coordinator/ManagedService.swift` — add `.hiddenBar` case + `isEnabled`.
- `Sources/Quack/AppEnvironment.swift` — construct + register `HiddenBarService`.
- `Sources/Quack/Notch/NotchService.swift`, `NotchContentViewModel.swift`, `NotchContentView.swift` — remove the hidden-icons row.
- Settings UI (a new tab section) — enable toggle + arrangement instructions.

---

## Task 0: Spike — capture feasibility (GATE) — ✅ DONE 2026-07-13

**Result (macOS 26.5.1, 14" MBP):** On-screen menu-bar item capture works; **off-screen (negative-X) capture returns nil**. Menu-bar item windows are owned by Control Center (layer 25), not the app. Decision taken: **capture-at-hide + cache** (grab glyphs while on-screen, cache, render cache; app-icon fallback). Tasks 7 and 9 below reflect this — there is no off-screen capture anywhere. Spike code was removed; no further action needed for this task.

<details><summary>Original spike (for reference)</summary>

This validates the plan's highest-risk assumption before any real building. It is throwaway code; do not commit it to a permanent file.

**Files:**
- Create (throwaway): `Sources/Quack/MenuBar/HiddenBar/_CaptureSpike.swift`

**Interfaces:**
- Produces: a proven answer (yes/no) to "does `CGWindowListCreateImage` return non-black pixels for a status-item window pushed to negative X by the divider trick?" Downstream Tasks 5–6 depend on this being **yes**.

- [ ] **Step 1: Add a temporary spike function**

```swift
import AppKit
import CoreGraphics

// THROWAWAY. Delete after Task 0. Manual spike for off-screen capture.
enum _CaptureSpike {
    static func run() {
        // 1. Create a divider status item and expand it to shove items off-screen.
        let divider = NSStatusBar.system.statusItem(withLength: 10_000)
        divider.button?.title = ""
        // 2. Enumerate on-screen menu-bar windows to find a third-party item now
        //    at negative X (owned by another app, in the menu-bar Y band).
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let wid = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            let x = boundsDict["X"] ?? 0
            NSLog("SPIKE candidate wid=\(wid) x=\(x) name=\(w[kCGWindowOwnerName as String] as? String ?? "?")")
            // 3. Try to capture that single window by id, even at negative X.
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .bestResolution])
            NSLog("SPIKE capture wid=\(wid) -> \(img == nil ? "NIL" : "\(img!.width)x\(img!.height)") ")
            // Non-black check: sample a few pixels via NSBitmapImageRep if img != nil.
        }
        NSStatusBar.system.removeStatusItem(divider)
    }
}
```

- [ ] **Step 2: Call `_CaptureSpike.run()` once at launch**

Temporarily add `_CaptureSpike.run()` in `AppEnvironment.init()` (last line), grant Screen Recording, then `./Scripts/install.sh` and read Console logs for `SPIKE`.

- [ ] **Step 3: Confirm the outcome**

Expected: at least one candidate at negative X returns a non-nil `CGImage` of non-zero size with non-black pixels. If **yes**, proceed. If **no** (all black/nil for off-screen windows), STOP and revisit: the fallback is a brief on-screen temp-show-to-capture flow (flickers) — record that decision in the spec before continuing.

- [ ] **Step 4: Remove the spike**

Delete `_CaptureSpike.swift` and the `_CaptureSpike.run()` call. Do not commit the spike. Commit nothing for this task (or commit only a one-line note in the spec's Verification section recording the result).

</details>

---

## Task 1: Settings flag + Feature case

**Files:**
- Modify: `Sources/QuackKit/Models/QuackSettings.swift` (property ~line 29, init param ~line 110, assignment ~line 152, CodingKeys, decoder ~line 207)
- Modify: `Sources/QuackKit/Coordinator/ManagedService.swift:14-24` (enum) and its `isEnabled` switch
- Test: `Tests/QuackKitTests/HiddenBarFeatureTests.swift`

**Interfaces:**
- Produces: `QuackSettings.hiddenBarEnabled: Bool` (default `false`); `Feature.hiddenBar`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuackKit

final class HiddenBarFeatureTests: XCTestCase {
    func testHiddenBarDisabledByDefault() {
        XCTAssertFalse(QuackSettings().hiddenBarEnabled)
        XCTAssertFalse(Feature.hiddenBar.isEnabled(in: QuackSettings()))
    }

    func testHiddenBarEnabledWhenFlagSet() {
        var s = QuackSettings()
        s.hiddenBarEnabled = true
        XCTAssertTrue(Feature.hiddenBar.isEnabled(in: s))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HiddenBarFeatureTests`
Expected: FAIL — `value of type 'QuackSettings' has no member 'hiddenBarEnabled'` / `type 'Feature' has no member 'hiddenBar'`.

- [ ] **Step 3: Add the setting**

In `QuackSettings.swift`: add `public var hiddenBarEnabled: Bool` next to `notchAgentsEnabled` (~line 29); add `hiddenBarEnabled: Bool = false,` to `init(...)` (after `notchAgentsEnabled:`); add `self.hiddenBarEnabled = hiddenBarEnabled` in the init body; add `hiddenBarEnabled` to the `CodingKeys` enum; add `hiddenBarEnabled = v(.hiddenBarEnabled, d.hiddenBarEnabled)` in `init(from:)`.

- [ ] **Step 4: Add the Feature case**

In `ManagedService.swift`: add `case hiddenBar` to the `Feature` enum; add `case .hiddenBar: return settings.hiddenBarEnabled` to the `isEnabled` switch.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HiddenBarFeatureTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/QuackKit/Models/QuackSettings.swift Sources/QuackKit/Coordinator/ManagedService.swift Tests/QuackKitTests/HiddenBarFeatureTests.swift
git commit -m "feat(hiddenbar): add hiddenBarEnabled setting + Feature case"
```

---

## Task 2: HiddenBarLayout — panel geometry

Zone classification (hidden = `minX < chevronMinX`) is a one-liner applied to `MenuBarAXItem` directly in the service (Task 9); it needs no separate type. This task provides only the panel-frame geometry.

**Files:**
- Create: `Sources/QuackKit/HiddenBar/HiddenBarLayout.swift`
- Test: `Tests/QuackKitTests/HiddenBarLayoutTests.swift`

**Interfaces:**
- Produces:
  - `HiddenBarLayout.panelFrame(itemCount:itemWidth:spacing:padding:height:chevronMidX:menuBarBottomY:screenMinX:screenMaxX:) -> CGRect` — the secondary-bar rect, centered under the chevron, clamped within screen bounds, hanging below the menu bar.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuackKit

final class HiddenBarLayoutTests: XCTestCase {
    func testPanelFrameRightAlignedUnderChevronAndClamped() {
        // 3 items * 24 + 2*8 spacing + 2*6 padding = 100 wide, 26 tall.
        let f = HiddenBarLayout.panelFrame(
            itemCount: 3, itemWidth: 24, spacing: 8, padding: 6, height: 26,
            chevronMidX: 850, menuBarBottomY: 1030, screenMinX: 0, screenMaxX: 1000)
        XCTAssertEqual(f.height, 26, accuracy: 0.5)
        XCTAssertEqual(f.width, 100, accuracy: 0.5)
        XCTAssertEqual(f.maxX, 850 + 50, accuracy: 0.5) // centered under chevron, not past screen
        XCTAssertLessThanOrEqual(f.maxX, 1000)
        XCTAssertGreaterThanOrEqual(f.minX, 0)
        XCTAssertEqual(f.minY, 1030 - 26, accuracy: 0.5) // hangs below the menu bar
    }

    func testPanelFrameClampsToScreenLeftEdge() {
        let f = HiddenBarLayout.panelFrame(
            itemCount: 10, itemWidth: 24, spacing: 8, padding: 6, height: 26,
            chevronMidX: 60, menuBarBottomY: 1030, screenMinX: 0, screenMaxX: 1000)
        XCTAssertEqual(f.minX, 0, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HiddenBarLayoutTests`
Expected: FAIL — no such type `HiddenBarLayout`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// Pure geometry for the hidden bar. Works in a Y-up space where
/// `menuBarBottomY` is the menu bar's lower edge and the panel hangs below it.
public enum HiddenBarLayout {

    /// The secondary-bar rect: centered under the chevron, clamped within screen.
    public static func panelFrame(
        itemCount: Int, itemWidth: CGFloat, spacing: CGFloat, padding: CGFloat,
        height: CGFloat, chevronMidX: CGFloat, menuBarBottomY: CGFloat,
        screenMinX: CGFloat, screenMaxX: CGFloat
    ) -> CGRect {
        let content = CGFloat(max(itemCount, 0)) * itemWidth
            + CGFloat(max(itemCount - 1, 0)) * spacing
        let width = content + padding * 2
        var minX = chevronMidX - width / 2
        minX = min(max(minX, screenMinX), screenMaxX - width)
        minX = max(minX, screenMinX) // when width > screen, pin left
        return CGRect(x: minX, y: menuBarBottomY - height, width: width, height: height)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HiddenBarLayoutTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/HiddenBar/HiddenBarLayout.swift Tests/QuackKitTests/HiddenBarLayoutTests.swift
git commit -m "feat(hiddenbar): pure panel geometry"
```

---

## Task 3: HiddenBarReveal — hover/pin state machine

**Files:**
- Create: `Sources/QuackKit/HiddenBar/HiddenBarReveal.swift`
- Test: `Tests/QuackKitTests/HiddenBarRevealTests.swift`

**Interfaces:**
- Produces:
  - `enum RevealState: Equatable { case hidden, revealed, pinned }`
  - `enum RevealEvent: Equatable { case hoverChevron, hoverPanel, exitAll, clickChevron, graceElapsed, clickOutside }`
  - `HiddenBarReveal.next(_ state: RevealState, on event: RevealEvent) -> RevealState`
  - `HiddenBarReveal.startsGraceTimer(from old: RevealState, to new: RevealState) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuackKit

final class HiddenBarRevealTests: XCTestCase {
    func testHoverRevealsThenGraceHides() {
        XCTAssertEqual(HiddenBarReveal.next(.hidden, on: .hoverChevron), .revealed)
        // Leaving arms grace; grace elapsing hides.
        XCTAssertEqual(HiddenBarReveal.next(.revealed, on: .exitAll), .revealed)
        XCTAssertTrue(HiddenBarReveal.startsGraceTimer(from: .revealed, to: .revealed))
        XCTAssertEqual(HiddenBarReveal.next(.revealed, on: .graceElapsed), .hidden)
    }

    func testHoverPanelKeepsOpenAndCancelsGrace() {
        XCTAssertEqual(HiddenBarReveal.next(.revealed, on: .hoverPanel), .revealed)
        // Re-entering before grace elapses: a graceElapsed after re-hover is ignored
        // because hoverPanel/hoverChevron reset it (state stays revealed).
        XCTAssertEqual(HiddenBarReveal.next(.revealed, on: .hoverChevron), .revealed)
    }

    func testClickPinsAndClickOutsideUnpins() {
        XCTAssertEqual(HiddenBarReveal.next(.revealed, on: .clickChevron), .pinned)
        XCTAssertEqual(HiddenBarReveal.next(.pinned, on: .exitAll), .pinned) // pinned ignores hover-out
        XCTAssertEqual(HiddenBarReveal.next(.pinned, on: .graceElapsed), .pinned)
        XCTAssertEqual(HiddenBarReveal.next(.pinned, on: .clickChevron), .hidden) // toggle off
        XCTAssertEqual(HiddenBarReveal.next(.pinned, on: .clickOutside), .hidden)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HiddenBarRevealTests`
Expected: FAIL — no such type `HiddenBarReveal`.

- [ ] **Step 3: Implement**

```swift
public enum RevealState: Equatable, Sendable { case hidden, revealed, pinned }

public enum RevealEvent: Equatable, Sendable {
    case hoverChevron, hoverPanel, exitAll, clickChevron, graceElapsed, clickOutside
}

/// Pure reveal state machine. The owner arms a grace timer when
/// `startsGraceTimer` returns true and cancels it on any hover event.
public enum HiddenBarReveal {
    public static func next(_ state: RevealState, on event: RevealEvent) -> RevealState {
        switch (state, event) {
        case (.hidden, .hoverChevron):        return .revealed
        case (.revealed, .hoverChevron),
             (.revealed, .hoverPanel):         return .revealed
        case (.revealed, .exitAll):            return .revealed // grace armed, not yet hidden
        case (.revealed, .graceElapsed):       return .hidden
        case (.revealed, .clickChevron):       return .pinned
        case (.pinned, .clickChevron),
             (.pinned, .clickOutside):         return .hidden
        case (.pinned, _):                     return .pinned
        default:                               return state
        }
    }

    /// Grace timer is armed only when the pointer leaves while revealed.
    public static func startsGraceTimer(from old: RevealState, to new: RevealState) -> Bool {
        old == .revealed && new == .revealed
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HiddenBarRevealTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/HiddenBar/HiddenBarReveal.swift Tests/QuackKitTests/HiddenBarRevealTests.swift
git commit -m "feat(hiddenbar): pure hover/pin reveal state machine"
```

---

## Task 4: ChevronPlacement — notch guard

**Files:**
- Create: `Sources/QuackKit/HiddenBar/ChevronPlacement.swift`
- Test: `Tests/QuackKitTests/ChevronPlacementTests.swift`

**Interfaces:**
- Consumes: `NotchGeometry.NotchSpan` (existing).
- Produces: `ChevronPlacement.isSafe(chevronMinX:notch:) -> Bool` — true when the chevron sits fully right of the notch (so hidden items push off the left edge, not behind the notch).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuackKit

final class ChevronPlacementTests: XCTestCase {
    func testChevronRightOfNotchIsSafe() {
        let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        XCTAssertTrue(ChevronPlacement.isSafe(chevronMinX: 900, notch: notch))
    }
    func testChevronOverlappingNotchIsUnsafe() {
        let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        XCTAssertFalse(ChevronPlacement.isSafe(chevronMinX: 800, notch: notch))
    }
    func testNoNotchIsAlwaysSafe() {
        XCTAssertTrue(ChevronPlacement.isSafe(chevronMinX: 100, notch: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChevronPlacementTests`
Expected: FAIL — no such type `ChevronPlacement`.

- [ ] **Step 3: Implement**

```swift
public enum ChevronPlacement {
    /// Safe when there is no notch, or the chevron begins at/right of the notch's
    /// right edge. Otherwise hidden items would land behind the notch (unmapped,
    /// uncapturable).
    public static func isSafe(chevronMinX: CGFloat, notch: NotchGeometry.NotchSpan?) -> Bool {
        guard let notch else { return true }
        return chevronMinX >= notch.maxX
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChevronPlacementTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/HiddenBar/ChevronPlacement.swift Tests/QuackKitTests/ChevronPlacementTests.swift
git commit -m "feat(hiddenbar): pure chevron-vs-notch placement guard"
```

---

## Task 5: ControlItemManager — chevron + divider status items

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/ControlItemManager.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class ControlItemManager` with:
    - `init(onChevronHover: @escaping () -> Void, onChevronExit: @escaping () -> Void, onChevronClick: @escaping () -> Void)`
    - `var chevronFrameOnScreen: CGRect?` (button window frame in Cocoa/global coords)
    - `func collapse()` / `func expand()` — set `hiddenDivider.length` to `10_000` / `variableLength`
    - `func teardown()` — remove both status items
- Consumes (later): callbacks are wired by `HiddenBarService` (Task 9).

App-target AppKit; not unit-tested (mirrors `StatusItemController`). Verified by build + manual.

- [ ] **Step 1: Implement**

```swift
import AppKit

/// Owns Quack's two hidden-bar control items: a visible chevron (trigger +
/// boundary) and an empty divider whose length collapses items off-screen.
/// Layout (L→R): [hidden items] [hiddenDivider] [chevron] [shown items].
@MainActor
final class ControlItemManager {
    private let chevron: NSStatusItem
    private let hiddenDivider: NSStatusItem
    private let onChevronClick: () -> Void

    enum Length { static let expanded: CGFloat = 10_000 }

    init(onChevronHover: @escaping () -> Void,
         onChevronExit: @escaping () -> Void,
         onChevronClick: @escaping () -> Void) {
        self.onChevronClick = onChevronClick
        // Start expanded (items visible) so the service can warm-capture glyphs
        // while items are on-screen before its first collapse() (Task 9).
        hiddenDivider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = "quack.hiddenDivider"
        chevron.autosaveName = "quack.chevron"
        hiddenDivider.button?.title = ""
        hiddenDivider.button?.setAccessibilityLabel("Quack hidden items divider")

        if let b = chevron.button {
            b.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(chevronClicked)
            b.setAccessibilityLabel("Show hidden menu bar items")
            // Hover tracking — NO CGEvent tap (CLAUDE.md). Button tracking area only.
            let area = NSTrackingArea(rect: b.bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: HoverForwarder(enter: onChevronHover, exit: onChevronExit),
                                      userInfo: nil)
            b.addTrackingArea(area)
        }
    }

    var chevronFrameOnScreen: CGRect? {
        guard let window = chevron.button?.window else { return nil }
        return window.frame
    }

    var chevronMinX: CGFloat? { chevronFrameOnScreen?.minX }

    func collapse() { hiddenDivider.length = Length.expanded }
    func expand()   { hiddenDivider.length = NSStatusItem.variableLength }

    func teardown() {
        NSStatusBar.system.removeStatusItem(chevron)
        NSStatusBar.system.removeStatusItem(hiddenDivider)
    }

    @objc private func chevronClicked() { onChevronClick() }
}

/// Retains hover callbacks for a tracking area (owner is unretained).
private final class HoverForwarder: NSResponder {
    private let enter: () -> Void
    private let exit: () -> Void
    init(enter: @escaping () -> Void, exit: @escaping () -> Void) {
        self.enter = enter; self.exit = exit; super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { enter() }
    override func mouseExited(with event: NSEvent) { exit() }
}
```

> Note: `HoverForwarder` must be retained by `ControlItemManager` (add a stored `private var hoverForwarder: HoverForwarder?` and assign it before creating the tracking area, passing it as `owner:`). Update the init accordingly so the responder is not deallocated.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean (no references yet outside this file besides Foundation/AppKit).

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/ControlItemManager.swift
git commit -m "feat(hiddenbar): control items (chevron + collapsing divider)"
```

---

## Task 6: AX item scan + status-window frame list

Per the Task 0 finding, identity comes from AX (real app/icon/element/frame), and the window list supplies only `(windowID, frame)` for glyph-capture matching (its pid is Control Center's, so it is NOT used for identity).

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/MenuBarAXScanner.swift`
- Create: `Sources/Quack/MenuBar/HiddenBar/StatusWindowList.swift`

**Interfaces:**
- Produces:
  - `struct MenuBarAXItem { let id: String; let pid: pid_t; let appName: String; let appIcon: NSImage?; let element: AXUIElement; let frame: CGRect }` — `id` is `"pid:index"`.
  - `MenuBarAXScanner.scanAll(menuBarBandY: ClosedRange<CGFloat>) -> [MenuBarAXItem]` — every app's `AXExtrasMenuBar` children whose frame midY is in the menu-bar band, sorted by `frame.minX`. (Generalizes the existing notch scanner: no notch filter.)
  - `struct StatusWindow { let windowID: UInt32; let frame: CGRect }`
  - `StatusWindowList.onScreen() -> [StatusWindow]` — layer-25 windows (any owner), on-screen only, for frame-matching during capture.

- [ ] **Step 1: Implement the AX scanner**

```swift
import AppKit
import ApplicationServices

struct MenuBarAXItem {
    let id: String
    let pid: pid_t
    let appName: String
    let appIcon: NSImage?
    let element: AXUIElement
    let frame: CGRect
}

/// Walks every running app's AXExtrasMenuBar and returns all menu-bar status
/// items with real frames. Identity/app/icon/element come from AX because the
/// window list attributes menu-bar windows to Control Center (Task 0). Call off
/// the main actor: AX is blocking IPC. Needs the Accessibility grant.
enum MenuBarAXScanner {
    static func scanAll(menuBarBandY: ClosedRange<CGFloat>) -> [MenuBarAXItem] {
        let apps = NSWorkspace.shared.runningApplications
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var found: [MenuBarAXItem] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            guard app.processIdentifier != ownPID else { return }
            let hits = scanApp(app, menuBarBandY: menuBarBandY)
            guard !hits.isEmpty else { return }
            lock.lock(); found.append(contentsOf: hits); lock.unlock()
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func scanApp(_ app: NSRunningApplication, menuBarBandY: ClosedRange<CGFloat>) -> [MenuBarAXItem] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var barVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &barVal) == .success,
              let bar = barVal, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var childrenVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return [] }
        var out: [MenuBarAXItem] = []
        for (index, child) in children.enumerated() {
            guard let frame = frame(of: child), frame.width > 0,
                  menuBarBandY.contains(frame.midY) else { continue }
            out.append(MenuBarAXItem(
                id: "\(app.processIdentifier):\(index)",
                pid: app.processIdentifier,
                appName: app.localizedName ?? "?",
                appIcon: app.icon,
                element: child,
                frame: frame))
        }
        return out
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?, sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
```

- [ ] **Step 2: Implement the window frame list**

```swift
import CoreGraphics

struct StatusWindow {
    let windowID: UInt32
    let frame: CGRect   // global Quartz
}

/// On-screen layer-25 (menu-bar) windows, any owner. Used only to match a
/// windowID to an AX item by X so the glyph can be captured while on-screen.
enum StatusWindowList {
    static func onScreen() -> [StatusWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [StatusWindow] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let wid = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"], ww > 0
            else { continue }
            out.append(StatusWindow(windowID: wid, frame: CGRect(x: x, y: y, width: ww, height: hh)))
        }
        return out
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/MenuBarAXScanner.swift Sources/Quack/MenuBar/HiddenBar/StatusWindowList.swift
git commit -m "feat(hiddenbar): AX item scan + status-window frame list"
```

---

## Task 7: MenuBarItemImageCache — capture

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/MenuBarItemImageCache.swift`

**Interfaces:**
- Consumes: `MenuBarAXItem`, `StatusWindow` (Task 6).
- Produces:
  - `@MainActor final class MenuBarItemImageCache`
  - `func image(forID id: String) -> NSImage?` — cached glyph, keyed by AX item id
  - `func captureOnScreen(items: [MenuBarAXItem], windows: [StatusWindow])` — for each **on-screen** AX item, match the layer-25 window at the same X and capture it; store keyed by the AX item's `id`. Merges (keeps prior captures for items not on-screen now).
  - `var hasScreenRecording: Bool` (mirror of `CGPreflightScreenCaptureAccess()`)

> **Task 0 constraints:** off-screen (negative-X) items capture as nil, so only on-screen items (`frame.minX >= 0`) are attempted. Window pid is Control Center's, so the AX item ↔ window association is by **X-frame match**, not pid. Cache is keyed by the AX `id` (stable across collapse), not windowID.

- [ ] **Step 1: Implement**

```swift
import AppKit
import CoreGraphics

/// Caches real-glyph captures keyed by AX item id. Captures ONLY on-screen
/// items (off-screen capture returns nil on macOS 26 — Task 0). The glyph for an
/// AX item is the capture of the layer-25 window sitting at the same X.
@MainActor
final class MenuBarItemImageCache {
    private var cache: [String: NSImage] = [:]

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    func image(forID id: String) -> NSImage? { cache[id] }

    func captureOnScreen(items: [MenuBarAXItem], windows: [StatusWindow], tolerance: CGFloat = 6) {
        guard hasScreenRecording else { return }
        for item in items where item.frame.minX >= 0 {
            guard let win = windows.min(by: {
                abs($0.frame.minX - item.frame.minX) < abs($1.frame.minX - item.frame.minX)
            }), abs(win.frame.minX - item.frame.minX) <= tolerance else { continue }
            guard let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, win.windowID,
                [.boundsIgnoreFraming, .bestResolution]),
                cg.width > 1, cg.height > 1 else { continue }
            cache[item.id] = NSImage(cgImage: cg,
                size: NSSize(width: item.frame.width, height: item.frame.height))
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/MenuBarItemImageCache.swift
git commit -m "feat(hiddenbar): glyph cache keyed by AX id, frame-matched capture"
```

---

## Task 8: HiddenBarView + HiddenBarPanel

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/HiddenBarView.swift`
- Create: `Sources/Quack/MenuBar/HiddenBar/HiddenBarPanel.swift`

**Interfaces:**
- Consumes: `MenuBarAXItem`, `MenuBarItemImageCache`.
- Produces:
  - `struct HiddenBarItemVM: Identifiable { let id: String; let image: NSImage?; let item: MenuBarAXItem }` — `image` is the glyph capture already resolved to `glyph ?? appIcon` by the service.
  - `HiddenBarView(items: [HiddenBarItemVM], onClick: (MenuBarAXItem) -> Void, showPermissionBanner: Bool, onGrant: () -> Void)`
  - `@MainActor final class HiddenBarPanel` with `func show(view:frame:)`, `func hide()`, `var isVisible: Bool`, and hover callbacks `onPanelHover`/`onPanelExit`.

- [ ] **Step 1: Implement the view**

```swift
import SwiftUI
import AppKit

struct HiddenBarItemVM: Identifiable {
    let id: String
    let image: NSImage?
    let item: MenuBarAXItem
}

struct HiddenBarView: View {
    let items: [HiddenBarItemVM]
    let onClick: (MenuBarAXItem) -> Void
    let showPermissionBanner: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showPermissionBanner {
                Button(action: onGrant) {
                    Label("Enable Screen Recording to show icons", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }.buttonStyle(.plain)
            }
            ForEach(items) { vm in
                Button { onClick(vm.item) } label: {
                    Group {
                        if let img = vm.image { Image(nsImage: img).resizable().scaledToFit() }
                        else { Image(systemName: "app.dashed").resizable().scaledToFit() }
                    }.frame(width: 22, height: 22)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Implement the panel**

```swift
import AppKit
import SwiftUI

/// Borderless, non-activating panel that hangs under the menu bar and renders
/// the hidden items. Level above the menu bar. No CGEvent tap; it receives
/// mouse events natively for its own hover lifecycle.
@MainActor
final class HiddenBarPanel {
    private let panel: NSPanel
    private var host: NSHostingView<HiddenBarView>?
    var onPanelHover: () -> Void = {}
    var onPanelExit: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    var isVisible: Bool { panel.isVisible }

    func show(view: HiddenBarView, frame: CGRect) {
        let host = NSHostingView(rootView: view)
        self.host = host
        panel.contentView = TrackingContainer(content: host, enter: onPanelHover, exit: onPanelExit)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// Hosts the SwiftUI view and reports hover for the whole panel area.
private final class TrackingContainer: NSView {
    private let enter: () -> Void
    private let exit: () -> Void
    init(content: NSView, enter: @escaping () -> Void, exit: @escaping () -> Void) {
        self.enter = enter; self.exit = exit
        super.init(frame: .zero)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { enter() }
    override func mouseExited(with event: NSEvent) { exit() }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarView.swift Sources/Quack/MenuBar/HiddenBar/HiddenBarPanel.swift
git commit -m "feat(hiddenbar): secondary bar panel + SwiftUI replica strip"
```

---

## Task 9: HiddenBarService — orchestration + click-forward

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift` (construct + register under `.hiddenBar`)

**Interfaces:**
- Consumes: `ControlItemManager`, `MenuBarAXScanner`, `StatusWindowList`, `MenuBarItemImageCache`, `HiddenBarPanel`, `HiddenBarView`, `HiddenBarItemVM`, `HiddenBarLayout`, `HiddenBarReveal`, `ChevronPlacement`, `MenuBarBand`, `NotchProbe`, `SettingsStore`, `PermissionsManager`.
- Produces: `@MainActor final class HiddenBarService: ManagedService` with `start()` / `stop()`.

Behavior (AX identity + capture-at-hide, per Task 0):
- `start()`: create `ControlItemManager` **expanded** (items still on-screen), then `warmAndCollapse()` — one natural disappearance, no extra flash.
- `warmAndCollapse()`: off-main AX scan → classify hidden set (`frame.minX < chevronMinX`; X is coordinate-system-agnostic) → on main, capture glyphs from the on-screen window list → remember `hiddenItems` → `collapse()`. Re-run on `didBecomeActive` (user likely just re-arranged) and after each click's expand (cheap glyph refresh).
- Reveal: render the remembered `hiddenItems` from cache (`glyph ?? appIcon`); no enumeration/capture at reveal (items are off-screen and uncapturable). Compute `panelFrame`, show panel.
- Grace: arm a 0.25s `Timer` when `startsGraceTimer` is true; cancel on any hover.
- Click-forward: `expand()` → after ~150ms layout delay, `AXUIElementPerformAction(item.element, kAXPressAction)` off-main (we hold the element directly — no pid lookup) → real menu opens on-screen → collapse on the next global mouse-up (with a 5s fallback). Also refresh that item's glyph while on-screen.
- Placement guard: if `ChevronPlacement.isSafe(chevronMinX:notch:)` is false, log once advising the user to ⌘-drag the chevron right of the notch (no auto-move).

- [ ] **Step 1: Add small helpers (band, notch probe, AX press)**

Create `Sources/Quack/MenuBar/HiddenBar/HiddenBarGeometry.swift`:

```swift
import AppKit
import QuackKit

/// Menu-bar Y band in AX/Quartz global (top-left origin) for the main display.
enum MenuBarBand {
    static func current() -> ClosedRange<CGFloat> {
        let thickness = NSStatusBar.system.thickness   // ~24pt
        return -5 ... (thickness + 12)                 // generous; main display top
    }
}

/// Notch span of the main display, or nil if not notched. Uses the auxiliary
/// top areas that flank the camera housing.
enum NotchProbe {
    static func current() -> NotchGeometry.NotchSpan? {
        guard let screen = NSScreen.main else { return nil }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        return NotchGeometry.notchSpan(
            screenMinX: screen.frame.minX, screenWidth: screen.frame.width,
            leftAuxWidth: left, rightAuxWidth: right)
    }
}
```

Extend `Sources/Quack/MenuBar/Overflow/AXStatusItemScanner.swift` with a direct-element press (we already have the element from the scan — no pid walk needed):

```swift
extension AXStatusItemScanner {
    /// Press a status item by its AX element. Call off the main actor (blocking IPC).
    static func press(element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}
```

- [ ] **Step 2: Implement the service**

```swift
import AppKit
import Combine
import ApplicationServices
import QuackKit

@MainActor
final class HiddenBarService: ManagedService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private var control: ControlItemManager?
    private let panel = HiddenBarPanel()
    private let imageCache = MenuBarItemImageCache()
    private var hiddenItems: [MenuBarAXItem] = []   // remembered set, captured on-screen
    private var state: RevealState = .hidden
    private var graceTimer: Timer?
    private var mouseUpMonitor: Any?
    private var activeObserver: NSObjectProtocol?

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
    }

    func start() {
        guard control == nil else { return }
        let c = ControlItemManager(
            onChevronHover: { [weak self] in self?.handle(.hoverChevron) },
            onChevronExit:  { [weak self] in self?.handle(.exitAll) },
            onChevronClick: { [weak self] in self?.handle(.clickChevron) })
        control = c
        panel.onPanelHover = { [weak self] in self?.handle(.hoverPanel) }
        panel.onPanelExit  = { [weak self] in self?.handle(.exitAll) }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.warmAndCollapse() } }
        // Items are still on-screen (divider expanded): capture, then collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.warmAndCollapse() }
    }

    func stop() {
        graceTimer?.invalidate(); graceTimer = nil
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        if let o = activeObserver { NotificationCenter.default.removeObserver(o); activeObserver = nil }
        panel.hide()
        control?.teardown(); control = nil
        hiddenItems = []
        state = .hidden
    }

    /// Capture glyphs for the currently-on-screen hidden set, then collapse.
    private func warmAndCollapse() {
        guard let control else { return }
        control.expand()
        guard let chevronMinX = control.chevronMinX else { control.collapse(); return }
        if let notch = NotchProbe.current(), !ChevronPlacement.isSafe(chevronMinX: chevronMinX, notch: notch) {
            Log.notch.notice("hidden bar: chevron left of notch — ⌘-drag it right of the notch")
        }
        let band = MenuBarBand.current()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBandY: band)
            let hidden = items.filter { $0.frame.minX < chevronMinX }
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self else { return }
                self.imageCache.captureOnScreen(items: hidden, windows: windows)
                self.hiddenItems = hidden
                self.control?.collapse()
            }
        }
    }

    private func handle(_ event: RevealEvent) {
        let old = state
        let new = HiddenBarReveal.next(old, on: event)
        graceTimer?.invalidate(); graceTimer = nil
        if HiddenBarReveal.startsGraceTimer(from: old, to: new) {
            graceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.handle(.graceElapsed) }
            }
        }
        state = new
        switch new {
        case .revealed, .pinned: reveal()
        case .hidden:            panel.hide()
        }
    }

    private func reveal() {
        guard let chevronFrame = control?.chevronFrameOnScreen, let screen = NSScreen.main else { return }
        let vms = hiddenItems.map {
            HiddenBarItemVM(id: $0.id, image: imageCache.image(forID: $0.id) ?? $0.appIcon, item: $0)
        }
        let frame = HiddenBarLayout.panelFrame(
            itemCount: vms.count, itemWidth: 24, spacing: 8, padding: 6, height: 26,
            chevronMidX: chevronFrame.midX,
            menuBarBottomY: screen.frame.maxY - NSStatusBar.system.thickness,
            screenMinX: screen.frame.minX, screenMaxX: screen.frame.maxX)
        let view = HiddenBarView(
            items: vms,
            onClick: { [weak self] in self?.forwardClick($0) },
            showPermissionBanner: !imageCache.hasScreenRecording,
            onGrant: { [weak self] in
                self?.permissions.requestScreenRecording()
                self?.permissions.openSystemSettings(for: .screenRecording)
            })
        panel.show(view: view, frame: frame)
    }

    private func forwardClick(_ item: MenuBarAXItem) {
        control?.expand()          // real item snaps on-screen; menu will open here
        panel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                AXStatusItemScanner.press(element: item.element)
            }
            self.armCollapseAfterMenu()
        }
    }

    private func armCollapseAfterMenu() {
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.control?.collapse()
                if let m = self?.mouseUpMonitor { NSEvent.removeMonitor(m); self?.mouseUpMonitor = nil }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.control?.collapse() }
    }
}
```

- [ ] **Step 3: Register the service in AppEnvironment**

In `AppEnvironment.swift`: add `private let hiddenBarService: HiddenBarService`; construct it `self.hiddenBarService = HiddenBarService(settings: settings, permissions: permissions)` alongside the other services; add `.hiddenBar: hiddenBarService` to the `services` dictionary.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 5: Manual end-to-end verify**

`./Scripts/install.sh`. Enable the feature (Task 11 toggle, or temporarily force `hiddenBarEnabled = true`). Grant Accessibility + Screen Recording. ⌘-drag two app icons left of the chevron. Verify: they collapse off-screen after warm; hovering the chevron shows the secondary bar with their **real glyphs** (captured at warm); clicking one opens that app's real menu at the top; the bar hides on mouse-out after the grace delay; clicking the chevron pins it. Re-arrange, click Quack's Dock/menu to re-activate → glyph set refreshes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/MenuBar/HiddenBar/HiddenBarGeometry.swift Sources/Quack/MenuBar/Overflow/AXStatusItemScanner.swift Sources/Quack/AppEnvironment.swift
git commit -m "feat(hiddenbar): AX-identity orchestration, capture-at-hide, AXPress click-forward"
```

---

## Task 10: Remove the notch hidden-icons row

**Files:**
- Modify: `Sources/Quack/Notch/NotchService.swift`
- Modify: `Sources/Quack/Notch/NotchContentViewModel.swift`
- Modify: `Sources/Quack/Notch/NotchContentView.swift`

**Interfaces:**
- Removes: `NotchContentViewModel.hiddenIcons`, `onHiddenIconTap`; the row view; and in `NotchService` the `hiddenIconsCache`, `hiddenIconsRowHeight`, the `model.hiddenIcons` assignments, the scan scheduling, and `forwardHiddenIconTap`.

- [ ] **Step 1: Remove view-model members**

In `NotchContentViewModel.swift` delete `@Published var hiddenIcons` and `var onHiddenIconTap`.

- [ ] **Step 2: Remove the row view**

In `NotchContentView.swift` delete the hidden-icons row subview and any reference to `model.hiddenIcons` / `onHiddenIconTap`.

- [ ] **Step 3: Remove the scan in NotchService**

In `NotchService.swift` delete `hiddenIconsCache`, `hiddenIconsRowHeight`, the `h += hiddenIconsRowHeight` height contribution, all `model.hiddenIcons = ...` lines, the scan-scheduling block, and `forwardHiddenIconTap`. Leave `AXStatusItemScanner` (still used by Task 9).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean (no dangling references).

- [ ] **Step 5: Manual verify**

`./Scripts/install.sh`. Open the notch panel — it shows media/agents only, no hidden-icons row, and its height is correspondingly shorter.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/Notch/NotchService.swift Sources/Quack/Notch/NotchContentViewModel.swift Sources/Quack/Notch/NotchContentView.swift
git commit -m "refactor(notch): drop hidden-icons row (superseded by hidden bar)"
```

---

## Task 11: Settings UI — toggle + arrangement instructions

**Files:**
- Modify: the relevant Settings tab view under `Sources/Quack/Settings/` (follow the existing pattern used for `notchMediaEnabled`).

**Interfaces:**
- Consumes: `SettingsStore`, `PermissionsManager` (for the Screen Recording status row).

- [ ] **Step 1: Add a "Hidden Menu Bar" section**

A `Toggle("Hidden menu bar", isOn: binding to hiddenBarEnabled)`; below it, help text: "⌘-drag menu-bar icons to the left of Quack's chevron (») to hide them. Hover the chevron to reveal them." Plus a Screen Recording status row that, when not granted, offers a "Grant" button calling `permissions.requestScreenRecording()` then `permissions.openSystemSettings(for: .screenRecording)`.

- [ ] **Step 2: Build + manual verify**

Run: `swift build` then `./Scripts/install.sh`. Toggle on/off; confirm the chevron appears/disappears (service start/stop via the coordinator) and the help text + permission row render.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/Settings/
git commit -m "feat(hiddenbar): settings toggle + arrangement instructions"
```

---

## Task 12: Freeze-safety regression check + final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full unit suite**

Run: `swift test`
Expected: all pass, including the four new `HiddenBar*`/`ChevronPlacement` test files.

- [ ] **Step 2: Freeze regression**

With the feature enabled and items hidden, toggle Quack's Accessibility grant off and on in System Settings, then toggle Screen Recording off and on. Confirm the Mac never freezes (mouse/keyboard stay responsive). This feature adds no CGEvent tap, so there is nothing to reinstall — the check confirms that invariant held.

- [ ] **Step 3: Full flow on hardware**

Confirm on the 14" MBP: chevron sits right of the notch (placement guard silent); hidden items push off the left edge (not behind the notch); reveal shows real glyphs; click opens real menus; live glyphs (e.g. battery) update on re-reveal.

- [ ] **Step 4: Commit any final fixups**

```bash
git add -A && git commit -m "test(hiddenbar): verify suite + freeze-safety regression"
```

---

## Self-review notes

- **Spec coverage:** hide mechanism (Tasks 5), arrangement (manual, Task 11 instructions), secondary bar (Tasks 7–8), capture + Screen Recording + fallback (Tasks 0,7,9), click-forward full fidelity (Task 9), two-zone classification (Task 2), chevron trigger + hover machine (Tasks 3,5,9), notch placement rule (Tasks 4,9,12), removal of notch row (Task 10), permissions reuse (Task 9/11). All spec sections map to a task.
- **Out-of-scope (v1)** honored: no third zone, no auto-move, main-display-only (`NSScreen.main` in Task 9).
- **Highest risk** (off-screen capture) is gated by Task 0 before any real work.
- **Type consistency:** `MenuBarAXItem` (identity), `StatusWindow` (capture matching), `HiddenBarItemVM`, `RevealState`/`RevealEvent`, `ChevronPlacement.isSafe`, `HiddenBarLayout.panelFrame`, `AXStatusItemScanner.press(element:)` used consistently across producing and consuming tasks. No pid-based identity anywhere (Task 0: windows owned by Control Center).
