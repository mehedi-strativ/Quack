import Foundation

/// The macOS permissions Quack may need, one per feature group. Notifications
/// deliberately absent: reminders are Quack's own toast windows, which need no
/// system permission.
public enum PermissionKind: String, CaseIterable, Sendable {
    case calendar
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }
}

/// Normalized permission state across the different system APIs.
public enum PermissionStatus: String, Sendable {
    case notRequested
    case granted
    case denied

    public var isGranted: Bool { self == .granted }
}

/// Maps raw system authorization integer codes to `PermissionStatus`, kept pure
/// so it can be unit tested without touching the real frameworks.
public enum PermissionStatusMapper {

    /// `EKAuthorizationStatus` raw values:
    /// 0 notDetermined, 1 restricted, 2 denied, 3 authorized (full),
    /// 4 writeOnly (macOS 14+), 5 fullAccess (macOS 14+ alias).
    public static func calendar(fromEventKitRawValue raw: Int) -> PermissionStatus {
        switch raw {
        case 3, 5: return .granted
        case 0: return .notRequested
        default: return .denied   // restricted, denied, writeOnly
        }
    }

    /// Accessibility is a simple trusted/not-trusted boolean.
    public static func accessibility(isTrusted: Bool) -> PermissionStatus {
        isTrusted ? .granted : .notRequested
    }

    /// Screen Recording is a simple has-access / not boolean, from
    /// `CGPreflightScreenCaptureAccess()`.
    public static func screenRecording(hasAccess: Bool) -> PermissionStatus {
        hasAccess ? .granted : .notRequested
    }
}
