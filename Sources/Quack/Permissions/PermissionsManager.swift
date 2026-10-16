import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import Combine
import QuackKit

/// Tracks and requests the macOS permissions Quack needs. Pure status mapping
/// lives in `PermissionStatusMapper` (QuackKit); this type owns the live calls.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    private var accessibilityPollTimer: Timer?

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notRequested
    }

    // MARK: Refresh

    func refreshAll() {
        refreshAccessibility()
        refreshScreenRecording()
    }

    func refreshAccessibility() {
        statuses[.accessibility] = PermissionStatusMapper.accessibility(isTrusted: AXIsProcessTrusted())
    }

    func refreshScreenRecording() {
        // Non-invasive check — does NOT prompt. `CGRequestScreenCaptureAccess`
        // (in `requestScreenRecording`) is the prompting call.
        statuses[.screenRecording] = PermissionStatusMapper.screenRecording(
            hasAccess: CGPreflightScreenCaptureAccess()
        )
    }

    // MARK: Requests

    /// Accessibility cannot be granted programmatically. Prompt the system to
    /// surface its dialog, then poll until the user flips the switch.
    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startAccessibilityPolling()
    }

    /// Triggers the system Screen Recording prompt the first time; subsequently
    /// macOS ignores it (the user must toggle in System Settings), so callers
    /// should fall back to `openSystemSettings(for: .screenRecording)`.
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refreshScreenRecording()
        return granted
    }

    func openSystemSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.refreshAccessibility()
                if self.status(for: .accessibility) == .granted {
                    timer.invalidate()
                    self.accessibilityPollTimer = nil
                }
            }
        }
    }
}
