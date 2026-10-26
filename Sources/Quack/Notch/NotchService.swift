import AppKit
import SwiftUI
import Combine
import CSMC
import QuackKit

/// Owns the notch panel: a system-load row (sampled only while open) and
/// Claude agent snapshots. Panel top anchored at cocoaNotchRect.minY,
/// content hangs DOWN, never behind the physical cutout.
@MainActor
final class NotchService: NSObject, ManagedService {
    /// Set by AppEnvironment after construction (opens the Settings window).
    var onOpenSettings: (() -> Void)?
    private let settings: SettingsStore
    private let reader = NotchScreenReader()
    private let model = NotchContentViewModel()
    private let agentsService: AgentsService
    private var panel: NotchPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var wired = false
    private var agentsRunning = false
    private var loadTimer: Timer?
    private var hovering = false
    /// Request ids already seen, so only a NEW request pops the panel open.
    private var seenPermissionIDs: Set<String> = []
    /// "session|message" of agents needing you, so only a NEW need pops it open.
    private var needsYouKeys: Set<String>?
    private var autoClose: DispatchWorkItem?
    /// Shrink animation running; repositions wait for it.
    private var closing = false
    /// Shrinks the window to the settled shape after a shrink animation.
    private var trimWindow: DispatchWorkItem?
    private var closeGeneration = 0
    /// Esc-to-minimize monitors, installed only while the panel is open.
    private var escMonitors: [Any] = []
    private var lastLoad: SystemLoad?

    /// Collapsed hover strip height, hanging below the notch. It only carries
    /// the compact status lights; all detail is revealed on hover.
    private let hoverMargin: CGFloat = 8
    /// Strip height while status dots show (6pt dots + 3pt above and below).
    private let peekStripHeight: CGFloat = 12
    private let expandedWidth: CGFloat = 420
    /// Wider while a question / permission card shows, for its option rows.
    private let requestWidth: CGFloat = 480
    /// Height of the Quack footer row (duck button + padding).
    private let footerRowHeight: CGFloat = 26
    /// System-load row (24) + its top padding (10).
    private let systemRowHeight: CGFloat = 34
    /// How long a "needs you" pop-open (no request to answer) stays up.
    private let peekSeconds: TimeInterval = 6

    init(settings: SettingsStore, claudeInstaller: ClaudeConfigInstaller) {
        self.settings = settings
        self.agentsService = AgentsService(installer: claudeInstaller)
    }

    func start() {
        reader.onChange = { [weak self] in self?.repositionOrTeardown() }
        reader.startObserving()
        applyAgentsFlag()
        guard reader.currentLayout() != nil else { return }
        buildPanelIfNeeded()
        wireIfNeeded()
        reposition()
    }

    func stop() {
        reader.stopObserving()
        reader.onChange = nil
        cancellables.removeAll()
        wired = false
        stopSampling()
        stopEscMonitor()
        if agentsRunning { agentsService.stop(); agentsRunning = false }
        panel?.orderOut(nil)
        panel = nil
        model.isOpen = false
        model.showsExpanded = false
        closing = false
        model.agents = []
        model.permissions = []
        seenPermissionIDs = []
        needsYouKeys = nil
        autoClose?.cancel(); autoClose = nil
        hovering = false
    }

    private func wireIfNeeded() {
        guard !wired else { return }
        wired = true
        model.onHoverChange = { [weak self] h in self?.handleHover(h) }
        model.onAgentTap = { [weak self] agent in self?.focusAgent(agent) }
        model.onSeen = { [weak self] agent in self?.agentsService.markSeen(agent) }
        model.onAnswer = { [weak self] prompt, decision in
            guard let self else { return }
            self.agentsService.answer(prompt, decision)
            // Typed an answer: give the keyboard back without closing.
            if let panel = self.panel, panel.isKeyWindow { panel.orderOut(nil); self.reposition() }
        }
        model.onOpenQuack = { [weak self] in self?.onOpenSettings?() }

        agentsService.$agents
            .sink { [weak self] a in self?.agentsChanged(a) }
            .store(in: &cancellables)
        model.$promptHeight
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reposition() } }
            .store(in: &cancellables)
        agentsService.$permissions
            .sink { [weak self] p in self?.permissionsChanged(p) }
            .store(in: &cancellables)
        agentsService.$integrationInstalled
            .sink { [weak self] i in self?.model.integrationInstalled = i }
            .store(in: &cancellables)
        settings.$settings
            .map { ($0.notchAgentsEnabled, $0.notchAnswerPermissions) }
            .removeDuplicates(by: ==)
            .sink { [weak self] _ in self?.applyAgentsFlag(); self?.reposition() }
            .store(in: &cancellables)
    }

    /// Starts/stops the agent source to match its flag. The coordinator
    /// handles the whole-panel lifecycle; this handles the agents zone.
    private func applyAgentsFlag() {
        let enabled = settings.settings.notchAgentsEnabled
        model.agentsEnabled = enabled
        agentsService.answersPermissions = settings.settings.notchAnswerPermissions
        guard enabled != agentsRunning else { return }
        agentsRunning = enabled
        enabled ? agentsService.start() : agentsService.stop()
    }

    /// Samples temperature + machine load every 1.5s while the panel is open,
    /// off the main thread; CPU % is the tick diff between two samples (same
    /// math as the temperature popover).
    private func startSampling() {
        guard loadTimer == nil else { return }
        sampleLoad()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLoad() }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadTimer = timer
    }

    private func stopSampling() {
        loadTimer?.invalidate(); loadTimer = nil
        lastLoad = nil
    }

    private func sampleLoad() {
        DispatchQueue.global(qos: .utility).async {
            let load = ProcessSampler.systemLoad()
            let tempC = csmc_cpu_temperature()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadTimer != nil else { return }   // closed meanwhile
                if let prev = self.lastLoad {
                    let total = load.cpuTotalTicks &- prev.cpuTotalTicks
                    if total > 0 {
                        self.model.cpuPercent = Double(load.cpuBusyTicks &- prev.cpuBusyTicks) / Double(total) * 100
                    }
                }
                self.model.gpuPercent = load.gpuPercent
                self.model.memoryPercent = load.memoryPercent
                if tempC > 0 {
                    let f = self.settings.settings.temperatureFahrenheit
                    let v = f ? tempC * 9 / 5 + 32 : tempC
                    self.model.temperatureText = "\(Int(v.rounded()))°\(f ? "F" : "C")"
                } else {
                    self.model.temperatureText = nil
                }
                self.lastLoad = load
            }
        }
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: expandedWidth, height: 40))
        guard let content = p.contentView else { return }
        let host = NotchHostingView(rootView: NotchContentView(model: model))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        panel = p
    }

    private func repositionOrTeardown() {
        guard reader.currentLayout() != nil else {
            panel?.orderOut(nil); model.isOpen = false; return
        }
        buildPanelIfNeeded()
        wireIfNeeded()
        reposition()
    }

    /// Collapsed/peek: a strip hanging below the notch cutout (menu bar stays
    /// usable). Expanded: a curtain from the very top of the screen, with
    /// `contentTopInset` pushing content below the physical camera housing.
    ///
    /// Motion happens in SwiftUI, not by animating the window: the window is
    /// set (instantly, while transparent) to at least the target size, the
    /// content is laid out once at that size, and only the black shape's
    /// size springs — out of the notch on open, back into it on close. A
    /// window-frame animation re-lays out every frame and stutters.
    private func reposition() {
        guard let layout = reader.currentLayout(), let panel, !closing else { return }
        defer { panel.orderFrontRegardless() }
        guard model.isOpen else {
            trimWindow?.cancel()
            model.showsExpanded = false
            model.contentTopInset = 0
            model.shapeSize = stripFrame(layout).size
            panel.setFrame(stripFrame(layout), display: true)
            return
        }
        model.contentTopInset = layout.cocoaNotchRect.height
        let target = openSize(layout)
        let opening = !model.showsExpanded
        if opening {
            model.showsExpanded = true
            model.shapeSize = notchFrame(layout).size   // start at the notch
        }
        model.contentSize = target
        // Grow the (transparent) window first; trim it after a shrink settles.
        let window = panel.frame.size
        if opening || target.width > window.width || target.height > window.height {
            let size = opening ? target : CGSize(width: max(window.width, target.width),
                                                 height: max(window.height, target.height))
            panel.setFrame(canvasFrame(layout, size), display: true)
        }
        if model.shapeSize != target {
            let spring: Animation = opening ? .spring(response: 0.42, dampingFraction: 0.8)
                                            : .spring(response: 0.3, dampingFraction: 0.9)
            // Next runloop on open, so the notch-sized first frame renders.
            DispatchQueue.main.async { [model] in withAnimation(spring) { model.shapeSize = target } }
        }
        trimWindow?.cancel()
        if target.width < window.width || target.height < window.height {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.isOpen, !self.closing, self.model.contentSize == target else { return }
                panel.setFrame(self.canvasFrame(layout, target), display: true)
            }
            trimWindow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// The hover strip hanging just below the notch; taller while it shows
    /// status dots so they fit whole.
    private func stripFrame(_ layout: NotchLayout) -> NSRect {
        let width = max(layout.cocoaNotchRect.width, 120)
        let height = model.showsPeek ? peekStripHeight : hoverMargin
        return NSRect(x: layout.cocoaNotchRect.midX - width / 2, y: layout.cocoaNotchRect.minY - height,
                      width: width, height: height)
    }

    /// The notch plus the hover strip: where opening starts and closing ends.
    /// Including the strip keeps the pointer inside the shape as it grows, so
    /// the hover that opened it doesn't read as an exit.
    private func notchFrame(_ layout: NotchLayout) -> NSRect {
        layout.cocoaNotchRect.union(stripFrame(layout))
    }

    /// Width follows the content (wider while a request card shows); height
    /// is content + the covered cutout band, capped so it scrolls instead of
    /// running off the screen.
    private func openSize(_ layout: NotchLayout) -> CGSize {
        CGSize(width: model.permissions.isEmpty ? expandedWidth : requestWidth,
               height: min(expandedHeight(), layout.screen.visibleFrame.height * 0.85) + layout.cocoaNotchRect.height)
    }

    /// A window of `size`, top edge at the screen top, centered on the notch.
    private func canvasFrame(_ layout: NotchLayout, _ size: CGSize) -> NSRect {
        NSRect(x: layout.cocoaNotchRect.midX - size.width / 2, y: layout.screen.frame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Expanded height from visible zones.
    private func expandedHeight() -> CGFloat {
        var h: CGFloat = 10                                     // bottom padding
        h += footerRowHeight                                    // Quack footer (duck button)
        h += systemRowHeight
        if !model.permissions.isEmpty { h += model.promptHeight + 10 }
        if model.agentsEnabled {
            h += 30                                             // header row
            if !model.permissions.isEmpty {
                // cards hidden while a request waits (header only)
            } else if !model.integrationInstalled || model.agents.isEmpty {
                h += 28                                         // CTA / empty row
            } else {
                let visible = min(model.agents.count, 3)
                h += CGFloat(visible) * 100 + CGFloat(visible - 1) * 8
            }
            h += 10                                             // zone bottom pad
        }
        return h
    }

    private func handleHover(_ hovering: Bool) {
        self.hovering = hovering
        // Typing an answer keeps it open even if the pointer drifts off.
        if !hovering, panel?.isKeyWindow == true { return }
        setOpen(hovering)
    }

    /// A session that newly needs you (finished, asking, waiting on a plan)
    /// pops the panel open for a few seconds. The first read after start
    /// only records state, so launching Quack doesn't pop it.
    private func agentsChanged(_ agents: [AgentSnapshot]) {
        model.agents = agents
        let keys = Set(agents.filter { $0.status == .needsYou }
            .map { "\($0.sessionID)|\($0.statusMessage ?? "")" })
        let hasNew = needsYouKeys.map { !keys.subtracting($0).isEmpty } ?? false
        needsYouKeys = keys
        guard hasNew, model.agentsEnabled else { reposition(); return }
        setOpen(true)
        scheduleAutoClose()
    }

    private func scheduleAutoClose() {
        autoClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, self.model.permissions.isEmpty,
                  self.panel?.isKeyWindow != true else { return }
            self.setOpen(false)
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekSeconds, execute: work)
    }

    /// A new request pops the panel open without a hover; it closes again
    /// once nothing is pending (unless the pointer is in it). Moving the
    /// pointer in and out dismisses it like any hover.
    private func permissionsChanged(_ prompts: [PermissionPrompt]) {
        model.permissions = prompts
        let ids = Set(prompts.map(\.id))
        let hasNew = !ids.subtracting(seenPermissionIDs).isEmpty
        seenPermissionIDs = ids
        if hasNew {
            autoClose?.cancel()
            setOpen(true)
        } else if prompts.isEmpty && !hovering && model.isOpen {
            setOpen(false)
        } else {
            reposition()
        }
    }

    private func setOpen(_ open: Bool) {
        closeGeneration += 1
        if open {
            closing = false
            model.isOpen = true
            startSampling()
            startEscMonitor()
            reposition()
            return
        }
        stopSampling()
        stopEscMonitor()
        guard model.isOpen, model.showsExpanded, let panel, let layout = reader.currentLayout() else {
            model.isOpen = false; reposition(); return
        }
        // Hand keyboard focus back to the app you were typing in.
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
        // Spring the shape back into the notch with the content still drawn,
        // then swap to the hover strip. A re-open mid-shrink bumps the
        // generation and cancels the swap.
        closing = true
        trimWindow?.cancel()
        let generation = closeGeneration
        withAnimation(.spring(response: 0.32, dampingFraction: 1)) { model.shapeSize = notchFrame(layout).size }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, generation == self.closeGeneration else { return }
            self.closing = false
            self.model.isOpen = false
            self.reposition()
        }
    }

    /// Esc minimizes the open panel; a waiting request stays waiting (hover
    /// to bring it back). Global monitor for Esc pressed in other apps (listen
    /// -only, needs Accessibility, so the keypress still reaches that app),
    /// local one for Esc while typing in the panel. No event tap.
    private func startEscMonitor() {
        guard escMonitors.isEmpty else { return }
        let isEsc: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard isEsc(e) else { return }
            MainActor.assumeIsolated { self?.minimize() }
        }) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard isEsc(e) else { return e }
            MainActor.assumeIsolated { self?.minimize() }
            return nil
        }) { escMonitors.append(local) }
    }

    private func stopEscMonitor() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
    }

    private func minimize() {
        autoClose?.cancel()
        hovering = false
        setOpen(false)
    }

    /// Click-to-focus: bring the app hosting the agent's session to front.
    private func focusAgent(_ agent: AgentSnapshot) {
        Log.claude.info("focusAgent: tap \(agent.project, privacy: .public) pid=\(agent.hostPID ?? -1)")
        guard let app = resolveApp(pid: agent.hostPID) else {
            Log.claude.info("focusAgent: no live host for \(agent.sessionID, privacy: .public)")
            return
        }
        Log.claude.info("focusAgent: activating \(app.localizedName ?? "?", privacy: .public) pid=\(app.processIdentifier)")
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([], withApplicationAt: url, configuration: cfg)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// The hook captures a CLI subprocess PID, not the registered GUI app.
    /// Walk the parent chain until we find a PID known to NSRunningApplication.
    private func resolveApp(pid startPID: Int?) -> NSRunningApplication? {
        guard let startPID else { return nil }
        let registered = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications.map { (Int($0.processIdentifier), $0) })
        var pid = startPID
        for _ in 0..<12 {
            if let app = registered[pid], !app.isTerminated { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let ppid = Int(info.kp_eproc.e_ppid)
            guard ppid > 1, ppid != pid else { break }
            pid = ppid
        }
        return nil
    }
}

/// Lets the first mouse-down in the non-key notch panel register as a tap
/// rather than just an activation attempt. Without this, onTapGesture inside
/// a canBecomeKey=false NSPanel requires two clicks.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
