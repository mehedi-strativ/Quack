import SwiftUI
import AppKit
import Combine
import QuackKit
import CSMC

/// Central composition root. Owns the settings, every live
/// service, and the coordinator that starts/stops services as flags flip.
/// Injected into the SwiftUI environment as a single `ObservableObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    let settingsStore: SettingsStore
    let permissions: PermissionsManager
    let diagnostics = DiagnosticsStatus()

    /// A reliably-ticking clock for time-based UI. The timer lives on the main
    /// run loop in `.common` mode so it keeps firing during menu tracking too.
    @Published var now = Date()
    /// The currently selected settings tab (lifted here so features can deep-link
    /// to a specific tab, e.g. the temperature popover → Display).
    @Published var settingsTab: SettingsTab = .dashboard
    /// Set when a search result is chosen: the section name to spotlight in the
    /// opened pane. Cleared by the pane after the flash.
    @Published var settingsSpotlight: String?
    private var clockTimer: Timer?
    private var activeObserver: NSObjectProtocol?

    let brightnessController: BrightnessController
    private let toasts = ToastPresenter()
    private let settingsWindow = SettingsWindowController()

    private let cursorService: CursorBrightnessService
    private let temperatureService: TemperatureStatusItem
    private let mouseService: MouseService
    private let timeAwarenessService: TimeAwarenessService

    private let coordinator: AppCoordinator
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let settings = SettingsStore()
        let permissions = PermissionsManager()
        let brightness = BrightnessController()

        self.settingsStore = settings
        self.permissions = permissions
        self.brightnessController = brightness

        self.cursorService = CursorBrightnessService(controller: brightness, settings: settings, permissions: permissions, diagnostics: diagnostics)
        self.temperatureService = TemperatureStatusItem(settings: settings)
        self.mouseService = MouseService(settings: settings, permissions: permissions)
        self.timeAwarenessService = TimeAwarenessService(settings: settings, toasts: toasts)

        let services: [Feature: ManagedService] = [
            .brightness: cursorService,
            .temperature: temperatureService,
            .mouse: mouseService,
            .timeAwareness: timeAwarenessService,
        ]
        self.coordinator = AppCoordinator(store: settings, services: services)
        temperatureService.onOpenSettings = { [weak self] in self?.showSettings(selecting: .stats) }
        timeAwarenessService.onOpenSettings = { [weak self] in self?.showSettings(selecting: .stats) }

        // Re-forward nested ObservableObject changes so SwiftUI views observing
        // `AppEnvironment` refresh when settings / permissions change.
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        brightness.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        diagnostics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        mouseService.sensitivity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        timeAwarenessService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        permissions.refreshAll()
        coordinator.activate()

        // Apply the saved appearance app-wide now, and re-apply whenever it
        // changes. Setting `NSApp.appearance` affects the settings window, the
        // dropdown, toasts and the HUD together.
        applyAppearance(settings.settings.appearance)
        settings.$settings
            .map(\.appearance)
            .removeDuplicates()
            .sink { [weak self] in self?.applyAppearance($0) }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            // Fires on the main run loop it's added to.
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer

        // Re-check permissions when returning to the app (e.g. after granting
        // access in System Settings).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.permissions.refreshAll()
            }
        }
    }


    /// Opens (and focuses) the Quack settings window, optionally selecting a tab.
    func showSettings(selecting tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        settingsWindow.show(env: self)
    }

    /// Day statistics for the Dashboard card and the day-by-day view. Today
    /// includes the live session (history is fed every tick in memory).
    func activityStats(for date: Date) -> ActivityHistory.DayStats? {
        timeAwarenessService.history.stats(for: date, calendar: .current)
    }

    func activityTopApps(for date: Date, _ n: Int) -> [ActivityTracker.AppSlice] {
        timeAwarenessService.history.topApps(for: date, calendar: .current, n)
    }

    /// Oldest day with recorded stats (bounds the ‹ chevron), nil if none.
    func activityOldestDay() -> Date? {
        timeAwarenessService.history.oldestDay(calendar: .current)
    }

    /// Reads the current CPU temperature (°C) off the main thread — the first
    /// SMC read enumerates keys, so never do it on the main actor. Returns <= 0
    /// when unsupported or unreadable.
    nonisolated func currentCPUTemperatureC() async -> Double {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: csmc_cpu_temperature())
            }
        }
    }

    /// Maps the stored appearance to an `NSAppearance` and applies it to the
    /// whole app. `.system` clears the override so the app tracks macOS live.
    func applyAppearance(_ raw: String) {
        let appearance: NSAppearance?
        switch AppAppearance.from(raw) {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
    }

    /// Applies a brightness change immediately and persists it.
    func applyBrightness(_ fraction: Double, to display: ControllableDisplay) {
        settingsStore.update { $0.displayBrightness[display.id] = fraction }
        brightnessController.apply(fraction: fraction, to: display)
    }

    /// The pointer-sensitivity unit (settings UI reads `liveApplyAvailable`).
    var mouseSensitivity: MouseSensitivityService { mouseService.sensitivity }
}
