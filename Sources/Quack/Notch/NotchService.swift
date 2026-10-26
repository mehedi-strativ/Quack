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
    private var lastLoad: SystemLoad?

    /// Collapsed hover strip height, hanging below the notch. It only carries
    /// the compact status lights; all detail is revealed on hover.
    private let hoverMargin: CGFloat = 8
    private let expandedWidth: CGFloat = 420
    /// Height of the Quack footer row (duck button + padding).
    private let footerRowHeight: CGFloat = 26
    /// System-load row (24) + its top padding (10).
    private let systemRowHeight: CGFloat = 34
    /// One permission card + spacing; at most two are shown without scrolling.
    private let permissionCardHeight: CGFloat = 112

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
        if agentsRunning { agentsService.stop(); agentsRunning = false }
        panel?.orderOut(nil)
        panel = nil
        model.isOpen = false
        model.agents = []
        model.permissions = []
        seenPermissionIDs = []
        hovering = false
    }

    private func wireIfNeeded() {
        guard !wired else { return }
        wired = true
        model.onHoverChange = { [weak self] h in self?.handleHover(h) }
        model.onAgentTap = { [weak self] agent in self?.focusAgent(agent) }
        model.onAnswer = { [weak self] prompt, decision in self?.agentsService.answer(prompt, decision) }
        model.onOpenQuack = { [weak self] in self?.onOpenSettings?() }

        agentsService.$agents
            .sink { [weak self] a in self?.model.agents = a; self?.reposition() }
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
    /// usable). Expanded: a curtain from the very top of the screen — the panel
    /// covers the menu-bar band and the cutout, and `contentTopInset` pushes
    /// the content below the physical camera housing so nothing renders
    /// behind it (CLAUDE.md geometry rule).
    private func reposition() {
        guard let layout = reader.currentLayout(), let panel else { return }
        let notchBottom = layout.cocoaNotchRect.minY
        let notchHeight = layout.cocoaNotchRect.height
        let screenTop = layout.screen.frame.maxY
        let width = model.isOpen ? expandedWidth : max(layout.cocoaNotchRect.width, 120)
        let centerX = layout.cocoaNotchRect.midX
        let originX = centerX - width / 2
        let height: CGFloat
        let originY: CGFloat
        if model.isOpen {
            height = expandedHeight() + notchHeight   // content + the covered cutout band
            originY = screenTop - height              // curtain: top edge at screen top
            model.contentTopInset = notchHeight       // content starts below the cutout
        } else {
            height = hoverMargin
            originY = notchBottom - height            // strip hangs below the notch
            model.contentTopInset = 0
        }
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Expanded height from visible zones.
    private func expandedHeight() -> CGFloat {
        var h: CGFloat = 10                                     // bottom padding
        h += footerRowHeight                                    // Quack footer (duck button)
        h += systemRowHeight
        h += CGFloat(min(model.permissions.count, 2)) * permissionCardHeight
        if model.agentsEnabled {
            h += 30                                             // header row
            if !model.integrationInstalled || model.agents.isEmpty {
                h += 28                                         // CTA / empty row
            } else {
                let visible = min(model.agents.count, 3)
                h += CGFloat(visible) * 100 + CGFloat(visible - 1) * 8
            }
            h += 10                                             // zone bottom pad
        }
        return min(h, 480)
    }

    private func handleHover(_ hovering: Bool) {
        self.hovering = hovering
        setOpen(hovering)
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
            setOpen(true)
        } else if prompts.isEmpty && !hovering && model.isOpen {
            setOpen(false)
        } else {
            reposition()
        }
    }

    private func setOpen(_ open: Bool) {
        model.isOpen = open
        open ? startSampling() : stopSampling()
        reposition()
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
