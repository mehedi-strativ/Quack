import AppKit
import SwiftUI
import Combine
import QuackKit
import CSMC

/// A separate menu-bar status item showing CPU temperature as text
/// (à la the `hot` app). Reads the SMC via `CSMC`, polls on a background
/// queue. Clicking it opens a popover with
/// thermal pressure, temperature, the apps using the most CPU/GPU/memory (with
/// Quit), and a Settings action. Opt-in.
@MainActor
final class TemperatureStatusItem: NSObject, ManagedService, NSPopoverDelegate {
    private let settings: SettingsStore
    /// Set by AppEnvironment after construction (opens the Settings window).
    var onOpenSettings: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var lastTempC: Double = -1
    /// Samples processes only while the popover is open.
    private var processTimer: Timer?
    private var lastSample: (samples: [ProcessSample], load: SystemLoad, at: Date)?

    private let model = TemperatureModel()
    private let popover = NSPopover()

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func start() {
        // Create the status item once and reuse it. Toggling the feature flips
        // `isVisible` instead of removing/re-adding the item — repeatedly
        // removing and recreating status items corrupts the menu-bar layout and
        // can drop *other* apps'/our own items (that's what made the duck vanish).
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "quack.temperature"
            if let button = item.button {
                button.setAccessibilityLabel("CPU temperature")
                button.target = self
                button.action = #selector(togglePopover)
            }
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = NSHostingController(
                rootView: TemperaturePopover(
                    model: model,
                    onSettings: { [weak self] in self?.openSettings() },
                    onQuit: { [weak self] app, force in self?.quit(app, force: force) }
                )
            )
            statusItem = item
        }
        statusItem?.isVisible = true

        // Re-render immediately when the unit toggle changes.
        cancellable = settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }

        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stopProcessSampling()
        cancellable = nil
        if popover.isShown { popover.performClose(nil) }
        statusItem?.isVisible = false
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            startProcessSampling()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { stopProcessSampling() }
    }

    // MARK: Top processes

    private func startProcessSampling() {
        stopProcessSampling()
        model.topApps = []
        model.cpuPercent = nil
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleProcesses() }
        }
        RunLoop.main.add(timer, forMode: .common)
        processTimer = timer
        sampleProcesses()   // baseline; the first rates land on the next tick
    }

    private func stopProcessSampling() {
        processTimer?.invalidate(); processTimer = nil
        lastSample = nil
    }

    /// Walks every process and reads machine-wide load off the main thread,
    /// then diffs against the previous walk to get rates.
    private func sampleProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let samples = ProcessSampler.sample()
            let load = ProcessSampler.systemLoad()
            let now = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.processTimer != nil else { return }   // closed meanwhile
                if let prev = self.lastSample {
                    self.model.topApps = ProcessUsage.aggregate(
                        previous: prev.samples, current: samples,
                        interval: now.timeIntervalSince(prev.at))
                    let total = load.cpuTotalTicks &- prev.load.cpuTotalTicks
                    if total > 0 {
                        self.model.cpuPercent = Double(load.cpuBusyTicks &- prev.load.cpuBusyTicks) / Double(total) * 100
                    }
                }
                self.model.gpuPercent = load.gpuPercent
                self.model.memoryPercent = load.memoryPercent
                self.lastSample = (samples, load, now)
            }
        }
    }

    /// Quits a regular app the polite way (it may ask to save); a bare process
    /// or a bundle with no running app gets SIGTERM. `force` = ⌥-click.
    private func quit(_ app: AppUsage, force: Bool) {
        guard !app.isSystem else { return }
        let running = app.pids.lazy
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.bundleURL?.path == app.bundlePath }
        if let running {
            _ = force ? running.forceTerminate() : running.terminate()
        } else {
            for pid in app.pids { kill(pid, force ? SIGKILL : SIGTERM) }
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        onOpenSettings?()
    }

    /// Reads the SMC off the main thread (the first read enumerates keys), then
    /// updates the button on the main actor.
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let c = csmc_cpu_temperature()
            DispatchQueue.main.async { [weak self] in
                self?.lastTempC = c
                self?.render()
            }
        }
    }

    private func render() {
        // Keep the popover model in sync.
        model.tempC = lastTempC
        model.fahrenheit = settings.settings.temperatureFahrenheit
        model.thermalState = ProcessInfo.processInfo.thermalState

        guard let button = statusItem?.button else { return }
        // Always use the default adaptive menu-bar color (a fixed attributed
        // color flickered between tinted and black/white against the menu bar).
        button.contentTintColor = nil
        if lastTempC > 0 {
            let fahrenheit = settings.settings.temperatureFahrenheit
            let value = fahrenheit ? lastTempC * 9 / 5 + 32 : lastTempC
            button.title = "\(Int(value.rounded()))°"
        } else {
            button.title = "--"
        }
        tightenWidth(button)
    }

    /// `variableLength` adds generous system side-insets. Pin the item to the
    /// text width with only a little side padding.
    private func tightenWidth(_ button: NSStatusBarButton) {
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (button.title as NSString).size(withAttributes: [.font: font]).width
        statusItem?.length = ceil(textWidth + 4)
    }
}
