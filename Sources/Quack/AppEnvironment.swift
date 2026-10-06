import SwiftUI
import AppKit
import Combine
import QuackKit
import CSMC

/// Central composition root. Owns the settings, the meeting store, every live
/// service, and the coordinator that starts/stops services as flags flip.
/// Injected into the SwiftUI environment as a single `ObservableObject`.
@MainActor
final class AppEnvironment: ObservableObject {
    let settingsStore: SettingsStore
    let permissions: PermissionsManager
    let meetingStore: MeetingStore
    let diagnostics = DiagnosticsStatus()

    /// A reliably-ticking clock that drives the menu-bar countdown. A
    /// `Timer.publish` placed inside a `MenuBarExtra` label does not fire
    /// dependably, which froze the countdown; this timer lives on the main
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

    private let eventKitProvider: EventKitProvider
    private let googleOAuth: GoogleOAuthService
    private let googleCalendarProvider: GoogleCalendarProvider
    private let composite: CompositeCalendarProvider
    let brightnessController: BrightnessController
    private let toasts = ToastPresenter()
    private let quackSound = QuackSound()
    private let settingsWindow = SettingsWindowController()

    private let calendarService: CalendarRefreshService
    private let reminderScheduler: ReminderScheduler
    private let cursorService: CursorBrightnessService
    private let gestureService: GestureMonitor
    private let hotkeyService: HotkeyMonitor
    private let dockPinchService: DockPinchMonitor
    private let temperatureService: TemperatureStatusItem
    let menuBarOverflow: MenuBarOverflowService
    private let notchService: NotchService
    private let mouseService: MouseService
    private let timeAwarenessService: TimeAwarenessService
    let claudeInstaller = ClaudeConfigInstaller()
    let opencodeInstaller = OpencodeConfigInstaller()

    private let coordinator: AppCoordinator
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let settings = SettingsStore()
        // Calendar is always on now (its toggle was removed); it powers the
        // countdown, reminders, and the dropdown list.
        settings.update { $0.calendarEnabled = true }
        let permissions = PermissionsManager()
        let eventKitProvider = EventKitProvider(permissions: permissions)
        let googleOAuth = GoogleOAuthService(
            clientID: "783466472013-itdojrdr933jt0s0g1s47qb24g1ibnim.apps.googleusercontent.com",
            clientSecret: "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"
        )
        let googleCalendarProvider = GoogleCalendarProvider(
            oauth: googleOAuth,
            enabled: { settings.settings.useGoogle },
            calendarIDs: {
                settings.settings.syncAllCalendars ? [] : settings.settings.selectedGoogleCalendarIDs
            }
        )
        let composite = CompositeCalendarProvider(
            providers: [googleCalendarProvider]
        )
        let store = MeetingStore(
            provider: composite,
            calendarIDs: {
                settings.settings.syncAllCalendars ? [] : settings.settings.selectedGoogleCalendarIDs
            }
        )
        let brightness = BrightnessController()

        self.settingsStore = settings
        self.permissions = permissions
        self.eventKitProvider = eventKitProvider
        self.googleOAuth = googleOAuth
        self.googleCalendarProvider = googleCalendarProvider
        self.composite = composite
        self.meetingStore = store
        self.brightnessController = brightness

        self.menuBarOverflow = MenuBarOverflowService()
        self.calendarService = CalendarRefreshService(store: store, permissions: permissions)
        self.reminderScheduler = ReminderScheduler(store: store, settings: settings, toasts: toasts, sound: quackSound)
        self.cursorService = CursorBrightnessService(controller: brightness, settings: settings, permissions: permissions, diagnostics: diagnostics)
        self.gestureService = GestureMonitor(settings: settings, permissions: permissions, diagnostics: diagnostics)
        self.hotkeyService = HotkeyMonitor(settings: settings, permissions: permissions)
        self.dockPinchService = DockPinchMonitor(settings: settings, permissions: permissions, diagnostics: diagnostics)
        self.temperatureService = TemperatureStatusItem(settings: settings, overflow: menuBarOverflow)
        self.notchService = NotchService(settings: settings, permissions: permissions,
                                          claudeInstaller: claudeInstaller, opencodeInstaller: opencodeInstaller,
                                          overflow: menuBarOverflow)
        self.mouseService = MouseService(settings: settings, permissions: permissions)
        self.timeAwarenessService = TimeAwarenessService(settings: settings, toasts: toasts,
                                                         overflow: menuBarOverflow)

        let services: [Feature: ManagedService] = [
            .calendar: calendarService,
            .reminders: reminderScheduler,
            .menuBarCountdown: NullService(),   // title is driven reactively; no side effects
            .brightness: cursorService,
            .windowSwipe: gestureService,
            .windowShortcuts: hotkeyService,
            .dockPinch: dockPinchService,
            .temperature: temperatureService,
            .mouse: mouseService,
            .timeAwareness: timeAwarenessService,
        ]
        self.coordinator = AppCoordinator(store: settings, services: services)
        temperatureService.onOpenSettings = { [weak self] in self?.showSettings(selecting: .stats) }
        timeAwarenessService.onOpenSettings = { [weak self] in self?.showSettings(selecting: .stats) }
        notchService.onOpenSettings = { [weak self] in self?.showSettings() }

        // Re-forward nested ObservableObject changes so SwiftUI views observing
        // `AppEnvironment` refresh when settings / meetings / permissions change.
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        brightness.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        diagnostics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        mouseService.sensitivity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        timeAwarenessService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        permissions.refreshAll()
        coordinator.activate()
        // The notch panel is also the host for the always-available overflow
        // rail, so its shell must run even when media/agent zones are disabled.
        menuBarOverflow.start()
        notchService.start()

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

        // Re-check permissions and reload the calendar when returning to the app
        // (e.g. after granting access in System Settings).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.permissions.refreshAll()
                self?.refreshCalendarNow()
            }
        }
    }


    /// Plays a sound for the settings preview button.
    func previewSound(_ sound: NotificationSound) {
        quackSound.play(sound)
    }

    /// Shows a sample "join now" toast so the user can confirm reminders appear
    /// (independent of whether a real meeting is currently due).
    func previewToast() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        toasts.show(ToastItem(
            title: "Preview meeting",
            relativeText: "now",
            timeRange: "\(f.string(from: now)) – \(f.string(from: now.addingTimeInterval(1800)))",
            colorHex: nil,
            joinURL: url,
            provider: MeetingProvider(url: url),
            joinable: true,
            isStart: true
        ), dismissAfter: nil)   // mirror the real join-now toast: stays until dismissed
        quackSound.play(NotificationSound.from(settingsStore.settings.joinAlertSound))
    }

    /// Shows a sample advance-reminder toast (plain notification, no Join button,
    /// auto-dismiss) — what the 20/10/5-minute reminders look like.
    func previewReminderToast() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        toasts.show(ToastItem(
            title: "Preview meeting",
            relativeText: "in 10 min",
            timeRange: "\(f.string(from: now.addingTimeInterval(600))) – \(f.string(from: now.addingTimeInterval(2400)))",
            colorHex: nil,
            joinURL: url,
            provider: MeetingProvider(url: url),
            joinable: false,
            isStart: false
        ), dismissAfter: 6)
        quackSound.play(NotificationSound.from(settingsStore.settings.notificationSound))
    }

    /// Re-reads the calendar now (e.g. when the menu opens) so the list is never
    /// showing stale/empty data.
    func refreshCalendarNow() {
        guard settingsStore.settings.calendarEnabled else { return }
        Task { @MainActor in
            await meetingStore.refresh()
            // The fetch above also asks macOS to sync remote sources, which is
            // async — so fetch again a few seconds later to pick up an edit that
            // had just synced from the cloud (Google/iCloud).
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await meetingStore.refresh()
        }
    }

    /// Opens (and focuses) the Quack settings window, optionally selecting a tab.
    func showSettings(selecting tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        settingsWindow.show(env: self)
    }

    /// Fetches every event overlapping `window` for the agenda view, honoring the
    /// user's calendar selection. Returns them sorted by start time with
    /// conferencing links resolved. Empty on no access/error.
    func events(in window: DateInterval) async -> [MeetingEvent] {
        let fetched = (try? await composite.fetchEvents(window: window)) ?? []
        let s = settingsStore.settings
        let ids = s.syncAllCalendars ? [] : s.selectedGoogleCalendarIDs
        return MeetingSelection.filter(fetched, window: window, calendarIDs: ids)
            .map { $0.withConferencingURL(MeetingURLParser.joinURL(for: $0)) }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Google Calendar

    var isGoogleAuthenticated: Bool {
        get async { await googleOAuth.isAuthenticated }
    }

    func signInToGoogle() async throws {
        try await googleOAuth.authenticate()
        settingsStore.update { $0.useGoogle = true }
    }

    func signOutFromGoogle() async {
        let googleIDs = Set(await googleCalendarProvider.availableCalendars().map(\.id))
        await googleOAuth.signOut()
        settingsStore.update {
            $0.useGoogle = false
            $0.selectedGoogleCalendarIDs.removeAll { googleIDs.contains($0) }
        }
    }

    func availableGoogleCalendars() async -> [GoogleCalendarInfo] {
        await googleCalendarProvider.availableCalendars()
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

    /// Claude Code integration state/actions for the settings pane. Returns
    /// success; failures are logged, never fatal (the panel degrades quietly).
    func claudeIntegrationInstalled() -> Bool {
        claudeInstaller.isInstalled()
    }

    @discardableResult
    func installClaudeIntegration() -> Bool {
        do { try claudeInstaller.install(); return true }
        catch { Log.claude.error("Claude integration install failed: \(error.localizedDescription)"); return false }
    }

    @discardableResult
    func removeClaudeIntegration() -> Bool {
        do { try claudeInstaller.uninstall(); return true }
        catch { Log.claude.error("Claude integration uninstall failed: \(error.localizedDescription)"); return false }
    }

    /// opencode integration state/actions for the settings pane. Mirrors the
    /// Claude Code trio above; failures are logged, never fatal.
    func opencodeIntegrationInstalled() -> Bool {
        opencodeInstaller.isInstalled()
    }

    @discardableResult
    func installOpencodeIntegration() -> Bool {
        do { try opencodeInstaller.install(); return true }
        catch { Log.opencode.error("opencode integration install failed: \(error.localizedDescription)"); return false }
    }

    @discardableResult
    func removeOpencodeIntegration() -> Bool {
        do { try opencodeInstaller.uninstall(); return true }
        catch { Log.opencode.error("opencode integration uninstall failed: \(error.localizedDescription)"); return false }
    }
}

/// A no-op service used for features that are purely reactive (the menu-bar
/// countdown is rendered from `MeetingStore`, so it needs no lifecycle).
@MainActor
private final class NullService: ManagedService {
    func start() {}
    func stop() {}
}
