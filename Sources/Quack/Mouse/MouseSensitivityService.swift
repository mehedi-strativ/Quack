// Sources/Quack/Mouse/MouseSensitivityService.swift
import AppKit
import Foundation
import Combine
import QuackKit

/// Overrides the system pointer tracking speed. No event tap.
///
/// Two-part apply (the LinearMouse approach):
///  1. Persist `com.apple.mouse.scaling` in the global prefs domain so System
///     Settings stays in sync and the value survives reboot/replug.
///  2. Push `HIDMouseAcceleration` (fixed-point, ×65536) into the HID event
///     system via the private `IOHIDEventSystemClient` API so the change
///     applies instantly.
///
/// If the private API is unavailable (symbols missing / client rejected), the
/// prefs write still happens and `liveApplyAvailable` turns false — the UI
/// shows a "takes effect after replug/login" caption.
@MainActor
final class MouseSensitivityService: ObservableObject {
    /// False when the private HID client couldn't be used (prefs-only mode).
    @Published private(set) var liveApplyAvailable = true

    private let settings: SettingsStore
    private var cancellable: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?
    private var started = false

    // MARK: private HID API (dlsym'd — no headers for these)
    private typealias CreateSimpleClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetProperty = @convention(c) (AnyObject, CFString, CFTypeRef) -> Int32
    private let hidClient: AnyObject?
    private let hidSetProperty: SetProperty?

    init(settings: SettingsStore) {
        self.settings = settings
        // Resolve the private symbols once. IOKit is already linked; use
        // RTLD_DEFAULT-style lookup via dlopen(nil).
        let handle = dlopen(nil, RTLD_NOW)
        if let createSym = dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient"),
           let setSym = dlsym(handle, "IOHIDEventSystemClientSetProperty") {
            let create = unsafeBitCast(createSym, to: CreateSimpleClient.self)
            hidSetProperty = unsafeBitCast(setSym, to: SetProperty.self)
            hidClient = create(kCFAllocatorDefault)?.takeRetainedValue()
        } else {
            hidClient = nil
            hidSetProperty = nil
        }
    }

    func start() {
        guard !started else { return }
        started = true

        if settings.settings.mouseSensitivityEnabled { apply() }

        // Debounced live apply on slider / toggle changes.
        cancellable = settings.$settings
            .map { (enabled: $0.mouseSensitivityEnabled, value: $0.mouseSensitivity) }
            .removeDuplicates(by: ==)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                if state.enabled { self?.apply() } else { self?.restore() }
            }

        // Quitting with an override active must not leave the Mac stuck on
        // Quack's value.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.settings.mouseSensitivityEnabled else { return }
                self.restore()
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        cancellable = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        restore()
    }

    // MARK: apply / restore

    private func apply() {
        // Capture the pre-Quack system value once, so disable can restore it.
        if settings.settings.savedSystemMouseScaling == nil {
            let current = Self.readSystemScaling() ?? 0.6875   // macOS default (mid slider)
            settings.update { $0.savedSystemMouseScaling = current }
        }
        setScaling(settings.settings.mouseSensitivity)
    }

    private func restore() {
        guard let saved = settings.settings.savedSystemMouseScaling else { return }
        setScaling(saved)
        settings.update { $0.savedSystemMouseScaling = nil }
    }

    private func setScaling(_ value: Double) {
        // 1. Persist for System Settings + reboot.
        CFPreferencesSetValue("com.apple.mouse.scaling" as CFString,
                              NSNumber(value: value),
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
        // 2. Live apply through the HID event system.
        if let client = hidClient, let setProp = hidSetProperty {
            let fixed = NSNumber(value: Int(value * 65536))
            let result = setProp(client, "HIDMouseAcceleration" as CFString, fixed)
            if result != 0 {
                if !liveApplyAvailable { liveApplyAvailable = true }
            } else {
                liveApplyAvailable = false
                Log.mouse.error("HID live apply rejected by client — wrote prefs only (takes effect after replug/login)")
            }
        } else {
            liveApplyAvailable = false
            Log.mouse.error("HID live apply unavailable — wrote prefs only (takes effect after replug/login)")
        }
        Log.mouse.log("Pointer scaling set to \(value, privacy: .public)")
    }

    private static func readSystemScaling() -> Double? {
        let v = CFPreferencesCopyValue("com.apple.mouse.scaling" as CFString,
                                       kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost)
        return (v as? NSNumber)?.doubleValue
    }
}
