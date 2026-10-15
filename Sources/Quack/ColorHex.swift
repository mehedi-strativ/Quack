import SwiftUI

extension Color {
    /// Quack's brand accent — a warm duck yellow.
    static let quackYellow = Color(red: 1.0, green: 0.78, blue: 0.05)   // ~#FFC70D
    static let quackOrange = Color(red: 0.96, green: 0.49, blue: 0.13)
    static let quackPink = Color(red: 1.0, green: 0.24, blue: 0.50)     // ~#FF3D7F
}

extension LinearGradient {
    /// The "sunrise" brand gradient (yellow → orange → pink) for hero surfaces.
    static let quackSunrise = LinearGradient(
        colors: [.quackYellow, .quackOrange, .quackPink],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A colored rounded-square tile with a white SF Symbol — the System
/// Settings–style category marker used in the sidebar and dashboard.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// A thin progress ring (0…1) in one color over a faint track.
struct ProgressRing: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 40
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8),
                   value: progress)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// Parses "#RRGGBB" (or "RRGGBB"). Returns nil for malformed input.
    init?(hex: String?) {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let value = Int(h, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
