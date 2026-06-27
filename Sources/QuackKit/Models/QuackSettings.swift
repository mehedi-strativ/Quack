import Foundation

/// All persisted user settings and feature flags. Encoded as JSON under a single
/// `UserDefaults` key by `SettingsStore`.
public struct QuackSettings: Codable, Equatable, Sendable {
    // MARK: Feature flags
    public var calendarEnabled: Bool
    public var remindersEnabled: Bool
    public var menuBarCountdownEnabled: Bool
    public var brightnessEnabled: Bool
    public var windowSwipeEnabled: Bool
    /// Two-finger swipe left/right snaps the window to that half of the screen
    /// (when no monitor lies in that direction).
    public var windowSnapEnabled: Bool
    /// Option+Command+Arrow window management shortcuts.
    public var windowShortcutsEnabled: Bool
    /// Modifier bitmask for the shortcuts: bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧.
    public var windowShortcutModifiers: Int
    /// Pinch two fingers in on an app's Dock icon to quit that app.
    public var dockPinchQuitEnabled: Bool
    /// Show CPU temperature (with a flame icon) in the menu bar.
    public var cpuTemperatureEnabled: Bool
    /// Show the temperature in Fahrenheit instead of Celsius.
    public var temperatureFahrenheit: Bool

    // MARK: Reminders
    /// Lead times (minutes before start) at which to fire a reminder.
    public var reminderLeadMinutes: [Int]
    /// Identifier of the sound played for the "join now" toast (see NotificationSound).
    public var notificationSound: String

    // MARK: Calendar
    public var useEventKit: Bool
    public var useGoogle: Bool
    /// When true, sync every calendar and ignore `selectedCalendarIDs`.
    public var syncAllCalendars: Bool
    /// Explicit calendar selection used when `syncAllCalendars` is false.
    public var selectedCalendarIDs: [String]

    // MARK: Brightness
    public var brightnessStepPercent: Int
    public var dimInactiveDisplay: Bool
    /// Per-display target brightness (0...1), keyed by a stable display key.
    public var displayBrightness: [String: Double]

    // MARK: Window swipe
    /// 0…1; scales the velocity threshold needed to recognize a swipe.
    public var swipeSensitivity: Double

    public init(
        calendarEnabled: Bool = true,
        remindersEnabled: Bool = true,
        menuBarCountdownEnabled: Bool = true,
        brightnessEnabled: Bool = false,
        windowSwipeEnabled: Bool = false,
        windowSnapEnabled: Bool = true,
        windowShortcutsEnabled: Bool = true,
        windowShortcutModifiers: Int = 0b0011,   // ⌘ + ⌥
        dockPinchQuitEnabled: Bool = false,
        cpuTemperatureEnabled: Bool = false,
        temperatureFahrenheit: Bool = false,
        reminderLeadMinutes: [Int] = [10, 5],
        notificationSound: String = "quack",
        useEventKit: Bool = true,
        useGoogle: Bool = false,
        syncAllCalendars: Bool = true,
        selectedCalendarIDs: [String] = [],
        brightnessStepPercent: Int = 10,
        dimInactiveDisplay: Bool = false,
        displayBrightness: [String: Double] = [:],
        swipeSensitivity: Double = 0.5
    ) {
        self.calendarEnabled = calendarEnabled
        self.remindersEnabled = remindersEnabled
        self.menuBarCountdownEnabled = menuBarCountdownEnabled
        self.brightnessEnabled = brightnessEnabled
        self.windowSwipeEnabled = windowSwipeEnabled
        self.windowSnapEnabled = windowSnapEnabled
        self.windowShortcutsEnabled = windowShortcutsEnabled
        self.windowShortcutModifiers = windowShortcutModifiers
        self.dockPinchQuitEnabled = dockPinchQuitEnabled
        self.cpuTemperatureEnabled = cpuTemperatureEnabled
        self.temperatureFahrenheit = temperatureFahrenheit
        self.reminderLeadMinutes = reminderLeadMinutes
        self.notificationSound = notificationSound
        self.useEventKit = useEventKit
        self.useGoogle = useGoogle
        self.syncAllCalendars = syncAllCalendars
        self.selectedCalendarIDs = selectedCalendarIDs
        self.brightnessStepPercent = brightnessStepPercent
        self.dimInactiveDisplay = dimInactiveDisplay
        self.displayBrightness = displayBrightness
        self.swipeSensitivity = swipeSensitivity
    }

    // Custom decoding so that adding a new field never breaks an existing
    // persisted blob: any missing key falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuackSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens decodeIfPresent's `T?` into a single optional.
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) {
                return decoded
            }
            return fallback
        }
        calendarEnabled = v(.calendarEnabled, d.calendarEnabled)
        remindersEnabled = v(.remindersEnabled, d.remindersEnabled)
        menuBarCountdownEnabled = v(.menuBarCountdownEnabled, d.menuBarCountdownEnabled)
        brightnessEnabled = v(.brightnessEnabled, d.brightnessEnabled)
        windowSwipeEnabled = v(.windowSwipeEnabled, d.windowSwipeEnabled)
        windowSnapEnabled = v(.windowSnapEnabled, d.windowSnapEnabled)
        windowShortcutsEnabled = v(.windowShortcutsEnabled, d.windowShortcutsEnabled)
        windowShortcutModifiers = v(.windowShortcutModifiers, d.windowShortcutModifiers)
        dockPinchQuitEnabled = v(.dockPinchQuitEnabled, d.dockPinchQuitEnabled)
        cpuTemperatureEnabled = v(.cpuTemperatureEnabled, d.cpuTemperatureEnabled)
        temperatureFahrenheit = v(.temperatureFahrenheit, d.temperatureFahrenheit)
        reminderLeadMinutes = v(.reminderLeadMinutes, d.reminderLeadMinutes)
        notificationSound = v(.notificationSound, d.notificationSound)
        useEventKit = v(.useEventKit, d.useEventKit)
        useGoogle = v(.useGoogle, d.useGoogle)
        syncAllCalendars = v(.syncAllCalendars, d.syncAllCalendars)
        selectedCalendarIDs = v(.selectedCalendarIDs, d.selectedCalendarIDs)
        brightnessStepPercent = v(.brightnessStepPercent, d.brightnessStepPercent)
        dimInactiveDisplay = v(.dimInactiveDisplay, d.dimInactiveDisplay)
        displayBrightness = v(.displayBrightness, d.displayBrightness)
        swipeSensitivity = v(.swipeSensitivity, d.swipeSensitivity)
    }
}
