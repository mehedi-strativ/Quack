import QuackKit

/// Every searchable settings control, one entry per control. This is the
/// search index AND the de-facto accessibility inventory: if a control isn't
/// listed here, it can't be found from the sidebar search.
enum SettingsSearchRegistry {
    static func entry(_ id: String, _ title: String, _ tab: SettingsTab,
                      _ section: String, _ keywords: [String] = []) -> SettingEntry {
        SettingEntry(id: id, title: title, tabID: tab.rawValue, section: section, keywords: keywords)
    }

    static let all: [SettingEntry] = [
        // Meetings
        entry("meetings.countdown", "Show meeting countdown in the menu bar", .meetings, "Calendar",
              ["timer", "next meeting", "menu bar"]),
        entry("meetings.accounts", "Calendar accounts & selection", .meetings, "Calendar",
              ["google", "icloud", "eventkit", "sync", "select calendars"]),
        entry("meetings.reminders", "Meeting reminders", .meetings, "Reminders",
              ["notification", "alert", "lead time", "before meeting"]),
        entry("meetings.sound", "Reminder & join sounds", .meetings, "Sound",
              ["quack", "audio", "notification sound", "chime"]),
        entry("meetings.remindAtStart", "Remind on time (join now)", .meetings, "Reminders",
              ["start", "join", "on time"]),

        // Hidden icons
        entry("hiddenbar.enable", "Hidden menu bar", .hiddenIcons, "Hidden menu bar",
              ["bartender", "chevron", "hide icons", "collapse", "declutter"]),
        entry("hiddenbar.battery", "Reveal the Battery icon while on battery", .hiddenIcons, "Hidden menu bar",
              ["power", "unplugged", "auto reveal"]),
        entry("hiddenbar.wifi", "Reveal the Wi-Fi icon while Wi-Fi is off", .hiddenIcons, "Hidden menu bar",
              ["wireless", "network", "disconnected", "auto reveal"]),

        // Stats & timer
        entry("stats.cpu", "Show CPU temperature in the menu bar", .stats, "CPU temperature",
              ["heat", "thermal", "degrees", "flame"]),
        entry("stats.fahrenheit", "Show in Fahrenheit", .stats, "CPU temperature",
              ["celsius", "units", "degrees"]),
        entry("stats.activityTimer", "Show an activity timer in the menu bar", .stats, "Time awareness",
              ["work timer", "continuous", "usage"]),
        entry("stats.restReminders", "Remind me to take breaks", .stats, "Rest reminders",
              ["break", "rest", "pomodoro", "stand up", "health"]),
        entry("stats.statistics", "Activity statistics", .stats, "Statistics",
              ["daily", "history", "top apps", "screen time"]),

        // Mouse
        entry("mouse.tracking", "Override tracking speed", .mouse, "Pointer",
              ["cursor", "sensitivity", "speed", "pointer"]),
        entry("mouse.smoothScroll", "Smooth scrolling", .mouse, "Scrolling",
              ["wheel", "animate", "tick", "momentum"]),
        entry("mouse.buttons", "Extra buttons (4 / 5) actions", .mouse, "Extra buttons",
              ["side buttons", "back", "forward", "custom shortcut", "rebind"]),

        // Gestures
        entry("gestures.swipe", "Two-finger swipe on the title bar", .gestures, "Window swipe",
              ["trackpad", "move window", "throw", "flick", "snap half"]),
        entry("gestures.swipeSensitivity", "Swipe sensitivity", .gestures, "Window swipe",
              ["speed", "threshold", "velocity"]),
        entry("gestures.dockPinch", "Pinch a Dock icon to quit the app", .gestures, "Pinch gestures",
              ["quit", "close app", "trackpad"]),
        entry("gestures.windowPinch", "Pinch a window's title bar to close it", .gestures, "Pinch gestures",
              ["close window", "trackpad"]),

        // Shortcuts
        entry("shortcuts.windows", "Window management shortcuts", .shortcuts, "Keyboard shortcuts",
              ["command option arrow", "snap", "halves", "maximize", "hotkey", "keybinding"]),
        entry("shortcuts.modifiers", "Shortcut modifier keys", .shortcuts, "Keyboard shortcuts",
              ["command", "option", "control", "shift", "customize"]),

        // Brightness
        entry("brightness.f1f2", "Control external brightness with F1 / F2", .brightness, "External-display brightness",
              ["monitor", "ddc", "display", "function keys", "dim"]),
        entry("brightness.step", "Brightness step", .brightness, "External-display brightness",
              ["increment", "percent"]),
        entry("brightness.dimInactive", "Dim the inactive display", .brightness, "External-display brightness",
              ["focus", "other monitor", "darken"]),

        // Notch
        entry("notch.media", "Show the media player in the notch", .notch, "Notch panel",
              ["now playing", "music", "spotify", "controls", "dynamic island"]),
        entry("notch.agents", "Show Claude Code agents in the notch", .notch, "Notch panel",
              ["ai", "progress", "tasks"]),

        // General
        entry("general.launchAtLogin", "Launch Quack at login", .general, "General",
              ["startup", "autostart", "boot"]),
        entry("general.hideDuck", "Hide the duck icon from the menu bar", .general, "General",
              ["icon", "duck", "declutter"]),
        entry("general.appearance", "Theme (Light / Dark / System)", .general, "Appearance",
              ["dark mode", "light mode", "appearance"]),

        // Permissions
        entry("permissions.list", "Permissions", .permissions, "Permissions",
              ["accessibility", "screen recording", "calendar access", "privacy", "grant", "tcc"]),
        entry("permissions.status", "Diagnostics & status", .permissions, "Status",
              ["health", "debug", "version"]),
    ]
}
