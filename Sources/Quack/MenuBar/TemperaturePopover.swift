import SwiftUI
import Foundation

/// Live data for the temperature popover, updated by `TemperatureStatusItem`.
@MainActor
final class TemperatureModel: ObservableObject {
    @Published var tempC: Double = -1
    @Published var fahrenheit = false
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
}

/// The popover shown when the flame menu-bar item is clicked: thermal pressure,
/// temperature, and a Settings action.
struct TemperaturePopover: View {
    @ObservedObject var model: TemperatureModel
    let onSettings: () -> Void
    @State private var hoveringSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(icon: "flame", label: "Thermal Pressure",
                value: pressureText, color: pressureColor)
            row(icon: "thermometer.medium", label: "Temperature",
                value: tempText, color: .primary)

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
        .frame(width: 250, alignment: .leading)
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
