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
            hiddenIconsRow
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

    /// The menu-bar status items the notch is hiding, shown as their apps'
    /// icons (the window server unmaps crushed items, so there are no live
    /// pixels to mirror). Tap asks the owning app to press the item via AX.
    /// Placeholder when nothing is hidden, so the row is always visible.
    @ViewBuilder
    private var hiddenIconsRow: some View {
        HStack(spacing: 10) {
            if model.hiddenIcons.isEmpty {
                Text(model.axTrusted
                     ? "No icons hidden behind the notch"
                     : "Grant Accessibility to show hidden icons")
                    .font(.system(size: 10))
                    .foregroundStyle(model.axTrusted ? NotchTheme.textMuted : NotchTheme.orange)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
                ForEach(model.hiddenIcons) { item in
                    Group {
                        if let icon = item.icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "app.dashed")
                        }
                    }
                    .frame(width: 18, height: 18)
                    .onTapGesture { model.onHiddenIconTap?(item) }
                    .help("\(item.appName): \(item.title)")
                }
                Spacer(minLength: 0)
            }
            Divider().frame(height: 14)
            // Quack's own items are excluded from the scan (self-AXPress
            // crashes off-main), so the duck gets a real button instead —
            // plain SwiftUI tap on the main thread.
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
                Text("Enable Claude integration in Quack Settings")
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
                AgentCardView(agent: agent)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onAgentTap?(agent) }
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
            .background(Capsule().fill(Color.black))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
