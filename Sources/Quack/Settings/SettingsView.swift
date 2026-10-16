import SwiftUI
import QuackKit

/// The feature groups shown in the left sidebar. Tabs are named for what they
/// control (self-describing), grouped by surface: menu bar, input, screen, app.
enum SettingsTab: String, CaseIterable {
    case dashboard, stats
    case mouse
    case brightness
    case general, permissions

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .stats: return "Stats & Timer"
        case .mouse: return "Mouse"
        case .brightness: return "Brightness"
        case .general: return "Settings"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .stats: return "gauge.with.needle"
        case .mouse: return "computermouse"
        case .brightness: return "sun.max"
        case .general: return "gearshape"
        case .permissions: return "lock.shield"
        }
    }

    /// Each feature area's signature color — one step along a warm-to-violet
    /// "sunrise" ramp in sidebar order, all at matched saturation/brightness,
    /// so the tiles read as one family rather than a rainbow.
    var color: Color {
        switch self {
        case .dashboard: return Color(hex: "#FFAA1F")!
        case .stats: return Color(hex: "#FF6A3D")!
        case .mouse: return Color(hex: "#FF4F66")!
        case .brightness: return Color(hex: "#B455CC")!
        case .general: return Color(hex: "#8F5FE0")!
        case .permissions: return Color(hex: "#6C67F0")!
        }
    }
}

/// Named groupings for the sidebar. `Dashboard` sits alone at the top;
/// `App` (General/Permissions) closes the list.
private enum SidebarGroup: String, CaseIterable {
    case top = ""
    case menuBar = "Menu Bar"
    case input = "Input"
    case screen = "Screen"
    case app = "App"

    var tabs: [SettingsTab] {
        switch self {
        case .top: return [.dashboard]
        case .menuBar: return [.stats]
        case .input: return [.mouse]
        case .screen: return [.brightness]
        case .app: return [.general, .permissions]
        }
    }

    /// Whether to render a visible header label (top is unlabeled).
    var showsHeader: Bool { self != .top }
}

/// The whole settings window: an immersive full-height sidebar (grouped nav,
/// traffic-light-aware app title) on the left and the selected pane on the
/// right. Uses `NavigationSplitView` so the sidebar material, selection
/// highlight, and light/dark colors are all native and adapt to the appearance.
struct SettingsRootView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var selection: Binding<SettingsTab?> {
        Binding(get: { env.settingsTab }, set: { if let new = $0 { env.settingsTab = new } })
    }

    private var results: [SettingEntry] {
        SettingsSearch.matches(query, in: SettingsSearchRegistry.all)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 280)
        } detail: {
            SettingsPane(tab: env.settingsTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .font(.system(size: 14))
        .tint(.quackOrange)
        .onAppear { env.permissions.refreshAll() }
        // ⌘F from anywhere in the window focuses the search field.
        .background(Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).accessibilityHidden(true))
    }

    /// A single, always-present `List` whose ROWS swap between the grouped
    /// nav and search results — never the List itself. Swapping the List
    /// instance (an earlier version wrapped search results in their own
    /// `List` behind an if/else) tore down and rebuilt the sidebar's hosting
    /// view on every keystroke, stealing focus back from the search field
    /// each time. One stable List keeps the header (logo + search box, in
    /// that fixed order) untouched while typing.
    private var sidebar: some View {
        List(selection: selection) {
            if query.isEmpty {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section {
                        ForEach(group.tabs, id: \.self) { tab in
                            // HStack, not Label: the sidebar Label's icon slot is
                            // fixed ~20pt wide and clips a larger tile.
                            HStack(spacing: 8) {
                                IconTile(symbol: tab.icon, color: tab.color, size: 22)
                                Text(tab.title).font(.system(size: 14, weight: .medium))
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .tag(tab)
                        }
                    } header: {
                        if group.showsHeader {
                            Text(group.rawValue).accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            } else {
                Section {
                    searchResultRows
                }
                .accessibilityLabel("\(results.count) settings match \(query)")
            }
        }
        .listStyle(.sidebar)
        // Immersive: the sidebar material runs full-height under the
        // transparent title bar. Logo sits first, search box right below it —
        // both fixed here so neither ever competes with system-controlled
        // placement for order.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                appIdentity
                searchField
            }
        }
        // Quit is always reachable, pinned to the very bottom of the sidebar.
        .safeAreaInset(edge: .bottom, spacing: 0) { quitFooter }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onSubmit { if let first = results.first { open(first) } }
                .onExitCommand { query = ""; searchFocused = false }
                .accessibilityLabel("Search settings")
            if query.isEmpty {
                Text("⌘F").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(searchFocused ? 0.22 : 0.08), lineWidth: 1))
        )
        .padding(.horizontal, 10).padding(.bottom, 4)
    }

    @ViewBuilder
    private var searchResultRows: some View {
        if results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No matches").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Try \"scroll\", \"break\" or \"hide\"")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        } else {
            ForEach(results) { entry in
                Button { open(entry) } label: {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(entry.title).font(.system(size: 12.5)).lineLimit(1)
                        Text(breadcrumb(entry))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 1)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens \(breadcrumb(entry))")
            }
        }
    }

    private func breadcrumb(_ e: SettingEntry) -> String {
        let tab = SettingsTab(rawValue: e.tabID)?.title ?? e.tabID
        return "\(tab) › \(e.section)"
    }

    private func open(_ entry: SettingEntry) {
        if let tab = SettingsTab(rawValue: entry.tabID) { env.settingsTab = tab }
        env.settingsSpotlight = entry.section
        query = ""
        searchFocused = false
    }

    private var quitFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "power").font(.system(size: 13, weight: .semibold)).frame(width: 20)
                    Text("Quit Quack").font(.system(size: 14))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
    }

    private var appIdentity: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 18, height: 18)
            Text("Quack").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, 78)   // clear the traffic-light cluster
        .padding(.trailing, 12)
        .frame(height: 28)       // align with the title-bar height
        .padding(.top, 6).padding(.bottom, 8)
    }
}

/// One settings pane. The `general` tab is the custom schedule view; every
/// other tab is a grouped `Form`.
struct SettingsPane: View {
    let tab: SettingsTab
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        // The window title (active tab name) is drawn by AppKit in the
        // transparent title bar, outside SwiftUI's layout — nothing reserves
        // that strip automatically. A `safeAreaInset` here does NOT fix it:
        // Form's grouped-style section headers are sticky (they pin to the
        // scroll view's own top edge while scrolling), and that pin ignores
        // a safe-area inset applied outside the Form. A real spacer, in
        // normal layout flow, pushes the Form's scroll region itself down —
        // so its sticky header pins below the title instead of under it.
        VStack(spacing: 0) {
            Color.clear.frame(height: 30)
            pane
        }
            // Search-jump spotlight: a transient chip naming the section the
            // user searched for, so the eye lands in the right place.
            .overlay(alignment: .top) {
                if let section = env.settingsSpotlight {
                    // 30 clears the spacer above; +10 is the chip's own margin.
                    SpotlightChip(text: section)
                        .padding(.top, 40)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            env.settingsSpotlight = nil
                        }
                }
            }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .dashboard:
            DashboardView()
        default:
            Form {
                switch tab {
                case .brightness:
                    BrightnessSection()
                case .stats:
                    TemperatureSection()
                    TimeAwarenessStatsSection()
                    TimeAwarenessSection()
                case .mouse:
                    MousePointerSection()
                    MouseScrollSection()
                    MouseButtonsSection()
                    MouseClickMonitorSection()
                case .general:
                    SettingsSection()
                case .permissions:
                    PermissionsSection()
                    StatusSection()
                case .dashboard:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)   // let the darker window bg show through
        }
    }
}

/// The transient "you jumped here" marker after picking a search result.
/// Fades in/out unless Reduce Motion is on (then it just appears/disappears).
private struct SpotlightChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.quackOrange)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.quackOrange.opacity(0.14))
            .overlay(Capsule().strokeBorder(Color.quackOrange.opacity(0.35), lineWidth: 1)))
        .transition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .identity : .opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel("Jumped to \(text)")
    }
}

// MARK: - Settings (app-level preferences)

private struct SettingsSection: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
      Group {
        let s = env.settingsStore
        Section("General") {
            Toggle("Launch Quack at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
            Toggle("Hide the duck icon from the menu bar", isOn: s.binding(\.hideDuckIcon))
            Text("Settings stay reachable from the temperature and activity items, or by opening Quack again.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Section("Appearance") {
            Picker("Theme", selection: appearanceBinding) {
                ForEach(AppAppearance.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows your macOS Light/Dark setting and switches with it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    /// Bridges the string-backed `appearance` setting to the `AppAppearance`
    /// enum the picker uses. Persisting the change triggers the app-wide
    /// re-apply wired up in `AppEnvironment`.
    private var appearanceBinding: Binding<AppAppearance> {
        let s = env.settingsStore
        return Binding(
            get: { AppAppearance.from(s.settings.appearance) },
            set: { mode in s.update { $0.appearance = mode.rawValue } }
        )
    }
}

// MARK: - Dashboard (General tab)

/// The Dashboard tab: a greeting, then a grid of tinted stat cards — one
/// per feature area, each in its signature color. Cards open their tab.
private struct DashboardView: View {
    @EnvironmentObject var env: AppEnvironment
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]

    @State private var tempC: Double = -1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                greeting
                LazyVGrid(columns: columns, spacing: 14) {
                    DashCard(tab: .stats, title: "CPU", icon: "thermometer.medium") { cpuSummary }
                    if env.settingsStore.settings.timeAwarenessEnabled {
                        DashCard(tab: .stats, title: "Focus", icon: "bolt.fill") { timeSummary }
                    }
                    DashCard(tab: .brightness) { displaySummary }
                    DashCard(tab: .permissions) { permissionsSummary }
                }
            }
            .padding(20)
        }
        .background(.background)
        .task { await pollTemperature() }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.greeting(for: env.now))
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(Self.longDate.string(from: env.now))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Burning the midnight oil"
        }
    }

    private func pollTemperature() async {
        while !Task.isCancelled {
            tempC = await env.currentCPUTemperatureC()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    // MARK: Time awareness (today's stats)

    @ViewBuilder private var timeSummary: some View {
        if let stats = env.activityStats(for: Date()), stats.activeSeconds >= 60 {
            let top = env.activityTopApps(for: Date(), 1).first
            // ponytail: ring fills against a fixed 8h workday; make it a setting if anyone asks.
            gist(ActivityFormat.compact(stats.activeSeconds),
                 "\(stats.breaks) break\(stats.breaks == 1 ? "" : "s")" + (top.map { " · Top: \($0.name)" } ?? ""),
                 progress: Double(stats.activeSeconds) / (8 * 3600), ringColor: SettingsTab.stats.color)
        } else {
            gist("0m", "The timer records while you work")
        }
    }

    // MARK: CPU (live temperature)

    @ViewBuilder private var cpuSummary: some View {
        let s = env.settingsStore.settings
        let f = s.temperatureFahrenheit
        if tempC > 0 {
            let v = f ? tempC * 9 / 5 + 32 : tempC
            gist("\(Int(v.rounded()))°\(f ? "F" : "C")",
                 s.cpuTemperatureEnabled ? "Showing in menu bar" : "Not in menu bar",
                 tint: tempTint(tempC),
                 progress: (tempC - 30) / 70, ringColor: tempTint(tempC))
        } else {
            gist("—", "Reading sensor…")
        }
    }

    /// Green / orange / red by CPU temperature (°C), matching the menu-bar item.
    private func tempTint(_ c: Double) -> Color {
        if c >= 85 { return .red }
        if c >= 70 { return .orange }
        return .green
    }

    @ViewBuilder private var displaySummary: some View {
        let s = env.settingsStore.settings
        if s.brightnessEnabled {
            let n = env.diagnostics.externalDisplayCount
            gist("On", "F1 / F2 · \(n) external display\(n == 1 ? "" : "s")", tint: .green)
        } else {
            gist("Off", "Control external brightness with F1 / F2", tint: .secondary)
        }
    }

    @ViewBuilder private var permissionsSummary: some View {
        let kinds = PermissionKind.allCases
        let granted = kinds.filter { env.permissions.status(for: $0) == .granted }.count
        let denied = kinds.contains { env.permissions.status(for: $0) == .denied }
        let all = granted == kinds.count
        gist("\(granted)/\(kinds.count)",
             denied ? "Some access denied" : (all ? "All set" : "Tap to manage"),
             tint: all ? .primary : .orange,
             progress: Double(granted) / Double(kinds.count),
             ringColor: all ? SettingsTab.permissions.color : .orange)
    }

    /// Big rounded headline value + caption, with an optional progress ring.
    private func gist(_ primary: String, _ secondary: String?, tint: Color = .primary,
                      progress: Double? = nil, ringColor: Color = .quackOrange) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint).lineLimit(1)
                if let secondary {
                    Text(secondary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let progress { ProgressRing(progress: progress, color: ringColor) }
        }
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
    }()
}

/// A dashboard stat card in its feature's signature color: icon tile + title
/// over a big headline value, on a soft tinted wash. Opens the matching tab.
private struct DashCard<Content: View>: View {
    @EnvironmentObject var env: AppEnvironment
    let tab: SettingsTab
    var title: String?
    var icon: String?
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                env.settingsTab = tab
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { env.settingsTab = tab }
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IconTile(symbol: icon ?? tab.icon, color: tab.color, size: 24)
                    Text(title ?? tab.title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .offset(x: hovering ? 2 : 0)
                }
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tab.color.opacity(hovering ? 0.16 : 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(tab.color.opacity(hovering ? 0.45 : 0.22), lineWidth: 1)
                    )
            )
            .scaleEffect(hovering && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .instantHover($hovering)
        .accessibilityLabel("\(title ?? tab.title). Opens \(tab.title) settings")
    }
}

// MARK: - Brightness

private struct BrightnessSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("External-display brightness") {
            Toggle("Control external brightness with F1 / F2 keys", isOn: s.binding(\.brightnessEnabled))
            Text("When the cursor is on an external display, the brightness keys adjust that monitor over DDC instead of the built-in screen.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            if !env.brightnessController.isSupportedPlatform {
                Text("Brightness control is unavailable on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            } else if s.settings.brightnessEnabled {
                if env.permissions.status(for: .accessibility) != .granted {
                    HStack {
                        Text("F1 / F2 routing needs Accessibility permission (the slider still works without it).")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("Grant") { env.permissions.requestAccessibilityAccess() }
                    }
                }
                Stepper("Step: \(s.settings.brightnessStepPercent)%",
                        value: s.binding(\.brightnessStepPercent), in: 1...50, step: 1)
                Toggle("Dim the inactive display", isOn: s.binding(\.dimInactiveDisplay))
                if env.brightnessController.displays.isEmpty {
                    Text("No external displays detected.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(env.brightnessController.displays) { display in
                    DisplayRow(display: display)
                }
                Button("Re-scan displays") { env.brightnessController.refreshDisplays() }
            }
        }
    }
}

private struct DisplayRow: View {
    @EnvironmentObject var env: AppEnvironment
    let display: ControllableDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                Spacer()
                Text(display.supportsDDC ? "DDC supported" : "DDC not supported")
                    .font(.system(size: 12))
                    .foregroundStyle(display.supportsDDC ? .green : .secondary)
            }
            if display.supportsDDC {
                Slider(value: brightnessBinding, in: 0...1)
            }
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { env.settingsStore.settings.displayBrightness[display.id] ?? 0.8 },
            set: { env.applyBrightness($0, to: display) }
        )
    }
}

// MARK: - CPU temperature

private struct TemperatureSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("CPU temperature") {
            Toggle("Show CPU temperature in the menu bar", isOn: s.binding(\.cpuTemperatureEnabled))
            Text("Adds a flame icon with the current CPU temperature, read from the Mac's sensors. It turns orange, then red, as the chip heats up.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if s.settings.cpuTemperatureEnabled {
                Toggle("Show in Fahrenheit", isOn: s.binding(\.temperatureFahrenheit))
            }
        }
    }
}

// MARK: - Time awareness statistics (day-by-day)

private struct TimeAwarenessStatsSection: View {
    @EnvironmentObject var env: AppEnvironment
    /// 0 = today, -1 = yesterday, … Resets whenever the tab is recreated.
    @State private var dayOffset = 0

    var body: some View {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: env.now)) ?? env.now
        let stats = env.activityStats(for: date)
        Section("Statistics") {
            HStack {
                Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(!canGoBack(cal))
                Spacer()
                Text(label(for: date, cal)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(dayOffset >= 0)
            }
            if let stats {
                LabeledContent("Active", value: ActivityFormat.compact(stats.activeSeconds))
                LabeledContent("Breaks", value: "\(stats.breaks)")
                ForEach(env.activityTopApps(for: date, 5), id: \.bundleID) { app in
                    LabeledContent(app.name, value: ActivityFormat.compact(app.seconds))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No activity recorded.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Back stops at the older of: 29 days before today, or the oldest stored
    /// day (no point paging through guaranteed-empty days).
    private func canGoBack(_ cal: Calendar) -> Bool {
        let todayStart = cal.startOfDay(for: env.now)
        guard let floor29 = cal.date(byAdding: .day, value: -29, to: todayStart),
              let target = cal.date(byAdding: .day, value: dayOffset - 1, to: todayStart) else { return false }
        let oldest = env.activityOldestDay() ?? todayStart
        return target >= max(floor29, oldest)
    }

    private func label(for date: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}

// MARK: - Time awareness

private struct TimeAwarenessSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Time awareness") {
            Toggle("Show an activity timer in the menu bar", isOn: s.binding(\.timeAwarenessEnabled))
            Text("Counts how long you've been using the Mac without a real break, with a per-app breakdown in its menu. The timer resets after you've been away long enough.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if s.settings.timeAwarenessEnabled {
            Section("Rest reminders") {
                Toggle("Remind me to take breaks", isOn: s.binding(\.restRemindersEnabled))
                if s.settings.restRemindersEnabled {
                    Stepper("Remind after: \(s.settings.activityReminderMinutes) min of activity",
                            value: s.binding(\.activityReminderMinutes), in: 10...120, step: 5)
                    Stepper("Repeat every: \(s.settings.activityRepeatMinutes) min while I keep going",
                            value: s.binding(\.activityRepeatMinutes), in: 5...60, step: 5)
                }
                Stepper("Count a break after: \(s.settings.activityIdleResetMinutes) min away",
                        value: s.binding(\.activityIdleResetMinutes), in: 1...30, step: 1)
                Text("\"Away\" means no keyboard or mouse input — the screen being locked or the Mac asleep counts immediately.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mouse

private struct MousePointerSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Pointer") {
            Toggle("Override tracking speed", isOn: s.binding(\.mouseSensitivityEnabled))
            Text("Sets the system-wide pointer speed. Turning this off restores the speed you had before.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if s.settings.mouseSensitivityEnabled {
                HStack {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: s.binding(\.mouseSensitivity), in: 0...3)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                if !env.mouseSensitivity.liveApplyAvailable {
                    Text("Live apply unavailable on this macOS — changes take effect after replugging the mouse or logging in again.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct MouseScrollSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Scrolling") {
            Toggle("Smooth scrolling", isOn: s.binding(\.smoothScrollEnabled))
            Text("Animates scroll-wheel ticks into smooth motion, like a trackpad. Trackpads and Magic Mouse are unaffected.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if s.settings.smoothScrollEnabled,
               env.permissions.status(for: .accessibility) != .granted {
                HStack {
                    Text("Requires Accessibility permission.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Button("Grant") { env.permissions.requestAccessibilityAccess() }
                }
            }
        }
    }
}

private struct MouseButtonsSection: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var activeRecorder: Int? = nil

    var body: some View {
        let s = env.settingsStore
        let anyRemapped = s.settings.mouseButton4Action != MouseButtonAction.default_.rawValue
            || s.settings.mouseButton5Action != MouseButtonAction.default_.rawValue
        Section("Extra buttons") {
            buttonRow(label: "Button 4", id: 4,
                      action: \.mouseButton4Action, shortcut: \.mouseButton4Shortcut)
            buttonRow(label: "Button 5", id: 5,
                      action: \.mouseButton5Action, shortcut: \.mouseButton5Shortcut)
            Text("Buttons 4 and 5 are the side (back/forward) buttons on most mice.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if anyRemapped, env.permissions.status(for: .accessibility) != .granted {
                HStack {
                    Text("Requires Accessibility permission.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Button("Grant") { env.permissions.requestAccessibilityAccess() }
                }
            }
        }
    }

    @ViewBuilder
    private func buttonRow(label: String, id: Int,
                           action: WritableKeyPath<QuackSettings, String>,
                           shortcut: WritableKeyPath<QuackSettings, MouseShortcut?>) -> some View {
        let s = env.settingsStore
        let actionBinding = Binding<MouseButtonAction>(
            get: { MouseButtonAction.from(s.settings[keyPath: action]) },
            set: { new in s.update { $0[keyPath: action] = new.rawValue } }
        )
        Picker(label, selection: actionBinding) {
            ForEach(MouseButtonAction.allCases, id: \.self) { a in
                Text(a.title).tag(a)
            }
        }
        if actionBinding.wrappedValue == .customShortcut {
            ShortcutRecorderField(shortcut: s.binding(shortcut),
                                   recorderID: id, activeRecorder: $activeRecorder)
        }
    }
}

private struct MouseClickMonitorSection: View {
    @StateObject private var log = MouseClickLog.shared

    var body: some View {
        Section {
            if log.entries.isEmpty {
                Text("Click any mouse button to see it here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(log.entries) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Text(entry.time)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Click monitor")
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.link)
                    .disabled(log.entries.isEmpty)
            }
        }
        .onAppear { log.startMonitoring() }
        .onDisappear { log.stopMonitoring() }
    }
}

/// Composes a keyboard shortcut from modifier toggle chips + a recorded plain
/// key, instead of requiring the user to physically press the whole combo.
///
/// That's not a UX nicety — it's the only way to produce OS-reserved combos
/// (⌃→, ⌘Space, …) at all: the global Symbolic Hotkey handler consumes those
/// combos before any app's local `NSEvent` monitor ever sees them, so the old
/// "press the combo" recorder could never capture them. Toggling ⌃ on and
/// recording a bare `→` (never intercepted, since Control isn't held) sidesteps
/// that entirely.
///
/// Recording uses a local NSEvent monitor (only sees keys while Quack's
/// settings window is focused) — no event tap, no extra permissions. Esc
/// cancels. `activeRecorder` is shared across sibling fields (see
/// `MouseButtonsSection`): AppKit delivers a keydown to every registered local
/// monitor regardless of what any one of them returns, so without this,
/// recording on two fields at once would silently map both buttons to the
/// same keypress.
private struct ShortcutRecorderField: View {
    @Binding var shortcut: MouseShortcut?
    let recorderID: Int
    @Binding var activeRecorder: Int?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var modifierMask = 0

    private static let chips: [(bit: Int, label: String)] = [
        (0b10000, "fn"), (0b0100, "⌃"), (0b0010, "⌥"), (0b1000, "⇧"), (0b0001, "⌘"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Modifiers")
                Spacer()
                ForEach(Self.chips, id: \.bit) { chip in
                    Toggle(chip.label, isOn: chipBinding(chip.bit))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            HStack {
                Text("Key")
                Spacer()
                Button {
                    recording ? stopRecording() : startRecording()
                } label: {
                    Text(recording ? "Press a key… (⎋ cancels)" : (shortcut?.display ?? "Record Key"))
                        .frame(minWidth: 140)
                }
                .disabled(activeRecorder != nil && activeRecorder != recorderID)
            }
        }
        .onAppear { modifierMask = shortcut?.modifiers ?? 0 }
        .onDisappear { stopRecording() }
    }

    /// Toggling a chip updates the pending mask immediately; if a key is
    /// already recorded, it re-applies live with no need to re-record.
    private func chipBinding(_ bit: Int) -> Binding<Bool> {
        Binding(
            get: { modifierMask & bit != 0 },
            set: { on in
                modifierMask = on ? (modifierMask | bit) : (modifierMask & ~bit)
                if let existing = shortcut {
                    shortcut = MouseShortcut(keyCode: existing.keyCode, modifiers: modifierMask)
                }
            }
        )
    }

    private func startRecording() {
        guard activeRecorder == nil else { return }   // defensive: another field is recording
        activeRecorder = recorderID
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc — cancel, keep old value
            // Modifiers come from the chips, not the physical keypress — a
            // held Control here would mean the OS already ate the combo.
            shortcut = MouseShortcut(keyCode: Int(event.keyCode), modifiers: modifierMask)
            return nil   // consume — don't let the key trigger anything
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if activeRecorder == recorderID { activeRecorder = nil }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        Section("Permissions") {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                HStack {
                    Text(kind.displayName)
                    Spacer()
                    statusLabel(env.permissions.status(for: kind))
                    Button("Open Settings") { env.permissions.openSystemSettings(for: kind) }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Text("Granted").foregroundStyle(.green).font(.system(size: 12))
        case .denied:
            Text("Denied").foregroundStyle(.red).font(.system(size: 12))
        case .notRequested:
            Text("Not requested").foregroundStyle(.secondary).font(.system(size: 12))
        }
    }
}

// MARK: - Status (live diagnostics)

private struct StatusSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let d = env.diagnostics
        Section("Status") {
            row("Brightness keys active", d.brightnessKeyTapInstalled,
                onText: "listening", offText: env.settingsStore.settings.brightnessEnabled ? "needs Accessibility" : "off")
            HStack {
                Text("External displays")
                Spacer()
                Text("\(d.externalDisplayCount) screen(s), \(d.ddcServiceCount) DDC")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("\"Active\" means the feature is receiving input. If it says \"needs Accessibility\", grant it above — it switches to listening within a second, no relaunch.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ on: Bool, onText: String, offText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
            Text(on ? onText : offText)
                .font(.system(size: 12)).foregroundStyle(on ? .green : .secondary)
        }
    }
}
