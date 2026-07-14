import Foundation
import IOKit.ps
import Network

/// Current system conditions that can trigger an auto-reveal of the hidden bar.
struct HiddenBarConditions: Equatable {
    var onBattery = false
    var wifiConnected = true
}

/// Watches power source (AC vs battery) and Wi-Fi connectivity, reporting
/// changes on the main actor. Power uses IOKit power-source notifications;
/// Wi-Fi uses `NWPathMonitor` (no Location permission needed).
@MainActor
final class HiddenBarConditionMonitor {
    private(set) var conditions = HiddenBarConditions()
    var onChange: ((HiddenBarConditions) -> Void)?

    private var powerSource: CFRunLoopSource?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.quack.hiddenbar.path")

    func start() {
        // Power: initial read + notification on change.
        updatePower()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<HiddenBarConditionMonitor>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.updatePower() }
        }, ctx)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        // Wi-Fi connectivity.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.updateWifi(connected: wifi) }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func stop() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
        }
        pathMonitor.cancel()
    }

    private func updatePower() {
        let onBattery = Self.isOnBattery()
        guard onBattery != conditions.onBattery else { return }
        conditions.onBattery = onBattery
        onChange?(conditions)
    }

    private func updateWifi(connected: Bool) {
        guard connected != conditions.wifiConnected else { return }
        conditions.wifiConnected = connected
        onChange?(conditions)
    }

    private static func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
        return type == kIOPSBatteryPowerValue
    }
}
