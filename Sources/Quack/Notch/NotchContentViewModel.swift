import AppKit
import Combine
import QuackKit

/// Observable state for the notch panel: a system-load row on top, Claude
/// agent snapshots below.
@MainActor
final class NotchContentViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var agents: [AgentSnapshot] = []
    @Published var agentsEnabled = false
    @Published var integrationInstalled = false
    /// System-load row; nil until the first sample after hover-in.
    @Published var temperatureText: String?
    @Published var cpuPercent: Double?
    @Published var gpuPercent: Double?
    @Published var memoryPercent: Double?
    /// Real notch height for this screen; view pads content below the cutout.
    @Published var contentTopInset: CGFloat = 0

    var onHoverChange: ((Bool) -> Void)?
    var onAgentTap: ((AgentSnapshot) -> Void)?
    /// Opens Quack's Settings window (the duck button in the footer).
    var onOpenQuack: (() -> Void)?

    var needsYouCount: Int { agents.filter { $0.status == .needsYou }.count }
    var activeCount: Int { agents.filter { $0.status != .idle }.count }
    /// Ambient peek shows only when the agents zone is on and something is live.
    var showsPeek: Bool { agentsEnabled && activeCount > 0 }
}
