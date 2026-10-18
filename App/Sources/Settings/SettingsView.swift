import AppKit
import Combine
import ServiceManagement
import SwiftUI
import VardisCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", performance = "Performance", menuBar = "Menu Bar", alerts = "Alerts"
    case cleanup = "Disk Cleanup", claude = "Claude Code", privacy = "Privacy & Data"
    case integrations = "Integrations", advanced = "Advanced", about = "About Vardis"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .performance: "bolt"
        case .menuBar: "menubar.rectangle"
        case .alerts: "exclamationmark.triangle"
        case .cleanup: "internaldrive"
        case .claude: "sparkle"
        case .privacy: "hand.raised"
        case .integrations: "powerplug"
        case .advanced: "cpu"
        case .about: "info.circle"
        }
    }

    /// Words from each pane's rows, so searching "login" finds General.
    var keywords: [String] {
        switch self {
        case .general: ["login", "dock", "appearance", "dark", "light", "shortcut", "units", "temperature", "updates"]
        case .performance: ["sampling", "interval", "battery", "history", "memory"]
        case .menuBar: ["cpu", "memory", "network", "battery", "disk", "gpu", "ports", "status", "panel", "tabs", "tiles", "theme"]
        case .alerts: ["notifications", "leak", "awake", "quiet", "limit"]
        case .cleanup: ["xcode", "simulators", "node_modules", "caches", "trash", "large files"]
        case .claude: ["sessions", "search", "terminal", "resume", "cost"]
        case .privacy: ["retention", "history", "data"]
        case .integrations: ["mcp", "server", "codex", "cursor"]
        case .advanced: ["debug", "log", "onboarding"]
        case .about: ["version", "website", "source"]
        }
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(pane.rawValue).font(.bodyV).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selected).matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selected.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane
    @State private var query = ""
    @Namespace private var pill

    init(initialPane: SettingsPane = .general) { _pane = State(initialValue: Self.takeRequest() ?? initialPane) }

    @MainActor private static var requestedPane: SettingsPane?

    /// Asks Settings to show `pane`: the window opens on it, or an open window switches to it.
    static func request(_ pane: SettingsPane) {
        requestedPane = pane
        NotificationCenter.default.post(name: .vardisSelectSettingsPane, object: pane.rawValue)
    }

    private static func takeRequest() -> SettingsPane? {
        defer { requestedPane = nil }
        return requestedPane
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Color.clear.frame(height: 40)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.bodyV)
                        .onExitCommand { query = "" }
                        .onSubmit { if let first = visiblePanes.first { pane = first } }
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 6).padding(.bottom, 10)
                ForEach(visiblePanes) { p in
                    SettingsSidebarRow(pane: p, isSelected: pane == p, pill: pill) { pane = p }
                }
                if visiblePanes.isEmpty {
                    Text("No matches").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.horizontal, 14).padding(.top, 4)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: 210)
            .background(Theme.sidebar)
            .motion(Motion.travel, value: pane)
            Rectangle().fill(Theme.separator).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if pane != .about { Text(pane.rawValue).font(.titleV).foregroundStyle(Theme.text) }
                    paneView
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)
            .background(Theme.window)
        }
        .frame(width: 900, height: 660)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .vardisSelectSettingsPane)) { n in
            guard let raw = n.object as? String, let p = SettingsPane(rawValue: raw) else { return }
            query = ""
            pane = p
            _ = Self.takeRequest()
        }
    }

    /// Panes whose name, or a word that belongs to them, matches the search.
    private var visiblePanes: [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { p in
            p.rawValue.localizedCaseInsensitiveContains(q) || p.keywords.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    @ViewBuilder private var paneView: some View {
        switch pane {
        case .general: GeneralPane()
        case .performance: PerformancePane()
        case .menuBar: MenuBarPane()
        case .alerts: AlertsPane()
        case .cleanup: CleanupPane()
        case .claude: ClaudePane()
        case .privacy: PrivacyPane()
        case .integrations: IntegrationsPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @AppStorage(Pref.openAtLogin) private var openAtLogin = true
    @AppStorage(Pref.dockMode) private var dockMode = "whileOpen"
    @AppStorage(Pref.appearance) private var appearance = "light"
    @AppStorage(Pref.temperatureUnit) private var temp = "c"
    @AppStorage(Pref.networkUnit) private var net = "bytes"
    @AppStorage(Pref.cpuMode) private var cpu = "mac"
    @AppStorage(Pref.checkUpdates) private var updates = true

    var body: some View {
        GroupBoxV {
            FormRow(label: "Open at login", detail: "Vardis stays in the menu bar so its window opens instantly") {
                Toggle("", isOn: $openAtLogin).toggleStyle(.switch).labelsHidden()
                    .onChange(of: openAtLogin) { _, on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            }
            FormRow(label: "Show in Dock") {
                Picker("", selection: $dockMode) { Text("Only while the window is open").tag("whileOpen"); Text("Always").tag("always"); Text("Never").tag("never") }
                    .labelsHidden().fixedSize()
            }
            FormRow(label: "Open Vardis", detail: "Global shortcut") { Text("⌥⌘V").font(.calloutV).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.raised, in: RoundedRectangle(cornerRadius: 6)) }
            FormRow(label: "Appearance", showsDivider: false) {
                Picker("", selection: $appearance) { Text("Light").tag("light"); Text("Dark").tag("dark"); Text("System").tag("system") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: appearance) { _, v in Appearance.apply(v) }
            }
        }
        GroupBoxV(title: "Units") {
            FormRow(label: "Temperature") { segmented($temp, [("°C", "c"), ("°F", "f")]) }
            FormRow(label: "Network speed") { segmented($net, [("Bytes", "bytes"), ("Bits", "bits")]) }
            FormRow(label: "CPU percentage", detail: "Per Mac shows 100% at most. Per core goes up to 100% × cores.", showsDivider: false) { segmented($cpu, [("Per Mac", "mac"), ("Per core", "core")]) }
        }
        if Edition.current.supports(.sparkleUpdates) {
            GroupBoxV(title: "Updates") {
                FormRow(label: "Check for updates automatically", detail: "Downloads only vardis.app/appcast.xml", showsDivider: false) { Toggle("", isOn: $updates).toggleStyle(.switch).labelsHidden() }
            }
        }
    }
}

private struct PerformancePane: View {
    @Environment(LiveModel.self) private var live
    @AppStorage(Pref.closedInterval) private var closed = 5
    @AppStorage(Pref.openInterval) private var open = 1
    @AppStorage(Pref.slowOnLowBattery) private var lowBattery = true
    @AppStorage(Pref.keepWindowReady) private var ready = true

    var body: some View {
        HStack(spacing: 0) {
            measure("Launch", LaunchTiming.milliseconds.map { String(format: "%.0f ms", $0) } ?? "–", "budget 150 ms", (LaunchTiming.milliseconds ?? 0) <= 150)
            measure("Last sample", String(format: "%.1f ms", live.lastSampleDuration.milliseconds), "budget 5 ms", live.lastSampleDuration.milliseconds <= 5)
            measure("Memory", Fmt.bytes(live.ownFootprint), "budget 40 MB", live.ownFootprint <= 40_000_000)
            measure("Interval", live.isFast ? "1 s" : "5 s", live.isFast ? "window open" : "window closed", true)
        }
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
        Text("Vardis measures itself the same way it measures everything else.").font(.captionV).foregroundStyle(Theme.textTertiary)
        GroupBoxV(title: "Sampling") {
            FormRow(label: "When the window is closed", detail: "Menu bar and history only") {
                Picker("", selection: $closed) { Text("Every 2 s").tag(2); Text("Every 5 s").tag(5); Text("Every 10 s").tag(10) }.labelsHidden().fixedSize()
            }
            FormRow(label: "When the window is open") {
                Picker("", selection: $open) { Text("Every 1 s").tag(1); Text("Every 2 s").tag(2) }.labelsHidden().fixedSize()
            }
            FormRow(label: "On battery below 20%", detail: "Slows sampling to every 15 s") { Toggle("", isOn: $lowBattery).toggleStyle(.switch).labelsHidden() }
            FormRow(label: "Keep the window ready", detail: "Opens in one frame. Uses a few MB more.", showsDivider: false) { Toggle("", isOn: $ready).toggleStyle(.switch).labelsHidden() }
        }
        GroupBoxV(title: "History", footer: "History is downsampled as it ages, so a year fits in about 90 MB.") {
            FormRow(label: "Last hour", detail: "Every second") { Text("1 s").font(.numeric).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Last 24 hours", detail: "Every 10 seconds") { Text("10 s").font(.numeric).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Last 30 days", detail: "Every minute") { Text("1 min").font(.numeric).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Older", detail: "Every 10 minutes, up to the retention set in Privacy & Data", showsDivider: false) { Text("10 min").font(.numeric).foregroundStyle(Theme.textSecondary) }
        }
    }

    private func measure(_ k: String, _ v: String, _ b: String, _ ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.captionV).foregroundStyle(Theme.textTertiary)
            Text(v).font(.numericL).foregroundStyle(Theme.text)
                .contentTransition(.numericText()).motion(Motion.value, value: v)
            Text(b).font(.captionV).foregroundStyle(ok ? Theme.textTertiary : Theme.orange)
        }
        .padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuBarPane: View {
    @Bindable private var prefs = MenuBarPrefs.shared

    var body: some View {
        MenuBarPreview(pieces: MenuBarFeed.shared.ordered(prefs.enabledReadouts))
        GroupBoxV(title: "Status item", footer: prefs.showReadouts ? "Drag to reorder. Values refresh once per sample, and only when the text changes." : nil) {
            FormRow(label: "Show", detail: "Vardis uses one menu bar item", showsDivider: prefs.showReadouts) {
                Picker("", selection: $prefs.showReadouts) { Text("Icon only").tag(false); Text("Icon and values").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if prefs.showReadouts {
                ReorderList(items: $prefs.readouts, minimumOn: 0)
            }
        }
        GroupBoxV(title: "Panel tabs", footer: "Battery & Power shows only on Macs with a battery, and Claude Code once Vardis finds an account. ⌘1 to ⌘9 switch tabs.") {
            ReorderList(items: $prefs.tabs, minimumOn: 1)
        }
        GroupBoxV(title: "Overview tiles") {
            ReorderList(items: $prefs.tiles, minimumOn: 0)
        }
        GroupBoxV(title: "Panel", footer: "Match menu bar follows the menu bar, which is dark on dark wallpapers and in Dark Mode.") {
            FormRow(label: "Theme", showsDivider: false) {
                Picker("", selection: $prefs.theme) { Text("Match menu bar").tag(PanelTheme.system); Text("Light").tag(PanelTheme.light); Text("Dark").tag(PanelTheme.dark) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        HStack {
            Spacer()
            Button("Restore Defaults") { prefs.resetToDefaults() }
        }
    }
}

/// The Menu Bar pane alone, for `--menubar-snapshot <png> --tab settings`.
struct MenuBarPaneSnapshot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(SettingsPane.menuBar.rawValue).font(.titleV).foregroundStyle(Theme.text)
            MenuBarPane()
        }
        .padding(.horizontal, 36).padding(.vertical, 32)
        .frame(width: 672, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.window)
    }
}

/// A strip of menu bar with the status item as it looks right now.
private struct MenuBarPreview: View {
    let pieces: [MenuPiece]

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").foregroundStyle(Theme.textSecondary)
            Image(nsImage: StatusTitleRenderer.image(pieces))
                .renderingMode(.template)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Theme.text.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
        .accessibilityLabel("Preview of the menu bar item")
    }
}

/// Something a Menu Bar list can show: a title, a symbol and an optional detail.
private protocol MenuChoiceItem: Hashable, Sendable, RawRepresentable<String> {
    var title: String { get }
    var symbol: String { get }
    var choiceDetail: String? { get }
}

extension MenuReadout: MenuChoiceItem { var choiceDetail: String? { detail } }
extension MenuTab: MenuChoiceItem { var choiceDetail: String? { nil } }
extension MenuTile: MenuChoiceItem { var choiceDetail: String? { nil } }

/// Toggle rows that reorder by dragging (or with Move Up / Move Down in the context menu).
private struct ReorderList<Item: MenuChoiceItem>: View {
    @Binding var items: [OrderedChoice<Item>]
    let minimumOn: Int
    @State private var dragging: Item?

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.item) { i, choice in
            row(i, choice)
        }
    }

    private func row(_ i: Int, _ choice: OrderedChoice<Item>) -> some View {
        let onCount = items.filter(\.isOn).count
        return FormRow(label: choice.item.title, detail: choice.item.choiceDetail, showsDivider: i < items.count - 1) {
            Toggle("", isOn: Binding(get: { items[safe: i]?.isOn ?? false }, set: { v in
                guard i < items.count else { return }
                withAnimation(Motion.quick) { items[i].isOn = v }
            }))
            .toggleStyle(.switch).labelsHidden()
            .disabled(choice.isOn && onCount <= minimumOn)
        }
        .padding(.leading, 42)
        .overlay(alignment: .leading) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Image(systemName: choice.item.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(choice.isOn ? Theme.textSecondary : Theme.textTertiary).frame(width: 16)
            }
        }
        .opacity(dragging == choice.item ? 0.45 : 1)
        .contentShape(Rectangle())
        .onDrag {
            dragging = choice.item
            return NSItemProvider(object: choice.item.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDropDelegate(target: choice.item, items: $items, dragging: $dragging))
        .contextMenu {
            Button("Move Up") { move(i, by: -1) }.disabled(i == 0)
            Button("Move Down") { move(i, by: 1) }.disabled(i == items.count - 1)
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard items.indices.contains(i), items.indices.contains(j) else { return }
        withAnimation(Motion.travel) { items.swapAt(i, j) }
    }
}

private struct ReorderDropDelegate<Item: MenuChoiceItem>: DropDelegate {
    let target: Item
    @Binding var items: [OrderedChoice<Item>]
    @Binding var dragging: Item?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = items.firstIndex(where: { $0.item == dragging }),
              let to = items.firstIndex(where: { $0.item == target }) else { return }
        withAnimation(Motion.travel) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct AlertsPane: View {
    @AppStorage(Pref.alertCPU) private var cpu = true
    @AppStorage(Pref.alertLeak) private var leak = true
    @AppStorage(Pref.alertAwake) private var awake = true
    @AppStorage(Pref.alertHang) private var hang = true
    @AppStorage(Pref.alertClaudeLimit) private var limit = true
    @AppStorage(Pref.alertClaudeWaiting) private var waiting = true
    @AppStorage(Pref.alertSwitched) private var switched = true
    @AppStorage(Pref.quietHours) private var quiet = true

    var body: some View {
        GroupBoxV(title: "Apps") {
            FormRow(label: "An app uses a lot of CPU", detail: "Above 80% for 2 minutes") { toggle($cpu) }
            FormRow(label: "Memory keeps growing", detail: "Likely a leak, checked against the app’s own normal") { toggle($leak) }
            FormRow(label: "An app keeps the Mac awake", detail: "For 30 minutes, including a closed lid") { toggle($awake) }
            FormRow(label: "An app stops responding", detail: "For 5 seconds", showsDivider: false) { toggle($hang) }
        }
        GroupBoxV(title: "Claude Code") {
            FormRow(label: "An account nears its limit", detail: "At 90% of the 5-hour window") { toggle($limit) }
            FormRow(label: "A session is waiting for you", detail: "After 2 minutes") { toggle($waiting) }
            FormRow(label: "Accounts switched", showsDivider: false) { toggle($switched) }
        }
        GroupBoxV(title: "Quiet") {
            FormRow(label: "Quiet hours", detail: "22:00 – 08:00. Alerts wait in the Today digest.", showsDivider: false) { toggle($quiet) }
        }
    }
}

private struct CleanupPane: View {
    @AppStorage(Pref.cleanupProtectDays) private var days = 14
    @AppStorage(Pref.cleanupLargeFiles) private var large = false

    var body: some View {
        GroupBoxV(title: "Look in") {
            FormRow(label: "Xcode", detail: "DerivedData, Archives, iOS DeviceSupport") { Text("On").font(.calloutV).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Simulators", detail: "Runtimes and devices Xcode no longer lists") { Text("On").font(.calloutV).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "node_modules", detail: "In your project folders") { Text("On").font(.calloutV).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Package caches", detail: "Homebrew, npm, pnpm, yarn, pip, Cargo, Go, Gradle") { Text("On").font(.calloutV).foregroundStyle(Theme.textSecondary) }
            FormRow(label: "Large old files", detail: "Over 1 GB, untouched for 6 months", showsDivider: false) { toggle($large) }
        }
        GroupBoxV(title: "Safety", footer: "Nothing is ever deleted directly. Selected items go to the Trash, and you decide when to empty it.") {
            FormRow(label: "Protect projects opened in the last") {
                Picker("", selection: $days) { Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30) }.labelsHidden().fixedSize()
            }
            FormRow(label: "Move to Trash instead of deleting", detail: "Always on", showsDivider: false) { Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().disabled(true) }
        }
    }
}

private struct ClaudePane: View {
    @AppStorage(Pref.claudeSearchIndex) private var index = true
    @AppStorage(Pref.claudeGroupBy) private var group = "topic"
    @AppStorage(Pref.claudeTerminal) private var terminal = "Terminal"
    @AppStorage(Pref.claudeAPICost) private var apiCost = true

    var body: some View {
        GroupBoxV(title: "Sessions", footer: "Vardis reads session files where Claude Code writes them. It never changes them.") {
            FormRow(label: "Make sessions searchable", detail: "Full-text index on this Mac") { toggle($index) }
            FormRow(label: "Group history by") { segmented($group, [("Topic", "topic"), ("Project", "project"), ("Date", "date")]) }
            FormRow(label: "Resume in", showsDivider: false) {
                Picker("", selection: $terminal) { ForEach(["Terminal", "iTerm", "Ghostty", "Warp"], id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
        }
        GroupBoxV(title: "Cost") {
            FormRow(label: "Show cost as API-equivalent", detail: "What the same tokens would cost on the API", showsDivider: false) { toggle($apiCost) }
        }
    }
}

private struct PrivacyPane: View {
    @AppStorage(Pref.historyRetentionDays) private var retention = 90

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
            Text("Free forever, and we collect nothing. No account, no analytics, no crash reports. Vardis only goes online to check for updates, and to ask Anthropic for your own plan limits.")
                .font(.calloutV).foregroundStyle(Theme.text)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        GroupBoxV(title: "History") {
            FormRow(label: "Keep history for") {
                Picker("", selection: $retention) { Text("30 days").tag(30); Text("90 days").tag(90); Text("6 months").tag(180); Text("1 year").tag(365) }.labelsHidden().fixedSize()
            }
            FormRow(label: "Stored in", detail: "~/Library/Application Support/Vardis", showsDivider: false) {
                Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.support) }
            }
        }
    }
}

private struct IntegrationsPane: View {
    @AppStorage(Pref.mcpServer) private var mcp = false
    var body: some View {
        GroupBoxV(title: "MCP server", footer: "Lets Claude Code, Codex and Cursor ask Vardis about apps, ports and disk. It can never quit or delete anything without you confirming in a Vardis window.") {
            FormRow(label: "Run MCP server", showsDivider: false) { toggle($mcp) }
        }
    }
}

private struct AdvancedPane: View {
    @AppStorage(Pref.debugLog) private var debug = false
    @AppStorage(Pref.onboardingDone) private var onboardingDone = false
    var body: some View {
        GroupBoxV(title: "Diagnostics") {
            FormRow(label: "Write a debug log", detail: "Off by default. Kept for 24 hours, never sent.", showsDivider: false) { toggle($debug) }
        }
        GroupBoxV {
            FormRow(label: "Show onboarding again", showsDivider: false) { Button("Start") { onboardingDone = false; NotificationCenter.default.post(name: .vardisShowOnboarding, object: nil) } }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text(Brand.name).font(.largeTitleV).foregroundStyle(Theme.text)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")").font(.calloutV).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Badge("Free forever", tone: .green)
                Text("No account, and no data collected").font(.calloutV).foregroundStyle(Theme.textTertiary)
            }
            HStack {
                Link("Website", destination: Brand.website)
                Link("Source code", destination: Brand.repository)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: Helpers

private func toggle(_ b: Binding<Bool>) -> some View {
    Toggle("", isOn: b).toggleStyle(.switch).labelsHidden()
}

private func segmented(_ b: Binding<String>, _ options: [(String, String)]) -> some View {
    Picker("", selection: b) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
}

enum Appearance {
    @MainActor static func apply(_ value: String) {
        switch value {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: Brand.dataFolderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension Notification.Name {
    static let vardisShowOnboarding = Notification.Name("vardisShowOnboarding")
    static let vardisSelectSettingsPane = Notification.Name("vardisSelectSettingsPane")
}
