import SwiftUI
import QuackKit

/// The unified notch panel content and its three states:
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
            if !model.overflowItems.isEmpty {
                overflowZone
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
            if model.mediaEnabled {
                MediaStripView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchTheme.panel)
        .clipShape(NotchShape())
        .foregroundStyle(.white)
    }

    private var overflowZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Hidden from menu bar", systemImage: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer(minLength: 0)
                Button { model.onToggleOverflowPin?() } label: {
                    Image(systemName: model.isOverflowPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(model.isOverflowPinned ? "Unpin overflow rail" : "Keep overflow rail open")
            }

            HStack(spacing: 6) {
                ForEach(model.overflowItems) { item in
                    Button { item.activate() } label: {
                        HStack(spacing: 5) {
                            if let image = item.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                            } else if let systemImage = item.systemImage {
                                Image(systemName: systemImage)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text(item.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(NotchTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(NotchTheme.card)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
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
                Text("Enable coding agents in Quack Settings")
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
                if !model.overflowItems.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(model.overflowItems.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(NotchTheme.orangeSoft)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(NotchTheme.orangeSoft.opacity(0.14)))
                    .accessibilityLabel("\(model.overflowItems.count) hidden menu items")
                }
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
        var parts: [String] = []
        if model.activeCount > 0 {
            parts.append("\(model.activeCount) active agents")
        }
        if !model.overflowItems.isEmpty {
            parts.append("\(model.overflowItems.count) hidden menu items")
        }
        return parts.joined(separator: ", ")
    }
}
