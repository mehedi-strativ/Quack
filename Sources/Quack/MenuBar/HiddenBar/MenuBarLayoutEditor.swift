import SwiftUI

/// Read-only preview of the live menu bar, grouped Shown / Hidden with real
/// glyphs. Actual hiding/showing is done via the Arrange button (cmd-drag):
/// macOS does not allow programmatic reordering of third-party status items
/// (see the Task 3 mechanism spike).
struct MenuBarLayoutEditor: View {
    let items: [HiddenBarService.LayoutItem]
    let onRefresh: () -> Void

    private var shown: [HiddenBarService.LayoutItem] { items.filter { !$0.isHidden } }
    private var hidden: [HiddenBarService.LayoutItem] { items.filter { $0.isHidden } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "Shown", section: shown, emptyHint: "No visible icons detected")
            row(title: "Hidden", section: hidden, emptyHint: "Nothing hidden yet")
            HStack(spacing: 8) {
                Button("Refresh", action: onRefresh).controlSize(.small)
                Text("Live preview. Use Arrange to change what's hidden.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(title: String, section: [HiddenBarService.LayoutItem], emptyHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if section.isEmpty {
                    Text(emptyHint).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ForEach(section) { tile($0) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tile(_ item: HiddenBarService.LayoutItem) -> some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
            }
        }
        .frame(width: 22, height: 22)
        .help(item.name)
    }
}
