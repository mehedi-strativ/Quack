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
    /// Held permission requests, answerable from the panel.
    @Published var permissions: [PermissionPrompt] = []
    /// Measured height of the request card, so the panel fits it exactly.
    @Published var promptHeight: CGFloat = 0
    /// System-load row; nil until the first sample after hover-in.
    @Published var temperatureText: String?
    @Published var cpuPercent: Double?
    @Published var gpuPercent: Double?
    @Published var memoryPercent: Double?
    /// Expanded content is drawn (true from open until the close spring ends).
    @Published var showsExpanded = false
    /// The black shape's current size; springs between notch and content size.
    @Published var shapeSize: CGSize = .zero
    /// Final open size: content is laid out once at this, the shape clips it.
    @Published var contentSize: CGSize = .zero
    /// Real notch height for this screen; view pads content below the cutout.
    @Published var contentTopInset: CGFloat = 0

    var onHoverChange: ((Bool) -> Void)?
    var onAgentTap: ((AgentSnapshot) -> Void)?
    var onSeen: ((AgentSnapshot) -> Void)?
    var onAnswer: ((PermissionPrompt, PermissionDecision) -> Void)?
    /// Opens Quack's Settings window (the gear button in the system row).
    var onOpenQuack: (() -> Void)?

    var needsYouCount: Int { agents.filter { $0.status == .needsYou }.count }
    /// The project name for a request, from its agent card when the hook
    /// didn't record one.
    func project(for prompt: PermissionPrompt) -> String {
        prompt.project ?? agents.first { $0.sessionID == prompt.session_id }?.project ?? "Claude Code"
    }
    var activeCount: Int { agents.filter { $0.status != .idle }.count }
    /// Ambient peek shows only when the agents zone is on and something is live.
    var showsPeek: Bool { agentsEnabled && activeCount > 0 }
}
