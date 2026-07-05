import Foundation
import EventKit
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
        refreshCalendar()
        refreshAccessibility()
        refreshScreenRecording()
    }

    func refreshCalendar() {
        let raw = Int(EKEventStore.authorizationStatus(for: .event).rawValue)
        statuses[.calendar] = PermissionStatusMapper.calendar(fromEventKitRawValue: raw)
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

    /// Opens System Settings → Privacy & Security → Calendars. Needed when the
    /// system won't re-show the prompt (already shown this session, or denied).
    func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func requestCalendarAccess() async -> Bool {
        // Transient store: a long-lived EKEventStore pins the process's calendar
        // cache, so the running app kept serving stale data (only a relaunch,
        // i.e. a new process, saw edits). No long-lived store anywhere now.
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        refreshCalendar()
        return granted
    }

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
        case .calendar: anchor = "Privacy_Calendars"
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
