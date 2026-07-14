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
    /// Pinch two fingers in while hovering a window's title bar to close that
    /// window (just the window, not the whole app).
    public var windowPinchCloseEnabled: Bool
    /// Show CPU temperature (with a flame icon) in the menu bar.
    public var cpuTemperatureEnabled: Bool
    /// Dynamic notch media player controls.
    public var notchMediaEnabled: Bool
    /// Show Claude Code agent progress in the notch panel.
    public var notchAgentsEnabled: Bool
    /// Bartender-style hidden menu bar (chevron + collapsing divider).
    public var hiddenBarEnabled: Bool
    /// On displays without a notch (external monitors), show every icon instead
    /// of hiding — the notch isn't crushing anything there.
    public var hiddenBarShowAllOnExternal: Bool
    /// Hide the duck icon from the menu bar.
    public var hideDuckIcon: Bool
    /// Fire a "join now" reminder at the meeting's start time.
    public var remindAtStart: Bool
    /// Show the temperature in Fahrenheit instead of Celsius.
    public var temperatureFahrenheit: Bool

    // MARK: Reminders
    /// Lead times (minutes before start) at which to fire a reminder.
    public var reminderLeadMinutes: [Int]
    /// Sound for advance reminders (20/10/5 min). See NotificationSound.
    public var notificationSound: String
    /// Sound for the join alerts (1-minute + on-time).
    public var joinAlertSound: String

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

    // MARK: Appearance
    /// UI appearance: "system" (follow macOS), "light", or "dark".
    /// See `AppAppearance`.
    public var appearance: String

    // MARK: Mouse
    /// Override the system pointer tracking speed.
    public var mouseSensitivityEnabled: Bool
    /// Pointer speed 0…3 (com.apple.mouse.scaling's practical range).
    public var mouseSensitivity: Double
    /// System scaling captured before Quack first overrode it; restored on
    /// disable / quit. nil = never overridden.
    public var savedSystemMouseScaling: Double?
    /// Animate discrete scroll-wheel ticks into smooth pixel scrolling.
    public var smoothScrollEnabled: Bool
    /// Raw values of `MouseButtonAction` for mouse buttons 4 and 5.
    public var mouseButton4Action: String
    public var mouseButton5Action: String
    /// Recorded combo used when the action is `customShortcut`.
    public var mouseButton4Shortcut: MouseShortcut?
    public var mouseButton5Shortcut: MouseShortcut?

    // MARK: Time awareness
    /// Show the continuous-activity timer in the menu bar.
    public var timeAwarenessEnabled: Bool
    /// Toast reminders to take a break.
    public var restRemindersEnabled: Bool
    /// Remind after this many minutes of continuous activity (N).
    public var activityReminderMinutes: Int
    /// Repeat the reminder every further M minutes while activity continues.
    public var activityRepeatMinutes: Int
    /// Consecutive idle minutes that count as a rest and reset the timer (K).
    public var activityIdleResetMinutes: Int

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
        windowPinchCloseEnabled: Bool = false,
        cpuTemperatureEnabled: Bool = false,
        notchMediaEnabled: Bool = false,
        notchAgentsEnabled: Bool = false,
        hiddenBarEnabled: Bool = false,
        hiddenBarShowAllOnExternal: Bool = true,
        hideDuckIcon: Bool = false,
        remindAtStart: Bool = true,
        temperatureFahrenheit: Bool = false,
        reminderLeadMinutes: [Int] = [10, 5],
        notificationSound: String = "quack",
        joinAlertSound: String = "quack",
        useEventKit: Bool = true,
        useGoogle: Bool = false,
        syncAllCalendars: Bool = true,
        selectedCalendarIDs: [String] = [],
        brightnessStepPercent: Int = 10,
        dimInactiveDisplay: Bool = false,
        displayBrightness: [String: Double] = [:],
        swipeSensitivity: Double = 0.5,
        appearance: String = AppAppearance.system.rawValue,
        mouseSensitivityEnabled: Bool = false,
        mouseSensitivity: Double = 1.0,
        savedSystemMouseScaling: Double? = nil,
        smoothScrollEnabled: Bool = false,
        mouseButton4Action: String = "default",
        mouseButton5Action: String = "default",
        mouseButton4Shortcut: MouseShortcut? = nil,
        mouseButton5Shortcut: MouseShortcut? = nil,
        timeAwarenessEnabled: Bool = false,
        restRemindersEnabled: Bool = true,
        activityReminderMinutes: Int = 50,
        activityRepeatMinutes: Int = 10,
        activityIdleResetMinutes: Int = 5
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
        self.windowPinchCloseEnabled = windowPinchCloseEnabled
        self.cpuTemperatureEnabled = cpuTemperatureEnabled
        self.notchMediaEnabled = notchMediaEnabled
        self.notchAgentsEnabled = notchAgentsEnabled
        self.hiddenBarEnabled = hiddenBarEnabled
        self.hiddenBarShowAllOnExternal = hiddenBarShowAllOnExternal
        self.hideDuckIcon = hideDuckIcon
        self.remindAtStart = remindAtStart
        self.temperatureFahrenheit = temperatureFahrenheit
        self.reminderLeadMinutes = reminderLeadMinutes
        self.notificationSound = notificationSound
        self.joinAlertSound = joinAlertSound
        self.useEventKit = useEventKit
        self.useGoogle = useGoogle
        self.syncAllCalendars = syncAllCalendars
        self.selectedCalendarIDs = selectedCalendarIDs
        self.brightnessStepPercent = brightnessStepPercent
        self.dimInactiveDisplay = dimInactiveDisplay
        self.displayBrightness = displayBrightness
        self.swipeSensitivity = swipeSensitivity
        self.appearance = appearance
        self.mouseSensitivityEnabled = mouseSensitivityEnabled
        self.mouseSensitivity = mouseSensitivity
        self.savedSystemMouseScaling = savedSystemMouseScaling
        self.smoothScrollEnabled = smoothScrollEnabled
        self.mouseButton4Action = mouseButton4Action
        self.mouseButton5Action = mouseButton5Action
        self.mouseButton4Shortcut = mouseButton4Shortcut
        self.mouseButton5Shortcut = mouseButton5Shortcut
        self.timeAwarenessEnabled = timeAwarenessEnabled
        self.restRemindersEnabled = restRemindersEnabled
        self.activityReminderMinutes = activityReminderMinutes
        self.activityRepeatMinutes = activityRepeatMinutes
        self.activityIdleResetMinutes = activityIdleResetMinutes
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
        windowPinchCloseEnabled = v(.windowPinchCloseEnabled, d.windowPinchCloseEnabled)
        cpuTemperatureEnabled = v(.cpuTemperatureEnabled, d.cpuTemperatureEnabled)
        notchMediaEnabled = v(.notchMediaEnabled, d.notchMediaEnabled)
        notchAgentsEnabled = v(.notchAgentsEnabled, d.notchAgentsEnabled)
        hiddenBarEnabled = v(.hiddenBarEnabled, d.hiddenBarEnabled)
        hiddenBarShowAllOnExternal = v(.hiddenBarShowAllOnExternal, d.hiddenBarShowAllOnExternal)
        hideDuckIcon = v(.hideDuckIcon, d.hideDuckIcon)
        remindAtStart = v(.remindAtStart, d.remindAtStart)
        temperatureFahrenheit = v(.temperatureFahrenheit, d.temperatureFahrenheit)
        reminderLeadMinutes = v(.reminderLeadMinutes, d.reminderLeadMinutes)
        notificationSound = v(.notificationSound, d.notificationSound)
        joinAlertSound = v(.joinAlertSound, d.joinAlertSound)
        useEventKit = v(.useEventKit, d.useEventKit)
        useGoogle = v(.useGoogle, d.useGoogle)
        syncAllCalendars = v(.syncAllCalendars, d.syncAllCalendars)
        selectedCalendarIDs = v(.selectedCalendarIDs, d.selectedCalendarIDs)
        brightnessStepPercent = v(.brightnessStepPercent, d.brightnessStepPercent)
        dimInactiveDisplay = v(.dimInactiveDisplay, d.dimInactiveDisplay)
        displayBrightness = v(.displayBrightness, d.displayBrightness)
        swipeSensitivity = v(.swipeSensitivity, d.swipeSensitivity)
        appearance = v(.appearance, d.appearance)
        mouseSensitivityEnabled = v(.mouseSensitivityEnabled, d.mouseSensitivityEnabled)
        mouseSensitivity = v(.mouseSensitivity, d.mouseSensitivity)
        savedSystemMouseScaling = v(.savedSystemMouseScaling, d.savedSystemMouseScaling)
        smoothScrollEnabled = v(.smoothScrollEnabled, d.smoothScrollEnabled)
        mouseButton4Action = v(.mouseButton4Action, d.mouseButton4Action)
        mouseButton5Action = v(.mouseButton5Action, d.mouseButton5Action)
        mouseButton4Shortcut = v(.mouseButton4Shortcut, d.mouseButton4Shortcut)
        mouseButton5Shortcut = v(.mouseButton5Shortcut, d.mouseButton5Shortcut)
        timeAwarenessEnabled = v(.timeAwarenessEnabled, d.timeAwarenessEnabled)
        restRemindersEnabled = v(.restRemindersEnabled, d.restRemindersEnabled)
        activityReminderMinutes = v(.activityReminderMinutes, d.activityReminderMinutes)
        activityRepeatMinutes = v(.activityRepeatMinutes, d.activityRepeatMinutes)
        activityIdleResetMinutes = v(.activityIdleResetMinutes, d.activityIdleResetMinutes)
    }
}
