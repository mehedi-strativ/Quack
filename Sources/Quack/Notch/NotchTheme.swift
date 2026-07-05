import SwiftUI
import QuackKit

/// The notch panel's fixed dark theme (matches the approved mockup). The panel
/// visually extends the black notch, so it is always dark regardless of the
/// app-wide appearance setting.
enum NotchTheme {
    static let panel = Color(.sRGB, red: 0.086, green: 0.090, blue: 0.098, opacity: 1)   // #161719
    static let card = Color(.sRGB, red: 0.125, green: 0.129, blue: 0.153, opacity: 1)    // #202127
    static let strip = Color(.sRGB, red: 0.067, green: 0.071, blue: 0.078, opacity: 1)   // #111214
    static let hairline = Color.white.opacity(0.08)
    static let orange = Color(.sRGB, red: 0.961, green: 0.510, blue: 0.180, opacity: 1)  // #F5822E
    static let orangeSoft = Color(.sRGB, red: 0.961, green: 0.635, blue: 0.306, opacity: 1) // #F5A24E
    static let green = Color(.sRGB, red: 0.435, green: 0.812, blue: 0.341, opacity: 1)   // #6FCF57
    static let textPrimary = Color(.sRGB, red: 0.949, green: 0.949, blue: 0.941, opacity: 1)
    static let textSecondary = Color(.sRGB, red: 0.737, green: 0.741, blue: 0.729, opacity: 1)
    static let textMuted = Color(.sRGB, red: 0.549, green: 0.553, blue: 0.541, opacity: 1)

    /// Maps an agent's status to its dot/pill accent color.
    static func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .needsYou: return orange
        case .working: return green
        case .idle: return textMuted
        }
    }
}
