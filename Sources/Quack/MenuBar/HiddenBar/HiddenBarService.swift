import AppKit
import Combine
import ApplicationServices
import QuackKit

/// Bartender-style hidden menu bar. Hides items chosen by the user (⌘-dragged
/// left of the chevron) by expanding a divider status item off-screen; reveals
/// them in a secondary panel rendered from glyphs captured while the items were
/// on-screen (off-screen capture returns nil — see the hidden-bar spike).
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
    private var scrollMonitor: Any?
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var policyTimer: Timer?
    private var refreshTimer: Timer?
    private let warmWaiter = AXSettleWaiter<(chevron: CGRect?, divider: CGRect?)>()
    private let clickWaiter = AXSettleWaiter<CGRect?>()
    private(set) var isArranging = false
    /// True when no connected display has a notch, so every icon is shown
    /// (hiding is active whenever any connected display has a notch).
    private var showingAll = false
    private let conditionMonitor = HiddenBarConditionMonitor()
    /// True while a system condition (on battery / Wi-Fi off) is forcing reveal.
    private var conditionReveal = false
    /// The specific hidden item(s) a condition is currently surfacing.
    private var conditionItems: [MenuBarAXItem] = []

    struct HiddenPreviewItem: Identifiable { let id: String; let name: String; let icon: NSImage? }
    /// Called (main) whenever the hidden set changes — drives the Settings preview.
    var onHiddenSetChanged: (([HiddenPreviewItem]) -> Void)?

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
        // Listen-only — NOT a CGEventTap, so it cannot gate input (CLAUDE.md
        // freeze rule only applies to taps). Bartender/Vanilla-style scroll-
        // to-reveal: scrolling anywhere in the menu bar band reveals, same as
        // hovering the chevron.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.handleScroll(event) }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.warmAndCollapse() } }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyDisplayPolicy() } }
        // Belt-and-suspenders poll for a connected notched display, alongside
        // the didChangeScreenParametersNotification observer above.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyDisplayPolicy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        policyTimer = timer
        // Hidden-item glyphs are static captures (off-screen capture returns
        // nil — see the hidden-bar spike), so a menu extra whose rendering
        // changes over time (clock, battery %, CPU temp, countdown text) goes
        // stale in the panel once cached. Recapture on a steady cadence, but
        // `refreshWhileShowing` only does real work while something's actually
        // on screen to look at, so this stays a single quiet capture at
        // hide-time instead of a perpetual background flash.
        let refresh = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWhileShowing() }
        }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh
        conditionMonitor.onChange = { [weak self] c in self?.evaluateConditions(c) }
        conditionMonitor.start()
        // Items are still on-screen (divider expanded): capture, then collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.warmAndCollapse() }
    }

    func stop() {
        graceTimer?.invalidate(); graceTimer = nil
        policyTimer?.invalidate(); policyTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        warmWaiter.cancel()
        clickWaiter.cancel()
        conditionMonitor.stop()
        conditionReveal = false
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let o = activeObserver { NotificationCenter.default.removeObserver(o); activeObserver = nil }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        panel.hide()
        control?.setDividerVisible(false)
        control?.teardown(); control = nil
        hiddenItems = []
        state = .hidden
        isArranging = false
        showingAll = false
    }

    /// Capture glyphs for the currently-on-screen hidden set, then collapse.
    private func warmAndCollapse() {
        guard let control, !isArranging else { return }   // don't collapse mid-arrange
        control.expand()
        // A hidden chevron (isVisible=false) reports a (0,0) frame, which would
        // fail the on-screen gate below forever. Make it visible first so its
        // frame is readable; the end of this routine decides final visibility.
        control.setChevronVisible(true)
        // expand() relayouts asynchronously; the chevron/divider frames aren't
        // valid immediately (chevron reads (0,-22) at launch; the divider still
        // reports its collapsed off-screen X right after expand). Wait until BOTH
        // sit ON a real screen — this rejects the launch garbage AND the collapsed
        // divider, while (unlike an X>0 test) still accepting displays at negative
        // global X, i.e. external monitors positioned left of the built-in.
        // A settled menu-bar item sits at the TOP edge of the screen it's on
        // (frame.maxY ≈ that screen's maxY).
        warmWaiter.start(
            on: .main,
            probe: { [weak self] in
                (chevron: self?.control?.chevronFrameOnScreen, divider: self?.control?.dividerFrameOnScreen)
            },
            isSettled: { Self.isOnScreenAtTopEdge($0.chevron) && Self.isOnScreenAtTopEdge($0.divider) },
            completion: { [weak self] outcome in
                // On exhaustion, give up silently — matches the prior behavior
                // (no final action was taken when the 25-attempt budget ran out).
                guard case .settled(let frames) = outcome,
                      let chevronFrame = frames.chevron, let dividerFrame = frames.divider else { return }
                self?.proceedAfterSettled(chevronFrame: chevronFrame, dividerFrame: dividerFrame)
            })
    }

    /// Runs once the chevron/divider frames are confirmed on-screen: assigns
    /// roles, decides hide-vs-show-all, warns on an unsafe chevron placement,
    /// then scans + captures the hidden set off the main thread and collapses.
    private func proceedAfterSettled(chevronFrame: CGRect, dividerFrame: CGRect) {
        guard let control, !isArranging else { return }
        control.refreshRoles()   // assign chevron glyph to the rightmost item now
        let chevronMinX = (control.chevronMinX ?? chevronFrame.minX)
        let dividerMinX = (control.dividerMinX ?? dividerFrame.minX)
        // No connected display has a notch → nothing to hide.
        guard shouldHideOnCurrentDisplay() else {
            showingAll = true
            control.expand()
            control.setDividerVisible(false)
            control.setChevronVisible(false)   // nothing hidden here → no chevron
            panel.hide()
            state = .hidden
            hiddenItems = []
            onHiddenSetChanged?([])
            return
        }
        showingAll = false
        if let notch = NotchProbe.current(), !ChevronPlacement.isSafe(chevronMinX: chevronMinX, notch: notch) {
            Log.notch.notice("hidden bar: chevron left of notch — ⌘-drag it right of the notch")
        }
        // (Divider is by definition the leftmost of the two control items now,
        // so it's always left of the chevron — no flip possible.)
        // Classify by the DIVIDER, not the chevron: collapse() only pushes items
        // left of the divider off-screen, so the panel must show exactly those.
        let boundaryX = dividerMinX
        let bands = MenuBarBand.all()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBands: bands)
            let hidden = items.filter { $0.frame.minX < boundaryX }
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self, !self.showingAll, !self.isArranging else { return }
                self.imageCache.captureOnScreen(items: hidden, windows: windows)
                self.hiddenItems = hidden
                self.control?.collapse()
                // Keep the chevron visible on the hiding (notched) display even
                // when nothing is hidden yet — it's the control + Arrange anchor.
                // (It's hidden only in the external show-all path above.)
                self.control?.setChevronVisible(true)
                self.onHiddenSetChanged?(hidden.map {
                    .init(id: $0.id, name: $0.appName, icon: self.imageCache.image(forID: $0.id) ?? $0.appIcon)
                })
                // A hover/pinned panel already on screen was rendered from the
                // now-stale set — refresh it in place with the glyphs just
                // captured. (The condition-reveal panel doesn't need this: it
                // re-renders from `hiddenItems` on its own 1.5s policy tick.)
                if self.state == .revealed || self.state == .pinned { self.renderPanel(self.hiddenItems) }
            }
        }
    }

    /// Recapture glyphs while a panel is actually on screen, so a hidden item
    /// whose real glyph is still updating (clock, battery %, CPU temp) doesn't
    /// go stale for the duration of a hover/pin/condition-reveal. No-ops (cheap)
    /// the rest of the time.
    private func refreshWhileShowing() {
        guard control != nil, !isArranging, !showingAll,
              state != .hidden || conditionReveal else { return }
        warmAndCollapse()
    }

    /// Arrange mode: expand the real bar in place with a visible divider so the
    /// user can ⌘-drag icons across the boundary. Suppresses hover-reveal.
    func beginArrange() {
        guard control != nil else { return }
        isArranging = true
        graceTimer?.invalidate(); graceTimer = nil
        warmWaiter.cancel()
        clickWaiter.cancel()
        panel.hide()
        state = .hidden
        control?.expand()
        control?.setChevronVisible(false)  // during arrange the white bar is the only marker
        control?.setDividerVisible(true)
    }

    /// Leave Arrange mode: hide the marker, re-capture glyphs, collapse.
    func endArrange() {
        isArranging = false
        control?.setDividerVisible(false)
        warmAndCollapse()
    }

    /// Whether hiding should be active. The divider/chevron are a SINGLE pair
    /// of status items mirrored identically onto every display's menu bar —
    /// there is no way to collapse one display's bar while leaving another
    /// expanded. So this can't be "is the display I'm currently looking at
    /// notched" (that flapped on/off as the mouse moved between displays,
    /// undoing the hide whenever it drifted onto an external monitor — you had
    /// to toggle the feature to force a fresh collapse). It's a static,
    /// hardware-based rule instead: hide whenever ANY connected display has a
    /// notch; show everything only when none do (e.g. lid closed, external-only).
    private func shouldHideOnCurrentDisplay() -> Bool {
        NSScreen.screens.contains { NotchProbe.span(for: $0) != nil }
    }

    /// Is this frame a real, settled on-screen menu-bar position? Never gate on
    /// `minX >= 0` — external displays can sit at negative global X, so a valid
    /// frame can legitimately have minX < 0 (see the hidden-bar capture-findings
    /// memory). Instead: does it intersect some screen, and sit at that screen's
    /// top edge (frame.maxY ≈ that screen's maxY)?
    private static func isOnScreenAtTopEdge(_ r: CGRect?) -> Bool {
        guard let r, let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) else { return false }
        return abs(screen.frame.maxY - r.maxY) < 40
    }

    /// Re-evaluate hide-vs-show-all when the connected display set may have changed.
    private func applyDisplayPolicy() {
        guard let control, !isArranging else { return }
        // Keep the chevron glyph on the current rightmost (visible) item every
        // tick — independent of the AX warm, which can stall on its frame gate.
        if !showingAll { control.refreshRoles() }
        let hide = shouldHideOnCurrentDisplay()
        if hide && showingAll {
            warmAndCollapse()          // a notched display connected → re-hide
        } else if !hide && !showingAll {
            warmAndCollapse()          // last notched display disconnected → show all
        }
        evaluateConditions(conditionMonitor.conditions)   // also picks up setting changes
    }

    /// Auto-reveal ONLY the specific hidden icon(s) tied to an active system
    /// condition (Battery when on battery, Wi-Fi when disconnected), and hide
    /// again when the condition clears. Matches Control Center items by AX title.
    private func evaluateConditions(_ c: HiddenBarConditions) {
        guard control != nil, !showingAll, !isArranging else {
            conditionReveal = false; conditionItems = []
            return
        }
        var want: [MenuBarAXItem] = []
        if c.onBattery && settings.settings.hiddenBarRevealOnBattery {
            want += hiddenItems.filter { Self.isBattery($0.title) }
        }
        if !c.wifiConnected && settings.settings.hiddenBarRevealOnWifiOff {
            want += hiddenItems.filter { Self.isWifi($0.title) }
        }
        if !want.isEmpty {
            conditionReveal = true
            conditionItems = want
            if state == .hidden { renderPanel(want) }   // don't override a hover showing all
        } else if conditionReveal {
            conditionReveal = false; conditionItems = []
            if state == .hidden { panel.hide() }
        }
    }

    private static func isBattery(_ title: String) -> Bool {
        title.range(of: "battery", options: .caseInsensitive) != nil
    }
    private static func isWifi(_ title: String) -> Bool {
        // Title is e.g. "Wi‑Fi, connected, 3 bars" (note the non-breaking hyphen).
        let t = title.lowercased().replacingOccurrences(of: "\u{2011}", with: "").replacingOccurrences(of: "-", with: "")
        return t.contains("wifi")
    }

    private func handle(_ event: RevealEvent) {
        guard !isArranging, !showingAll else { return }   // no reveal while arranging / showing all
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
        case .revealed: reveal()
        case .pinned:   pin()
        case .hidden:   unpin()
        }
    }

    /// A scroll (or two-finger swipe, reported as the same event type) over
    /// the menu bar reveals the hidden set, same as chevron-hover. There's no
    /// natural "exit" event for a scroll the way there is for a tracking-area
    /// hover, so each tick immediately follows the reveal with `.exitAll` —
    /// which (per `HiddenBarReveal`) keeps the state `.revealed` but (re)arms
    /// the same short grace-hide timer hover already uses. As long as scroll
    /// ticks keep arriving faster than the grace delay, the panel stays open;
    /// once they stop, it grace-hides exactly like a hover would.
    private func handleScroll(_ event: NSEvent) {
        guard !isArranging, !showingAll,
              event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        let point = NSEvent.mouseLocation   // Cocoa, bottom-left origin
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 12
        else { return }
        handle(.hoverChevron)
        handle(.exitAll)
    }

    private func reveal() {
        renderPanel(hiddenItems)   // hover shows the full hidden set
    }

    /// Click-to-pin: keep the replica strip up persistently (unlike hover, which
    /// grace-hides) and flip the chevron to ▶. Stays open until clicked again.
    private func pin() {
        control?.setChevronExpanded(true)
        renderPanel(hiddenItems)
    }

    /// Leave the pinned state: restore the ◀ glyph and fall back to any
    /// condition-driven reveal (or nothing).
    private func unpin() {
        control?.setChevronExpanded(false)
        if conditionReveal { renderPanel(conditionItems) } else { panel.hide() }
    }

    private func renderPanel(_ items: [MenuBarAXItem]) {
        // Anchor the panel to the display that actually hosts the chevron, not
        // NSScreen.main — the menu bar (and chevron) can be on a secondary
        // display, where a main-screen frame would place the panel off-screen.
        guard let chevronFrame = control?.chevronFrameOnScreen,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(chevronFrame) }) ?? NSScreen.main
        else { return }
        let vms = items.map { item -> HiddenBarItemVM in
            let image = imageCache.image(forID: item.id) ?? item.appIcon
            let width = HiddenBarLayout.itemDisplayWidth(
                imageSize: image?.size ?? .zero, targetHeight: HiddenBarLayout.itemHeight,
                minWidth: 22, maxWidth: 68)
            return HiddenBarItemVM(id: item.id, image: image, item: item, displayWidth: width)
        }
        // Anchored at the menu bar's top edge (screen.maxY) so it reads as a
        // continuation of the primary bar, but deliberately taller than the
        // native bar thickness — see `HiddenBarLayout.itemHeight`.
        let frame = HiddenBarLayout.panelFrame(
            itemWidths: vms.map(\.displayWidth), spacing: 10, padding: 8,
            height: HiddenBarLayout.itemHeight + 10,
            chevronMidX: chevronFrame.midX,
            panelTopY: screen.frame.maxY,
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

    /// `expand()` just changed the divider's `.length`, which relayouts
    /// asynchronously — sometimes with a multi-second lag (see the hidden-bar
    /// capture-findings memory) — so the item's live AX frame can still be
    /// mid-transition well after a fixed 0.15s wait. Clicking too early either
    /// missed (nothing under the cursor) or hit the item's stale/off-screen
    /// position — the "clicking sometimes does nothing" bug. Poll for the
    /// frame to actually be on-screen instead of guessing a fixed delay.
    private func forwardClick(_ item: MenuBarAXItem) {
        control?.expand()          // real item snaps on-screen; menu opens there
        panel.hide()
        clickWaiter.start(
            on: DispatchQueue.global(qos: .userInitiated),
            probe: { MenuBarAXScanner.elementFrame(item.element) },
            isSettled: { Self.isOnScreenAtTopEdge($0) },
            completion: { [weak self] outcome in
                let frame: CGRect
                switch outcome {
                case .settled(let f):   frame = f ?? item.frame
                case .exhausted(let f): frame = f ?? item.frame   // last resort: stale beats nothing
                }
                DispatchQueue.main.async { self?.sendForwardedClick(frame: frame) }
            })
    }

    private func sendForwardedClick(frame: CGRect) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Synthesize a real click at the item's LIVE on-screen frame. AXPress
            // reports success but doesn't open most third-party popovers — a real
            // click does.
            SynthClick.left(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        // Arm collapse-on-next-mouseUp AFTER the synth click's own mouseUp has
        // passed, so we don't immediately dismiss the menu we just opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.armCollapseAfterMenu()
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
