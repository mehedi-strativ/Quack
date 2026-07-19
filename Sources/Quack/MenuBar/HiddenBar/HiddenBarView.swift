import SwiftUI
import AppKit

struct HiddenBarItemVM: Identifiable {
    let id: String
    let image: NSImage?
    let item: MenuBarAXItem
    /// Precomputed via `HiddenBarLayout.itemDisplayWidth`, so the rendered tile
    /// matches exactly what the panel's frame (sized before SwiftUI lays out
    /// anything) was computed for — a captured glyph is rarely square.
    let displayWidth: CGFloat
}

/// The secondary-bar replica strip: a row of hidden-item glyphs (or app-icon
/// fallback) plus an optional Screen Recording banner.
struct HiddenBarView: View {
    let items: [HiddenBarItemVM]
    let onClick: (MenuBarAXItem) -> Void
    let showPermissionBanner: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showPermissionBanner {
                Button(action: onGrant) {
                    Label("Enable Screen Recording to show icons", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            ForEach(items) { vm in
                Button { onClick(vm.item) } label: {
                    Group {
                        if let img = vm.image {
                            Image(nsImage: img).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app.dashed").resizable().scaledToFit()
                        }
                    }
                    .frame(width: vm.displayWidth, height: 22)
                }
                .buttonStyle(.plain)
                .help(vm.item.appName)
            }
        }
        .padding(.horizontal, 6)
        // Transparent — the behind-window blur is an NSVisualEffectView placed
        // behind this host in HiddenBarPanel (a SwiftUI Material over a clear
        // panel has no in-window backdrop to sample, so it barely blurs).
        .frame(maxHeight: .infinity)
    }
}
