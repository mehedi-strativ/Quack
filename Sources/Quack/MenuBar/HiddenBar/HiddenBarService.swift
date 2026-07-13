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
                MenuBarAXScanner.press(element: item.element)
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
