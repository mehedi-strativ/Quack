import Foundation

/// The macOS permissions Quack may need, one per feature group. Notifications
/// are deliberately absent: Quack's alerts are its own toast windows, which need
/// no system permission.
public enum PermissionKind: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
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
