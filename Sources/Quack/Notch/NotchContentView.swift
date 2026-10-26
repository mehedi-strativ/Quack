import SwiftUI
import QuackKit

/// The notch panel content and its three states:
/// expanded (hover) / peek (ambient dot) / collapsed (invisible hover target).
struct NotchContentView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { model.onHoverChange?($0) }
    }

    @ViewBuilder
    private var content: some View {
        if model.isOpen {
            expanded
        } else if model.showsPeek {
            peek
        } else {
            Color.black.opacity(0.001)   // hover target only
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: model.contentTopInset)
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
                    agentsZone
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
            } else {
                Spacer().frame(height: 6)
            }
            Spacer(minLength: 0)
            quackFooterRow
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchTheme.panel)
        .clipShape(NotchShape())
        .foregroundStyle(.white)
    }

    /// Temperature and whole-machine CPU / GPU / memory, sampled while open.
    private var systemRow: some View {
        HStack(spacing: 6) {
            stat("thermometer.medium", model.temperatureText)
            stat("cpu", percent(model.cpuPercent), label: "CPU")
            stat("square.stack.3d.up", percent(model.gpuPercent), label: "GPU")
            stat("memorychip", percent(model.memoryPercent), label: "MEM")
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

    @ViewBuilder
    private var permissionsZone: some View {
        let list = VStack(spacing: 8) {
            ForEach(model.permissions) { prompt in
                PermissionCardView(prompt: prompt, project: model.project(for: prompt)) {
                    model.onAnswer?(prompt, $0)
                }
            }
        }
        if model.permissions.count > 2 {
            ScrollView(showsIndicators: false) { list }.frame(maxHeight: 2 * 104 + 8)
        } else {
            list
        }
    }

    /// Footer with the duck button that opens Quack's Settings.
    @ViewBuilder
    private var quackFooterRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .onTapGesture { model.onOpenQuack?() }
                .help("Open Quack")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
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
                Button { model.onAgentTap?(agent) } label: {
                    AgentCardView(agent: agent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var peek: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(model.agents.filter { $0.status != .idle }.prefix(6)) { agent in
                    Circle()
                        .fill(NotchTheme.statusColor(agent.status))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(peekAccessibilityLabel)
    }

    private var peekAccessibilityLabel: String {
        "\(model.activeCount) active agents"
    }
}
