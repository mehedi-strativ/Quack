import Foundation

/// All persisted user settings and feature flags. Encoded as JSON under a single
/// `UserDefaults` key by `SettingsStore`.
public struct QuackSettings: Codable, Equatable, Sendable {
    // MARK: Feature flags
    public var brightnessEnabled: Bool
    /// Show CPU temperature in the menu bar.
    public var cpuTemperatureEnabled: Bool
    /// Notch panel that expands on hover below the built-in display's notch.
    public var notchEnabled: Bool
    /// Show Claude Code agent progress in the notch panel.
    public var notchAgentsEnabled: Bool
    /// Hide the duck icon from the menu bar.
    public var hideDuckIcon: Bool
    /// Show the temperature in Fahrenheit instead of Celsius.
    public var temperatureFahrenheit: Bool

    // MARK: Brightness
    public var brightnessStepPercent: Int
    public var dimInactiveDisplay: Bool
    /// Per-display target brightness (0...1), keyed by a stable display key.
    public var displayBrightness: [String: Double]

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
        brightnessEnabled: Bool = false,
        cpuTemperatureEnabled: Bool = false,
        notchEnabled: Bool = false,
        notchAgentsEnabled: Bool = false,
        hideDuckIcon: Bool = false,
        temperatureFahrenheit: Bool = false,
        brightnessStepPercent: Int = 10,
        dimInactiveDisplay: Bool = false,
        displayBrightness: [String: Double] = [:],
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
        self.brightnessEnabled = brightnessEnabled
        self.cpuTemperatureEnabled = cpuTemperatureEnabled
        self.notchEnabled = notchEnabled
        self.notchAgentsEnabled = notchAgentsEnabled
        self.hideDuckIcon = hideDuckIcon
        self.temperatureFahrenheit = temperatureFahrenheit
        self.brightnessStepPercent = brightnessStepPercent
        self.dimInactiveDisplay = dimInactiveDisplay
        self.displayBrightness = displayBrightness
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
        brightnessEnabled = v(.brightnessEnabled, d.brightnessEnabled)
        cpuTemperatureEnabled = v(.cpuTemperatureEnabled, d.cpuTemperatureEnabled)
        notchEnabled = v(.notchEnabled, d.notchEnabled)
        notchAgentsEnabled = v(.notchAgentsEnabled, d.notchAgentsEnabled)
        hideDuckIcon = v(.hideDuckIcon, d.hideDuckIcon)
        temperatureFahrenheit = v(.temperatureFahrenheit, d.temperatureFahrenheit)
        brightnessStepPercent = v(.brightnessStepPercent, d.brightnessStepPercent)
        dimInactiveDisplay = v(.dimInactiveDisplay, d.dimInactiveDisplay)
        displayBrightness = v(.displayBrightness, d.displayBrightness)
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
