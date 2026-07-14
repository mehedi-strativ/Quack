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
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var policyTimer: Timer?
    private var warmAttempts = 0
    private(set) var isArranging = false
    /// True when the current display is non-notched and we're showing every icon
    /// (no hiding) per `hiddenBarShowAllOnExternal`.
    private var showingAll = false
    private let conditionMonitor = HiddenBarConditionMonitor()
    /// True while a system condition (on battery / Wi-Fi off) is forcing reveal.
    private var conditionReveal = false

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
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.warmAndCollapse() } }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyDisplayPolicy() } }
        // The menu bar (and our status item) follows the active display; poll to
        // notice when it moves between a notched and a non-notched display.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyDisplayPolicy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        policyTimer = timer
        conditionMonitor.onChange = { [weak self] c in self?.evaluateConditions(c) }
        conditionMonitor.start()
        // Items are still on-screen (divider expanded): capture, then collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.warmAndCollapse() }
    }

    func stop() {
        graceTimer?.invalidate(); graceTimer = nil
        policyTimer?.invalidate(); policyTimer = nil
        conditionMonitor.stop()
        conditionReveal = false
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
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
        // expand() relayouts asynchronously; the chevron/divider frames aren't
        // valid immediately (chevron reads (0,-22) at launch; the divider still
        // reports its collapsed off-screen X right after expand). Wait until BOTH
        // are on-screen — divider positive and at/left of the chevron — before
        // scanning, else the boundary is wrong and nothing classifies as hidden.
        guard let chevronMinX = control.chevronMinX, chevronMinX > 0,
              let dividerMinX = control.dividerMinX, dividerMinX > 0, dividerMinX <= chevronMinX else {
            warmAttempts += 1
            if warmAttempts <= 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.warmAndCollapse() }
            } else {
                control.collapse()
            }
            return
        }
        warmAttempts = 0
        // Non-notched display + "show all" setting → don't hide anything here.
        guard shouldHideOnCurrentDisplay() else {
            showingAll = true
            control.expand()
            control.setDividerVisible(false)
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
        // Classify by the DIVIDER, not the chevron: collapse() only pushes items
        // left of the divider off-screen, so the panel must show exactly those.
        let boundaryX = dividerMinX
        let band = MenuBarBand.current()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBandY: band)
            let hidden = items.filter { $0.frame.minX < boundaryX }
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self, !self.showingAll else { return }
                self.imageCache.captureOnScreen(items: hidden, windows: windows)
                self.hiddenItems = hidden
                self.control?.collapse()
                self.onHiddenSetChanged?(hidden.map {
                    .init(id: $0.id, name: $0.appName, icon: self.imageCache.image(forID: $0.id) ?? $0.appIcon)
                })
            }
        }
    }

    /// Arrange mode: expand the real bar in place with a visible divider so the
    /// user can ⌘-drag icons across the boundary. Suppresses hover-reveal.
    func beginArrange() {
        guard control != nil else { return }
        isArranging = true
        graceTimer?.invalidate(); graceTimer = nil
        panel.hide()
        state = .hidden
        control?.expand()
        control?.setDividerVisible(true)
    }

    /// Leave Arrange mode: hide the marker, re-capture glyphs, collapse.
    func endArrange() {
        isArranging = false
        control?.setDividerVisible(false)
        warmAndCollapse()
    }

    /// Whether hiding should be active on the display currently hosting the menu
    /// bar: always on a notched display; on a non-notched one only if the user
    /// hasn't opted to show everything there.
    private func shouldHideOnCurrentDisplay() -> Bool {
        if !settings.settings.hiddenBarShowAllOnExternal { return true }
        return currentDisplayHasNotch()
    }

    private func currentDisplayHasNotch() -> Bool {
        let screen: NSScreen?
        if let f = control?.chevronFrameOnScreen {
            screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main
        } else {
            screen = NSScreen.main
        }
        guard let screen else { return false }
        return NotchProbe.span(for: screen) != nil
    }

    /// Re-evaluate hide-vs-show-all when the active display may have changed.
    private func applyDisplayPolicy() {
        guard control != nil, !isArranging else { return }
        let hide = shouldHideOnCurrentDisplay()
        if hide && showingAll {
            warmAndCollapse()          // moved onto a notched display → re-hide
        } else if !hide && !showingAll {
            warmAndCollapse()          // moved onto a non-notched display → show all
        }
        evaluateConditions(conditionMonitor.conditions)   // also picks up setting changes
    }

    /// Auto-reveal the hidden panel while a system condition holds (on battery /
    /// Wi-Fi off), and auto-hide when it clears.
    private func evaluateConditions(_ c: HiddenBarConditions) {
        guard control != nil, !showingAll, !isArranging else {
            conditionReveal = false
            return
        }
        let want = (c.onBattery && settings.settings.hiddenBarRevealOnBattery)
                || (!c.wifiConnected && settings.settings.hiddenBarRevealOnWifiOff)
        if want && !conditionReveal {
            conditionReveal = true
            renderPanel()
        } else if !want && conditionReveal {
            conditionReveal = false
            if state == .hidden { panel.hide() }
        }
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
        case .revealed, .pinned: reveal()
        case .hidden:            if conditionReveal { renderPanel() } else { panel.hide() }
        }
    }

    private func reveal() {
        renderPanel()   // render the set captured at the last warm
    }

    private func renderPanel() {
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
        control?.expand()          // real item snaps on-screen; menu opens there
        panel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                // Synthesize a real click at the item's LIVE on-screen frame (it
                // just snapped back via expand()). AXPress reports success but
                // doesn't open most third-party popovers — a real click does.
                let frame = MenuBarAXScanner.elementFrame(item.element) ?? item.frame
                SynthClick.left(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            // Arm collapse-on-next-mouseUp AFTER the synth click's own mouseUp has
            // passed, so we don't immediately dismiss the menu we just opened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.armCollapseAfterMenu()
            }
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
