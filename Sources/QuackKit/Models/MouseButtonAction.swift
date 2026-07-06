import Foundation

/// What a remapped extra mouse button (4 or 5) does. Raw values are persisted
/// in `QuackSettings` — never change them.
public enum MouseButtonAction: String, CaseIterable, Codable, Sendable {
    case default_ = "default"      // pass through untouched (browser back/forward)
    case missionControl
    case appExpose
    case showDesktop
    case desktopNext
    case desktopPrevious
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
    case customShortcut
    case disabled = "none"         // swallow the click, do nothing

    public static func from(_ raw: String) -> MouseButtonAction {
        MouseButtonAction(rawValue: raw) ?? .default_
    }

    public var title: String {
        switch self {
        case .default_: return "Default (back / forward)"
        case .missionControl: return "Mission Control"
        case .appExpose: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .desktopNext: return "Desktop Next"
        case .desktopPrevious: return "Desktop Previous"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .customShortcut: return "Keyboard Shortcut…"
        case .disabled: return "Do Nothing"
        }
    }
}

/// A recorded keyboard shortcut for `MouseButtonAction.customShortcut`.
/// `modifiers` uses the same bitmask convention as `windowShortcutModifiers`:
/// bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧.
public struct MouseShortcut: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Human-readable form, e.g. "⌘⇧K". Symbol order matches macOS: ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if modifiers & 0b0100 != 0 { s += "⌃" }
        if modifiers & 0b0010 != 0 { s += "⌥" }
        if modifiers & 0b1000 != 0 { s += "⇧" }
        if modifiers & 0b0001 != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Names for common virtual key codes (ANSI layout). Unknown codes render
    /// as "key<code>" — ugly but unambiguous.
    private static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "key\(code)"
    }
}
