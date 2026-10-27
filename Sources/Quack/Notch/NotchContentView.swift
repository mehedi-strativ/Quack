import SwiftUI
import QuackKit

/// The notch panel content and its three states:
/// expanded (hover) / peek (ambient dot) / collapsed (invisible hover target).
/// The black shape is `shapeSize`, top-centered in the window; it springs
/// while the content inside stays laid out at its final `contentSize`.
struct NotchContentView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        content
            .frame(width: model.shapeSize.width, height: model.shapeSize.height, alignment: .top)
            .background(model.showsExpanded ? NotchTheme.panel : .clear)
            // Only the panel is notch-shaped; the collapsed strip never clips its dots.
            .clipShape(model.showsExpanded ? AnyShape(NotchShape()) : AnyShape(Rectangle()))
            .contentShape(Rectangle())
            .onHover { model.onHoverChange?($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if model.showsExpanded {
            expanded
                .frame(width: model.contentSize.width, height: model.contentSize.height)
        } else if model.showsPeek {
            peek
        } else {
            Color.black.opacity(0.001)   // hover target only
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: model.contentTopInset)
            // Scrolls only when the panel hits its screen-height cap, so tall
            // content is never cut off at the top.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    systemRow
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                    if !model.permissions.isEmpty {
                        permissionsZone
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    if model.agentsEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            NotchHeaderView(model: model)
                            // The waiting request is the focus; cards return after.
                            if model.permissions.isEmpty { agentsZone }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                    } else {
                        Spacer().frame(height: 6)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// Temperature and whole-machine CPU / GPU / memory, sampled while open.
    private var systemRow: some View {
        HStack(spacing: 6) {
            stat("thermometer.medium", model.temperatureText)
            stat("cpu", percent(model.cpuPercent), label: "CPU")
            stat("square.stack.3d.up", percent(model.gpuPercent), label: "GPU")
            stat("memorychip", percent(model.memoryPercent), label: "MEM")
            Button { model.onOpenQuack?() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.textMuted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(NotchTheme.card))
            }
            .buttonStyle(.plain)
            .help("Open Quack")
        }
        .frame(height: 24)
    }

    private func stat(_ icon: String, _ value: String?, label: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.textMuted)
            if let label {
                Text(label).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchTheme.textMuted)
            }
            Text(value ?? "--")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(NotchTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(NotchTheme.card))
    }

    private func percent(_ v: Double?) -> String? {
        v.map { "\(Int($0.rounded()))%" }
    }

    /// The oldest waiting request, one at a time like Claude Code. Its real
    /// height is reported so the panel can size to fit it.
    @ViewBuilder
    private var permissionsZone: some View {
        if let prompt = model.permissions.first {
            PermissionCardView(prompt: prompt, project: model.project(for: prompt),
                               moreCount: model.permissions.count - 1) {
                model.onAnswer?(prompt, $0)
            }
            .id(prompt.id)   // fresh picks / text for each request
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.preference(key: PromptHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(PromptHeightKey.self) { model.promptHeight = $0 }
        }
    }

    @ViewBuilder
    private var agentsZone: some View {
        if !model.integrationInstalled {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.orange)
                Text("Enable the Claude Code integration in Quack Settings")
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.agents.isEmpty {
            Text("No active agents")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
        } else if model.agents.count > 3 {
            ScrollView(showsIndicators: false) { cards }
                .frame(maxHeight: 3 * 100 + 2 * 8)
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(model.agents) { agent in
                // "Seen" only when nothing is left to answer for that session.
                let canSee = agent.status == .needsYou
                    && !model.permissions.contains { $0.session_id == agent.sessionID }
                Button { model.onAgentTap?(agent) } label: {
                    AgentCardView(agent: agent, onSeen: canSee ? { model.onSeen?(agent) } : nil,
                                  onGo: agent.status == .needsYou ? { model.onAgentTap?(agent) } : nil)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var peek: some View {
        HStack(spacing: 4) {
            ForEach(model.agents.filter { $0.status != .idle }.prefix(6)) { agent in
                Circle()
                    .fill(NotchTheme.statusColor(agent.status))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // centered in the strip
        .accessibilityElement(children: .combine)
        .accessibilityLabel(peekAccessibilityLabel)
    }

    private var peekAccessibilityLabel: String {
        "\(model.activeCount) active agents"
    }
}

private struct PromptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
