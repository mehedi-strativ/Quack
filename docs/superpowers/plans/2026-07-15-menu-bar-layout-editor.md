# Menu Bar Layout Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `Arrange…` button in the Menu Bar settings tab with an Ice-style drag editor — two rows (Shown / Hidden) of real-glyph tiles the user drags between and reorders within — executed by synthesizing ⌘-drags of the real menu-bar items.

**Architecture:** A pure order-diff planner in QuackKit turns a before/after layout into a minimal list of drag ops. A synth-⌘-drag executor runs those ops against the live bar (bar expanded so frames are on-screen). `HiddenBarService` scans + glyph-captures all items and exposes the layout; a SwiftUI editor renders the two rows and calls back on drop. A mechanism spike (Task 3) validates that macOS honors synth-⌘-drags of third-party items before the UI is built; if it fails, the editor falls back to divider-only hide/show (no within-section reorder).

**Tech Stack:** Swift, SwiftPM (no Xcode project), SwiftUI, AppKit, ApplicationServices (AX), CoreGraphics (CGEvent), Swift Testing (`import Testing`).

## Global Constraints

- Build/run the real app with `./Scripts/install.sh` — `swift build` only makes the dev binary; the running app is `/Applications/Quack.app`. UI changes need install.
- Never create a CGEvent **tap** on the main run loop (freezes the Mac). This feature creates **no** taps — it only *posts* synthesized events — so the rule is satisfied by not adding taps. Do not add any.
- All AX scanning and CGEvent posting run **off the main actor** (`DispatchQueue.global(qos: .userInitiated)`), matching the existing `SynthClick` / `MenuBarAXScanner` usage.
- Pure logic goes in `QuackKit` (unit-testable, like `HiddenBarReveal`, `ChevronPlacement`, `TrackpadSwipe`). AppKit/UI stays in `Sources/Quack`.
- Menu-bar item ids are the AX scanner's `"pid:index"` strings.
- Run unit tests with `swift test`. Run a single suite with `swift test --filter MenuBarLayoutPlanTests`.

---

### Task 1: MenuBarLayoutPlan (pure diff planner)

**Files:**
- Create: `Sources/QuackKit/HiddenBar/MenuBarLayoutPlan.swift`
- Test: `Tests/QuackKitTests/MenuBarLayoutPlanTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `MenuBarLayoutPlan.DragOp` (`Equatable`) with `kind: Kind` and `targetIndex: Int`.
  - `MenuBarLayoutPlan.DragOp.Kind` (`Equatable`): `.reorderItem(id: String)`, `.moveDivider`.
  - `MenuBarLayoutPlan.plan(currentOrder: [String], currentBoundary: Int, desiredOrder: [String], desiredBoundary: Int) -> [DragOp]`.
  - Semantics: `order` = item ids left→right, divider excluded. `boundary` = count of hidden items (indices `0..<boundary` are Hidden). Output lists the reorder op first (at most one, the single moved item), then a `moveDivider` op iff the boundary changed.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/MenuBarLayoutPlanTests.swift
import Testing
@testable import QuackKit

@Suite struct MenuBarLayoutPlanTests {

    // Identical layout → no operations.
    @Test func noChangeProducesNoOps() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,
            desiredOrder: ["a", "b", "c"], desiredBoundary: 1)
        #expect(ops.isEmpty)
    }

    // Boundary shifts, order unchanged → a single moveDivider op at the new count.
    @Test func boundaryOnlyMovesDivider() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,
            desiredOrder: ["a", "b", "c"], desiredBoundary: 2)
        #expect(ops == [.init(kind: .moveDivider, targetIndex: 2)])
    }

    // One item dragged to a new slot within its section → a single reorderItem op
    // carrying that item's id and its destination index. No divider op.
    @Test func reorderWithinSectionMovesOneItem() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 0,
            desiredOrder: ["a", "c", "b"], desiredBoundary: 0)
        #expect(ops == [.init(kind: .reorderItem(id: "c"), targetIndex: 1)])
    }

    // Dragging a shown item left across the boundary into Hidden → it both moves
    // in the order AND the boundary grows: reorder op first, then divider op.
    @Test func moveShownItemIntoHiddenEmitsReorderThenDivider() {
        // "c" (shown) dragged to the front, and now hidden.
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,   // hidden: [a]
            desiredOrder: ["c", "a", "b"], desiredBoundary: 2)    // hidden: [c, a]
        #expect(ops == [
            .init(kind: .reorderItem(id: "c"), targetIndex: 0),
            .init(kind: .moveDivider, targetIndex: 2),
        ])
    }

    // Everything hidden with no reordering → boundary jumps 0 → n, one divider op.
    @Test func hideAllIsDividerOnly() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b"], currentBoundary: 0,
            desiredOrder: ["a", "b"], desiredBoundary: 2)
        #expect(ops == [.init(kind: .moveDivider, targetIndex: 2)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuBarLayoutPlanTests`
Expected: FAIL — `cannot find 'MenuBarLayoutPlan' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/QuackKit/HiddenBar/MenuBarLayoutPlan.swift

/// Pure planner: turns a before→after menu-bar layout into the minimal list of
/// drag operations the executor must perform on the live bar. Coordinate-free —
/// the Quack-side executor converts each op's target index into an on-screen X.
///
/// `order` is the item ids left→right (Quack's divider excluded). `boundary` is
/// the number of Hidden items: indices `0..<boundary` are Hidden, the rest Shown.
public enum MenuBarLayoutPlan {

    public struct DragOp: Equatable {
        public enum Kind: Equatable {
            case reorderItem(id: String)   // move this real item to `targetIndex`
            case moveDivider               // move Quack's divider so `targetIndex` items are left of it
        }
        public let kind: Kind
        public let targetIndex: Int
        public init(kind: Kind, targetIndex: Int) {
            self.kind = kind
            self.targetIndex = targetIndex
        }
    }

    public static func plan(currentOrder: [String], currentBoundary: Int,
                            desiredOrder: [String], desiredBoundary: Int) -> [DragOp] {
        var ops: [DragOp] = []

        if currentOrder != desiredOrder {
            // A single user drag moves exactly one item; every other item keeps
            // its relative order. The moved item is the one whose removal makes
            // the two sequences identical, and whose index actually changed.
            if let moved = desiredOrder.enumerated().first(where: { i, id in
                currentOrder.firstIndex(of: id) != i
                    && currentOrder.filter { $0 != id } == desiredOrder.filter { $0 != id }
            }) {
                ops.append(.init(kind: .reorderItem(id: moved.element), targetIndex: moved.offset))
            }
        }

        if currentBoundary != desiredBoundary {
            ops.append(.init(kind: .moveDivider, targetIndex: desiredBoundary))
        }

        return ops
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MenuBarLayoutPlanTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/HiddenBar/MenuBarLayoutPlan.swift Tests/QuackKitTests/MenuBarLayoutPlanTests.swift
git commit -m "feat(menubar): pure layout-diff planner for the drag editor"
```

---

### Task 2: StatusItemDragger (synth-⌘-drag executor)

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/StatusItemDragger.swift`

**Interfaces:**
- Consumes: nothing (posts CGEvents).
- Produces: `enum StatusItemDragger` with
  `static func drag(from: CGPoint, toX: CGFloat, steps: Int = 20)` — synth ⌘-drag from `from` (global top-left, matching AX frames) horizontally to `toX`, restoring the cursor afterward. Caller runs it off the main actor.

This mirrors `SynthClick` in `HiddenBarGeometry.swift`: it only posts events (no tap), holds `.maskCommand` for the whole gesture (⌘ is what tells macOS to reorder a status item), and warps/restores the cursor.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Quack/MenuBar/HiddenBar/StatusItemDragger.swift
import AppKit
import CoreGraphics

/// Synthesizes a ⌘-drag of a menu-bar status item from `from` to x=`toX`,
/// keeping the menu-bar Y. Holding ⌘ for the whole gesture is what makes macOS
/// treat it as a status-item reorder (same gesture a user performs by hand).
/// Posts events only — no CGEvent tap — so it cannot gate input / freeze the Mac
/// (see CLAUDE.md). Call OFF the main actor: it sleeps between drag steps.
enum StatusItemDragger {
    /// `from` is in global Quartz coordinates (top-left origin), matching AX frames.
    static func drag(from: CGPoint, toX: CGFloat, steps: Int = 20) {
        let restore = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .combinedSessionState)

        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: src, mouseType: type,
                            mouseCursorPosition: p, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }

        CGWarpMouseCursorPosition(from)
        post(.leftMouseDown, from)
        usleep(20_000)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            let x = from.x + (toX - from.x) * t
            post(.leftMouseDragged, CGPoint(x: x, y: from.y))
            usleep(8_000)
        }
        post(.leftMouseUp, CGPoint(x: toX, y: from.y))
        if let restore {
            usleep(60_000)
            CGWarpMouseCursorPosition(restore)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (pre-existing `ToastPresenter` Sendable warning is fine).

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/StatusItemDragger.swift
git commit -m "feat(menubar): synth-cmd-drag executor for status items"
```

---

### Task 3: Mechanism spike — validate synth-⌘-drag of a third-party item

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift` (add `#if DEBUG` spike method)
- Modify: `Sources/Quack/Settings/SettingsView.swift` (add `#if DEBUG` button in `StatusSection`)
- Modify: `Sources/Quack/AppEnvironment.swift` (expose `#if DEBUG` passthrough)

**Interfaces:**
- Consumes: `StatusItemDragger.drag` (Task 2), `MenuBarAXScanner.scanAll` (existing), `MenuBarBand.current()` (existing), `ControlItemManager.expand()` / `.collapse()` / `.dividerMinX` (existing).
- Produces: `#if DEBUG HiddenBarService.spikeDragLeftmostShownItem()` and `AppEnvironment.spikeMenuBarDrag()` — log-only; no stored API for later tasks.

**Goal of this task:** run the drag once against the live bar and read the log to decide the branch for Tasks 4–6:
- **PASS** (item's `minX` moved) → build the full real-item reorder in Tasks 5–6.
- **FAIL** (unchanged / macOS ignored it) → in Tasks 5–6, disable within-section reorder and keep only cross-section (divider) moves. Record the outcome in the plan's Task 6 note before implementing the editor.

- [ ] **Step 1: Add the spike method to HiddenBarService**

Add inside `HiddenBarService`, after `endArrange()`:

```swift
#if DEBUG
    /// SPIKE (temporary): drag the leftmost SHOWN third-party item ~40pt left and
    /// log before/after minX. Proves whether macOS honors a synth-⌘-drag of an
    /// item Quack does not own. Remove once Tasks 4–6 land.
    func spikeDragLeftmostShownItem() {
        guard let control else { Log.notch.notice("spike: no control"); return }
        control.expand()
        let boundaryX = control.dividerMinX ?? 0
        let band = MenuBarBand.current()
        DispatchQueue.global(qos: .userInitiated).async {
            let items = MenuBarAXScanner.scanAll(menuBarBandY: band)
            guard let target = items.filter({ $0.frame.minX > boundaryX }).first else {
                Log.notch.notice("spike: no shown item to drag"); return
            }
            let before = target.frame.minX
            StatusItemDragger.drag(
                from: CGPoint(x: target.frame.midX, y: target.frame.midY),
                toX: target.frame.midX - 40)
            usleep(300_000)
            let after = MenuBarAXScanner.elementFrame(target.element)?.minX ?? before
            Log.notch.notice("spike: \(target.appName, privacy: .public) minX \(before) -> \(after) (moved=\(abs(after - before) > 4))")
            DispatchQueue.main.async { self.control?.collapse() }
        }
    }
#endif
```

- [ ] **Step 2: Expose it on AppEnvironment**

In `AppEnvironment.swift`, near `setHiddenBarArranging`, add:

```swift
#if DEBUG
    func spikeMenuBarDrag() { hiddenBarService.spikeDragLeftmostShownItem() }
#endif
```

- [ ] **Step 3: Add the debug button to StatusSection**

In `SettingsView.swift`, inside `StatusSection`'s `Section("Status")`, after the explanatory `Text(...)` line, add:

```swift
#if DEBUG
            Button("SPIKE: drag leftmost shown item") { env.spikeMenuBarDrag() }
                .controlSize(.small)
#endif
```

- [ ] **Step 4: Build, install, run the spike**

```bash
swift build
./Scripts/install.sh
```

Then: menu bar duck → Settings → Status tab → click **SPIKE: drag leftmost shown item**. Read the log:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.quack.menubar"' --level debug
```

Expected: a line `spike: <App> minX <X> -> <Y> (moved=true|false)`. Record `moved=` in Task 6's outcome note.

- [ ] **Step 5: Commit the spike**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/AppEnvironment.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "chore(menubar): temporary spike to validate synth-drag of 3rd-party item"
```

---

### Task 4: Capture all items + expose the layout from HiddenBarService

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/MenuBarItemImageCache.swift`
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`

**Interfaces:**
- Consumes: `MenuBarAXScanner.scanAll` (existing), `StatusWindowList.onScreen()` (existing), `ControlItemManager.expand/collapse/dividerMinX` (existing), `MenuBarItemImageCache.captureOnScreen` (existing).
- Produces:
  - `HiddenBarService.LayoutItem` (`Identifiable`): `id: String`, `name: String`, `icon: NSImage?`, `isHidden: Bool`.
  - `HiddenBarService.onLayoutChanged: (([LayoutItem]) -> Void)?` — fired (main) with the full L→R item list after a scan.
  - `HiddenBarService.refreshLayout()` — expand, scan ALL, capture ALL on-screen glyphs, classify by divider X, fire `onLayoutChanged`, then collapse (unless the editor is open — see Task 6).
  - `AppEnvironment.menuBarLayout: [HiddenBarService.LayoutItem]` (`@Published`) and the wiring that keeps it current.

- [ ] **Step 1: Widen the image cache to keep all captured glyphs**

`MenuBarItemImageCache.captureOnScreen` already captures whatever `items` it is handed and merges into `cache`. No signature change needed — Task 4 simply passes ALL scanned on-screen items instead of only the hidden ones. Confirm by reading `captureOnScreen`; no edit required in this step.

- [ ] **Step 2: Add the layout type and callback to HiddenBarService**

In `HiddenBarService.swift`, next to `HiddenPreviewItem`, add:

```swift
    struct LayoutItem: Identifiable { let id: String; let name: String; let icon: NSImage?; let isHidden: Bool }
    /// Fired (main) with the full L→R menu-bar item list after a scan — drives the editor.
    var onLayoutChanged: (([LayoutItem]) -> Void)?
```

- [ ] **Step 3: Add refreshLayout()**

Add to `HiddenBarService`, after `warmAndCollapse(...)`:

```swift
    /// Expand the bar, scan EVERY item, capture real glyphs for all on-screen
    /// items, classify by the divider X, and publish the full layout. Collapses
    /// afterward unless the editor is keeping the bar expanded (isArranging).
    func refreshLayout() {
        guard let control else { return }
        control.expand()
        control.setChevronVisible(true)
        let boundaryX = control.dividerMinX ?? 0
        let band = MenuBarBand.current()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBandY: band)
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self else { return }
                self.imageCache.captureOnScreen(items: items, windows: windows)
                let layout = items.map { item in
                    LayoutItem(id: item.id, name: item.appName,
                               icon: self.imageCache.image(forID: item.id) ?? item.appIcon,
                               isHidden: item.frame.minX < boundaryX)
                }
                self.onLayoutChanged?(layout)
                if !self.isArranging { self.control?.collapse() }
            }
        }
    }
```

- [ ] **Step 4: Publish the layout on AppEnvironment**

In `AppEnvironment.swift`, add near `hiddenBarItems`:

```swift
    @Published var menuBarLayout: [HiddenBarService.LayoutItem] = []
```

And in the init block where `hiddenBarService.onHiddenSetChanged` is wired (around line 101), add:

```swift
        hiddenBarService.onLayoutChanged = { [weak self] layout in
            Task { @MainActor in self?.menuBarLayout = layout }
        }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/AppEnvironment.swift Sources/Quack/MenuBar/HiddenBar/MenuBarItemImageCache.swift
git commit -m "feat(menubar): scan+capture all items and publish full layout"
```

---

### Task 5: MenuBarLayoutEditor (SwiftUI two-row drag view)

**Files:**
- Create: `Sources/Quack/MenuBar/HiddenBar/MenuBarLayoutEditor.swift`

**Interfaces:**
- Consumes: `HiddenBarService.LayoutItem` (Task 4).
- Produces: `struct MenuBarLayoutEditor: View` with
  - `let items: [HiddenBarService.LayoutItem]`
  - `let reorderEnabled: Bool` (false when the spike failed — cross-section only)
  - `let onCommit: (_ desiredOrder: [String], _ desiredBoundary: Int) -> Void`
  - `let onRefresh: () -> Void`

The view keeps a local editable `[LayoutItem]` seeded from `items`, renders a **Shown** row and a **Hidden** row of glyph tiles, supports drag between rows (and, if `reorderEnabled`, reorder within a row), and calls `onCommit(orderIds, hiddenCount)` on drop. Hidden items are `order[0..<boundary]`; the on-screen order is Hidden-left-to-right then Shown-left-to-right, matching the service's `minX < dividerX` classification.

- [ ] **Step 1: Write the view**

```swift
// Sources/Quack/MenuBar/HiddenBar/MenuBarLayoutEditor.swift
import SwiftUI
import UniformTypeIdentifiers

/// Ice-style editor: two rows of real-glyph tiles (Shown / Hidden). Drag a tile
/// to the other row to hide/show it; drag within a row to reorder (when enabled).
/// On any drop it reports the desired left→right id order and the Hidden count.
struct MenuBarLayoutEditor: View {
    let items: [HiddenBarService.LayoutItem]
    let reorderEnabled: Bool
    let onCommit: (_ desiredOrder: [String], _ desiredBoundary: Int) -> Void
    let onRefresh: () -> Void

    @State private var local: [HiddenBarService.LayoutItem] = []

    private var hidden: [HiddenBarService.LayoutItem] { local.filter { $0.isHidden } }
    private var shown: [HiddenBarService.LayoutItem] { local.filter { !$0.isHidden } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "Shown", section: shown, isHidden: false)
            row(title: "Hidden", section: shown.isEmpty && hidden.isEmpty ? [] : hidden, isHidden: true)
            HStack {
                Button("Refresh", action: onRefresh).controlSize(.small)
                if !reorderEnabled {
                    Text("Reordering isn't available on this macOS — drag between rows to hide/show.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { local = items }
        .onChange(of: items.map(\.id)) { _, _ in local = items }
    }

    @ViewBuilder
    private func row(title: String, section: [HiddenBarService.LayoutItem], isHidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(section) { item in
                    tile(item)
                        .onDrag { NSItemProvider(object: item.id as NSString) }
                        .onDrop(of: [.text], delegate: TileDrop(
                            target: item, intoHidden: isHidden, editor: self))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [.text], delegate: TileDrop(
                target: nil, intoHidden: isHidden, editor: self))
        }
    }

    private func tile(_ item: HiddenBarService.LayoutItem) -> some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
            }
        }
        .frame(width: 22, height: 22)
        .help(item.name)
    }

    // Called by the drop delegate: move `id` so it sits before `beforeID` (or at
    // the end of the section when nil) and belongs to the given section.
    fileprivate func move(id: String, intoHidden: Bool, beforeID: String?) {
        guard let moving = local.first(where: { $0.id == id }) else { return }
        // Same-section reorder is only allowed when enabled.
        if moving.isHidden == intoHidden && !reorderEnabled { return }
        var next = local.filter { $0.id != id }
        let updated = HiddenBarService.LayoutItem(
            id: moving.id, name: moving.name, icon: moving.icon, isHidden: intoHidden)
        if let beforeID, let idx = next.firstIndex(where: { $0.id == beforeID }) {
            next.insert(updated, at: idx)
        } else {
            // Append to the end of the target section: after the last item of it.
            if let lastIdx = next.lastIndex(where: { $0.isHidden == intoHidden }) {
                next.insert(updated, at: lastIdx + 1)
            } else if intoHidden {
                next.insert(updated, at: 0)          // first hidden item
            } else {
                next.append(updated)                 // first shown item
            }
        }
        // Normalize on-screen order: Hidden (L→R) then Shown (L→R).
        local = next.filter { $0.isHidden } + next.filter { !$0.isHidden }
        commit()
    }

    private func commit() {
        let order = local.map(\.id)
        let boundary = local.filter(\.isHidden).count
        onCommit(order, boundary)
    }
}

/// Drop delegate: drops onto a tile insert before it; drops onto the row's
/// empty space append to that section.
private struct TileDrop: DropDelegate {
    let target: HiddenBarService.LayoutItem?
    let intoHidden: Bool
    let editor: MenuBarLayoutEditor

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = obj as? String else { return }
            Task { @MainActor in
                editor.move(id: id, intoHidden: intoHidden, beforeID: target?.id)
            }
        }
        return true
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/MenuBarLayoutEditor.swift
git commit -m "feat(menubar): two-row drag editor view"
```

---

### Task 6: Wire the editor into settings + execute drops on the live bar

> **SPIKE OUTCOME (fill in from Task 3 before starting):** `moved = ____`.
> If `true`: pass `reorderEnabled: true` and implement `.reorderItem` execution.
> If `false`: pass `reorderEnabled: false`; still implement `.moveDivider`
> execution and log-skip any `.reorderItem` op.

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift` (add `executePlan`)
- Modify: `Sources/Quack/AppEnvironment.swift` (forward commit/refresh, track `reorderEnabled`)
- Modify: `Sources/Quack/Settings/SettingsView.swift` (`HiddenBarSection` renders the editor)

**Interfaces:**
- Consumes: `MenuBarLayoutPlan.plan` (Task 1), `StatusItemDragger.drag` (Task 2), `HiddenBarService.refreshLayout` / `onLayoutChanged` (Task 4), `MenuBarLayoutEditor` (Task 5), `MenuBarAXScanner.scanAll` + `elementFrame`, `ControlItemManager.expand/collapse/dividerMinX/dividerFrameOnScreen`.
- Produces:
  - `HiddenBarService.applyDesiredLayout(order: [String], boundary: Int, allowReorder: Bool)` — plans vs the current scan, executes ops via ⌘-drag against the live bar, re-scans, re-publishes.
  - `HiddenBarService.setEditing(_:)` — mirrors `beginArrange`/`endArrange` gating so hover-reveal is suppressed and the bar stays expanded while the editor is open.
  - `AppEnvironment.menuBarReorderEnabled: Bool`, `AppEnvironment.commitMenuBarLayout(order:boundary:)`, `AppEnvironment.setMenuBarEditing(_:)`.

- [ ] **Step 1: Add executePlan / applyDesiredLayout to HiddenBarService**

Add to `HiddenBarService`, after `refreshLayout()`:

```swift
    /// Keep the bar expanded and suppress hover-reveal while the editor is open.
    func setEditing(_ on: Bool) {
        isArranging = on
        if on {
            graceTimer?.invalidate(); graceTimer = nil
            panel.hide()
            state = .hidden
            control?.expand()
            control?.setChevronVisible(true)
            refreshLayout()
        } else {
            warmAndCollapse()
        }
    }

    /// Diff the desired layout against a fresh scan and execute the ops as
    /// ⌘-drags on the live bar. `allowReorder=false` (spike failed) skips item
    /// reorders and only moves the divider (hide/show still works).
    func applyDesiredLayout(order desiredOrder: [String], boundary desiredBoundary: Int,
                            allowReorder: Bool) {
        guard let control else { return }
        control.expand()
        let band = MenuBarBand.current()
        let menuBarY = (NSScreen.main.map { $0.frame.maxY - NSStatusBar.system.thickness / 2 }) ?? 12
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBandY: band)
            let dividerMinX = DispatchQueue.main.sync { control.dividerMinX ?? 0 }
            let currentOrder = items.map(\.id)
            let currentBoundary = items.filter { $0.frame.minX < dividerMinX }.count
            let ops = MenuBarLayoutPlan.plan(
                currentOrder: currentOrder, currentBoundary: currentBoundary,
                desiredOrder: desiredOrder, desiredBoundary: desiredBoundary)

            for op in ops {
                switch op.kind {
                case .reorderItem(let id):
                    guard allowReorder, let item = items.first(where: { $0.id == id }) else {
                        Log.notch.notice("layout: skip reorder \(id, privacy: .public) (disabled/missing)")
                        continue
                    }
                    let targetX = Self.xForIndex(op.targetIndex, items: items, movingID: id)
                    StatusItemDragger.drag(
                        from: CGPoint(x: item.frame.midX, y: item.frame.midY), toX: targetX)
                    usleep(250_000)
                case .moveDivider:
                    let fresh = MenuBarAXScanner.scanAll(menuBarBandY: band)
                    let targetX = Self.xForIndex(op.targetIndex, items: fresh, movingID: nil)
                    let dxFrame = DispatchQueue.main.sync { control.dividerFrameOnScreen }
                    if let f = dxFrame {
                        StatusItemDragger.drag(
                            from: CGPoint(x: f.midX, y: f.midY), toX: targetX)
                        usleep(250_000)
                    }
                }
            }
            _ = menuBarY   // y is read per-item from live frames above
            DispatchQueue.main.async { self?.refreshLayout() }
        }
    }

    /// Global-X to drop an item so it lands at `index` in the L→R order. Uses the
    /// left edge of the item currently at `index` (excluding the moving item), or
    /// just past the last item when appending.
    private static func xForIndex(_ index: Int, items: [MenuBarAXItem], movingID: String?) -> CGFloat {
        let rest = items.filter { $0.id != movingID }
        if index < rest.count { return rest[index].frame.minX + 2 }
        if let last = rest.last { return last.frame.maxX + 2 }
        return items.last?.frame.maxX ?? 0
    }
```

- [ ] **Step 2: Forward from AppEnvironment**

In `AppEnvironment.swift`, add:

```swift
    @Published var menuBarReorderEnabled = true   // set false if the Task 3 spike showed moved=false

    func setMenuBarEditing(_ on: Bool) { hiddenBarService.setEditing(on) }
    func commitMenuBarLayout(order: [String], boundary: Int) {
        hiddenBarService.applyDesiredLayout(order: order, boundary: boundary,
                                            allowReorder: menuBarReorderEnabled)
    }
```

- [ ] **Step 3: Render the editor in HiddenBarSection**

In `SettingsView.swift`, replace the `// Arrange mode:` `HStack { ... }` block (the Arrange button + hint, lines ~1479–1489) with:

```swift
                // Ice-style layout editor: drag tiles between Shown / Hidden.
                MenuBarLayoutEditor(
                    items: env.menuBarLayout,
                    reorderEnabled: env.menuBarReorderEnabled,
                    onCommit: { order, boundary in
                        env.commitMenuBarLayout(order: order, boundary: boundary)
                    },
                    onRefresh: { env.setMenuBarEditing(true) })
                    .onAppear { env.setMenuBarEditing(true) }
                    .onDisappear { env.setMenuBarEditing(false) }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Install and verify against the live bar**

```bash
./Scripts/install.sh
```

Menu bar duck → Settings → Menu Bar tab. Verify:
- Both rows show real glyphs (grant Screen Recording if tiles are app icons).
- Drag a tile from Shown to Hidden → that icon hides behind the chevron on the real bar (hover the chevron to confirm it's revealed there).
- Drag it back → it reappears in the real bar.
- If `menuBarReorderEnabled == true`: drag within a row → real bar order changes.
- Mac never freezes; input stays responsive throughout.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/AppEnvironment.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(menubar): wire drag editor to live-bar execution"
```

---

### Task 7: Remove the spike

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift`, `Sources/Quack/AppEnvironment.swift`, `Sources/Quack/Settings/SettingsView.swift`

- [ ] **Step 1: Delete the `#if DEBUG` spike blocks** added in Task 3 (the `spikeDragLeftmostShownItem` method, the `spikeMenuBarDrag()` passthrough, and the SPIKE button). Leave the `menuBarReorderEnabled` default set per the recorded outcome.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/AppEnvironment.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "chore(menubar): remove synth-drag spike"
```

---

## Self-Review

**Spec coverage:**
- Model & glyph capture (spec §1) → Task 4.
- Drag UI two rows (spec §2) → Task 5.
- Drop execution / planner + ⌘-drag (spec §3) → Tasks 1, 2, 6.
- Mechanism spike + fallback (spec §4, Milestone 1) → Task 3, gate in Tasks 5–6.
- Testable core in QuackKit (spec §5) → Task 1.
- Safety / no taps / off-main (spec §6) → Global Constraints, Tasks 2 & 6.
- Files list (spec §Files) → all created/modified across Tasks 1–7 (spike files revert in Task 7).

**Placeholder scan:** No TBD/TODO; the one intentional fill-in (Task 6 spike outcome) is a runtime result recorded during execution, not a missing design decision.

**Type consistency:** `LayoutItem(id,name,icon,isHidden)` used identically in Tasks 4/5/6. `DragOp(kind,targetIndex)` + `Kind.reorderItem(id:)`/`.moveDivider` consistent across Tasks 1/6. `plan(currentOrder:currentBoundary:desiredOrder:desiredBoundary:)` matches between Task 1 definition and Task 6 call. Editor callbacks `onCommit(order,boundary)`/`onRefresh` match `commitMenuBarLayout`/`setMenuBarEditing` wiring.
