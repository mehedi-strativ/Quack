import AppKit
import CoreGraphics
import QuackKit

/// Executes a remapped mouse-button action. Always called on the main actor
/// (dispatched from the tap thread) — never on the tap thread itself.
@MainActor
enum MouseActionPerformer {
    static func perform(_ action: MouseButtonAction, shortcut: MouseShortcut?) {
        switch action {
        case .default_, .disabled:
            break   // default never reaches here; disabled = swallow silently
        case .missionControl:
            postKeystroke(keyCode: 126, flags: .maskControl)          // ⌃↑
        case .appExpose:
            postKeystroke(keyCode: 125, flags: .maskControl)          // ⌃↓
        case .showDesktop:
            postKeystroke(keyCode: 103, flags: [])                    // F11 (default binding)
        case .playPause:
            postMediaKey(16)    // NX_KEYTYPE_PLAY
        case .nextTrack:
            postMediaKey(17)    // NX_KEYTYPE_NEXT
        case .previousTrack:
            postMediaKey(18)    // NX_KEYTYPE_PREVIOUS
        case .volumeUp:
            postMediaKey(0)     // NX_KEYTYPE_SOUND_UP
        case .volumeDown:
            postMediaKey(1)     // NX_KEYTYPE_SOUND_DOWN
        case .mute:
            postMediaKey(7)     // NX_KEYTYPE_MUTE
        case .customShortcut:
            guard let shortcut else { return }
            postKeystroke(keyCode: CGKeyCode(clamping: shortcut.keyCode),
                          flags: Self.flags(from: shortcut.modifiers))
        }
    }

    /// Synthesizes a full keyDown+keyUp pair with modifiers.
    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Synthesizes an NX_SYSDEFINED media-key press pair (subtype 8) — the
    /// same mechanism the keyboard's media keys use, so it reaches whichever
    /// app owns Now Playing (Music, Spotify, browsers…).
    private static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0x0a : 0x0b
            let data1 = Int((key << 16) | (state << 8))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Same bitmask convention as `windowShortcutModifiers` / `MouseShortcut`:
    /// bit0 ⌘, bit1 ⌥, bit2 ⌃, bit3 ⇧.
    private static func flags(from mask: Int) -> CGEventFlags {
        var flags = CGEventFlags()
        if mask & 0b0001 != 0 { flags.insert(.maskCommand) }
        if mask & 0b0010 != 0 { flags.insert(.maskAlternate) }
        if mask & 0b0100 != 0 { flags.insert(.maskControl) }
        if mask & 0b1000 != 0 { flags.insert(.maskShift) }
        return flags
    }
}
