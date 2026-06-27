import AppKit
import SwiftUI
import Combine
import QuackKit
import CSMC

/// A separate menu-bar status item showing CPU temperature with a flame icon
/// (à la the `hot` app). Reads the SMC via `CSMC`, polls on a background queue,
/// and tints orange/red as the chip heats up. Clicking it opens a popover with
/// thermal pressure, temperature, and a Settings action. Opt-in.
@MainActor
final class TemperatureStatusItem: NSObject, ManagedService {
    private let settings: SettingsStore
    /// Set by AppEnvironment after construction (opens the Settings window).
    var onOpenSettings: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var lastTempC: Double = -1

    private let model = TemperatureModel()
    private let popover = NSPopover()

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "CPU temperature")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: TemperaturePopover(model: model) { [weak self] in self?.openSettings() }
        )

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
        cancellable = nil
        if popover.isShown { popover.performClose(nil) }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
        guard lastTempC > 0 else { button.title = " --"; return }

        let fahrenheit = settings.settings.temperatureFahrenheit
        let value = fahrenheit ? lastTempC * 9 / 5 + 32 : lastTempC
        button.title = " \(Int(value.rounded()))°"
    }
}
