import SwiftUI
import AppKit
import QuackKit

/// Live data for the temperature popover, updated by `TemperatureStatusItem`.
@MainActor
final class TemperatureModel: ObservableObject {
    @Published var tempC: Double = -1
    @Published var fahrenheit = false
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    /// Machine-wide load, 0–100; nil until measured (CPU needs two samples).
    @Published var cpuPercent: Double?
    @Published var gpuPercent: Double?
    @Published var memoryPercent: Double?
    /// Per-app usage over the last sampling interval; empty until measured.
    @Published var topApps: [AppUsage] = []
    @Published var sortKey: ProcessSortKey = .cpu
}

/// What the "Using the most" list ranks by. CPU first: CPU and GPU work is
/// what heats the chip; memory barely does.
enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", power = "Power", memory = "Memory"
    var id: Self { self }

    func value(_ a: AppUsage) -> Double {
        switch self {
        case .cpu: return a.cpuPercent
        case .gpu: return a.gpuPercent
        case .power: return a.watts
        case .memory: return Double(a.memoryBytes)
        }
    }

    func text(_ a: AppUsage) -> String {
        switch self {
        case .cpu: return "\(Int(a.cpuPercent.rounded()))%"
        case .gpu: return "\(Int(a.gpuPercent.rounded()))%"
        case .power: return String(format: "%.1f W", a.watts)
        case .memory: return ByteCountFormatter.string(fromByteCount: Int64(a.memoryBytes), countStyle: .memory)
        }
    }
}

/// The popover shown when the temperature menu-bar item is clicked: thermal pressure,
/// temperature, the apps working the chip hardest (with Quit), and Settings.
struct TemperaturePopover: View {
    @ObservedObject var model: TemperatureModel
    let onSettings: () -> Void
    /// Quits an app; `force` when ⌥ was held.
    let onQuit: (AppUsage, _ force: Bool) -> Void
    @State private var hoveringSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(icon: "flame", label: "Thermal Pressure",
                value: pressureText, color: pressureColor)
            row(icon: "thermometer.medium", label: "Temperature",
                value: tempText, color: .primary)
            row(icon: "cpu", label: "CPU",
                value: percentText(model.cpuPercent), color: loadColor(model.cpuPercent))
            row(icon: "square.3.layers.3d", label: "GPU",
                value: percentText(model.gpuPercent), color: loadColor(model.gpuPercent))
            row(icon: "memorychip", label: "Memory",
                value: percentText(model.memoryPercent), color: loadColor(model.memoryPercent))

            Divider()

            topAppsSection

            Divider()

            Button(action: onSettings) {
                HStack {
                    Image(systemName: "gearshape")
                    Text("Settings…")
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(hoveringSettings ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .instantHover($hoveringSettings)
            .padding(.horizontal, -6)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder private var topAppsSection: some View {
        HStack {
            Text("Using the most").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
        Picker("Sort by", selection: $model.sortKey) {
            ForEach(ProcessSortKey.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()

        if model.topApps.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            VStack(spacing: 2) {
                ForEach(ranked) { app in
                    ProcessRow(app: app, value: model.sortKey.text(app), onQuit: onQuit)
                }
            }
            .padding(.horizontal, -6)
        }
    }

    private var ranked: [AppUsage] {
        let key = model.sortKey
        return Array(model.topApps.sorted { key.value($0) > key.value($1) }.prefix(5))
    }

    private func row(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).foregroundStyle(color)
        }
        .font(.system(size: 13))
    }

    private var tempText: String {
        guard model.tempC > 0 else { return "—" }
        let v = model.fahrenheit ? model.tempC * 9 / 5 + 32 : model.tempC
        return "\(Int(v.rounded()))°\(model.fahrenheit ? "F" : "C")"
    }

    private func percentText(_ p: Double?) -> String {
        p.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func loadColor(_ p: Double?) -> Color {
        guard let p else { return .primary }
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .primary
    }

    private var pressureText: String {
        switch model.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var pressureColor: Color {
        switch model.thermalState {
        case .nominal: return .primary
        case .fair: return .orange
        case .serious, .critical: return .red
        @unknown default: return .primary
        }
    }
}

/// One app in the "Using the most" list. Hover reveals Quit; macOS's own
/// processes get an Apple icon instead and can't be quit.
private struct ProcessRow: View {
    let app: AppUsage
    let value: String
    let onQuit: (AppUsage, _ force: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            Text(app.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering && !app.isSystem {
                Button("Quit") { onQuit(app, NSEvent.modifierFlags.contains(.option)) }
                    .controlSize(.small)
                    .help("Quit \(app.name). Hold ⌥ to force quit.")
            }
            Text(value).monospacedDigit().fontWeight(.semibold)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(hovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .instantHover($hovering)
        .help(app.isSystem
              ? "Part of macOS (“\(app.processName)”), so it can't be quit here."
              : app.processName)
    }

    @ViewBuilder private var icon: some View {
        if app.isSystem {
            Image(systemName: "apple.logo").foregroundStyle(.secondary)
        } else if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }
}
