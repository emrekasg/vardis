import SwiftUI
import VardisCore

/// Apps: every app with its processes rolled in, filterable and sortable, with an inspector at the trailing edge.
/// The inspector is a split, not a drawer: the table stays readable beside it, and ↑/↓ moves the inspector
/// from app to app, which is how people compare (the approved design shows the same split).
struct AppsView: View {
    @Environment(LiveModel.self) private var live
    @Environment(Navigation.self) private var nav
    @Environment(HistoryModel.self) private var history
    @Environment(\.cancelShortcutBlocked) private var cancelBlocked
    @State private var prefs = NowPrefs.shared

    @State private var query = ""
    @State private var filter: AppFilter = .all
    @State private var sort: AppSort = .memory
    @State private var descending = true
    @State private var selection: String?
    @State private var inspecting: String?
    @State private var memoryHour: [String: [Double]] = [:]
    @State private var flagged: Set<String> = []
    @State private var starts: [String: Date] = [:]
    @FocusState private var searching: Bool
    @FocusState private var listFocused: Bool

    private var all: [AppSample] { live.snapshot?.apps ?? [] }

    private var rows: [AppSample] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = all.filter { app in
            (filter == .all || filter.kind == AppKind.of(app))
                && (q.isEmpty || app.name.localizedCaseInsensitiveContains(q) || app.id.localizedCaseInsensitiveContains(q))
        }
        return filtered.sorted { a, b in
            let ordered = sort.ascending(a, b, starts: starts)
            return descending ? sort.ascending(b, a, starts: starts) : ordered
        }
    }

    var body: some View {
        let rows = rows
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterBar(count: rows.count)
                Hairline()
                AppsHeader(sort: $sort, descending: $descending, compact: inspecting != nil)
                    .padding(.horizontal, 20)
                Hairline().padding(.horizontal, 20)
                table(rows)
            }
            .frame(maxWidth: .infinity)
            if let id = inspecting, let app = all.first(where: { $0.id == id }) {
                Rectangle().fill(Theme.separator).frame(width: 1)
                AppInspector(app: app, started: starts[app.id], flagged: flagged.contains(app.name), close: closeInspector)
                    .frame(width: 400)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .motion(Motion.drawer, value: inspecting)
        .background(Theme.window)
        .background { shortcuts(rows) }
        .onAppear { takeNavigationSelection() }
        .onChange(of: nav.selectedAppID) { takeNavigationSelection() }
        // Keyed to the sample count, so nothing runs while the window is hidden (no samples reach the UI).
        .task(id: live.tick / 10) { starts = await live.appStartDates() }
        .task(id: live.tick / 120) {
            memoryHour = await history.appMemoryLastHour()
            flagged = await history.growthFlaggedApps()
        }
    }

    // MARK: Filter bar

    private func filterBar(count: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .screenSearchFocus($searching)
                    .onSubmit { listFocused = true }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                        .help("Clear search")
                }
            }
            .font(.bodyV)
            .padding(.horizontal, 8).frame(minWidth: 140, idealWidth: 220, maxWidth: 220, minHeight: 26, maxHeight: 26)
            .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Search (⌘F)")

            if inspecting == nil {
                Picker("Show", selection: $filter) {
                    ForEach(AppFilter.allCases) { f in Text("\(f.title) \(countText(f))").tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                // Beside the inspector there is no room for five segments; the same choice as a menu.
                Picker("Show", selection: $filter) {
                    ForEach(AppFilter.allCases) { f in Text("\(f.title) \(countText(f))").tag(f) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 8)
            if count != all.count {
                Text("\(count) of \(all.count) apps")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Order", selection: $descending) {
                    Text("Highest first").tag(true)
                    Text("Lowest first").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label(inspecting == nil ? "Sort: \(sort.title)" : sort.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20).frame(height: 48)
    }

    private func countText(_ f: AppFilter) -> String {
        let n = f == .all ? all.count : all.reduce(0) { $0 + (AppKind.of($1) == f.kind ? 1 : 0) }
        return "\(n)"
    }

    // MARK: Table

    private func table(_ rows: [AppSample]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { app in
                        AppRow(app: app, started: starts[app.id], hour: memoryHour[app.id],
                               maxMemory: rows.first.map { max($0.memory, all.first?.memory ?? 1) } ?? 1,
                               leak: flagged.contains(app.name), pinned: prefs.isPinned(app.id),
                               selected: selection == app.id, compact: inspecting != nil)
                            .id(app.id)
                            .onTapGesture { select(app.id, inspect: true) }
                            .contextMenu { menu(app) }
                    }
                    if rows.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No apps match",
                                   detail: query.isEmpty ? "Nothing in this group is running." : "Nothing running matches \u{201C}\(query)\u{201D}.")
                            .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { step(-1, rows, proxy); return .handled }
            .onKeyPress(.downArrow) { step(1, rows, proxy); return .handled }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                inspecting = selection
                return .handled
            }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder
    private func menu(_ app: AppSample) -> some View {
        Button("Show Details") { select(app.id, inspect: true) }
        Button(prefs.isPinned(app.id) ? "Unpin from Now" : "Pin to Now") { prefs.togglePin(app.id) }
        Divider()
        if app.bundleURL != nil { Button("Reveal in Finder") { AppActions.reveal(app, executable: nil) } }
        if app.bundleURL != nil { Button("Restart\u{2026}") { AppActions.restart(app) } }
        Button("Quit\u{2026}") { AppActions.quit(app) }
        Button("Force Quit\u{2026}") { AppActions.forceQuit(app) }
    }

    /// Hidden buttons that carry the screen's shortcuts: ⌘⌫ quits the selected app (after a confirmation),
    /// Esc closes the inspector.
    private func shortcuts(_ rows: [AppSample]) -> some View {
        ZStack {
            Button("Quit selected app") {
                if let id = selection, let app = all.first(where: { $0.id == id }) { AppActions.quit(app) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil || searching)
            Button("Close inspector") { closeInspector() }
                .keyboardShortcut(cancelBlocked || inspecting == nil ? nil : .cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func step(_ delta: Int, _ rows: [AppSample], _ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let i = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : rows.count)
        let next = rows[min(rows.count - 1, max(0, i + delta))].id
        select(next, inspect: inspecting != nil)
    }

    private func select(_ id: String, inspect: Bool) {
        selection = id
        listFocused = true
        if inspect { inspecting = id }
    }

    private func closeInspector() {
        inspecting = nil
        listFocused = true
    }

    private func takeNavigationSelection() {
        #if DEBUG
        // Visual checks: `VARDIS_INSPECT=<app id>` opens the inspector on launch (with --snapshot).
        if inspecting == nil, let id = ProcessInfo.processInfo.environment["VARDIS_INSPECT"] { select(id, inspect: true) }
        #endif
        guard let id = nav.selectedAppID else { return }
        nav.selectedAppID = nil
        filter = .all
        query = ""
        select(id, inspect: true)
    }
}

// MARK: Filter and sort

enum AppFilter: String, CaseIterable, Identifiable {
    case all, apps, background, system, commandLine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        case .background: "Background"
        case .system: "System"
        case .commandLine: "Command line"
        }
    }
    var kind: AppKind? {
        switch self {
        case .all: nil
        case .apps: .app
        case .background: .background
        case .system: .system
        case .commandLine: .commandLine
        }
    }
}

enum AppSort: String, CaseIterable, Identifiable {
    case name, cpu, memory, energy, diskWrite, uptime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        case .diskWrite: "Disk write"
        case .uptime: "Uptime"
        }
    }

    /// Strict "a before b" when sorting lowest first; ties fall back to name so rows do not jump.
    func ascending(_ a: AppSample, _ b: AppSample, starts: [String: Date]) -> Bool {
        func tie() -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        switch self {
        case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
        case .cpu: return a.cpu == b.cpu ? tie() : a.cpu < b.cpu
        case .memory: return a.memory == b.memory ? tie() : a.memory < b.memory
        case .energy: return a.energyWatts == b.energyWatts ? tie() : a.energyWatts < b.energyWatts
        case .diskWrite: return a.diskWriteBytesPerSecond == b.diskWriteBytesPerSecond ? tie() : a.diskWriteBytesPerSecond < b.diskWriteBytesPerSecond
        case .uptime:
            // Longer uptime = earlier start.
            let sa = starts[a.id] ?? .distantFuture, sb = starts[b.id] ?? .distantFuture
            return sa == sb ? tie() : sa > sb
        }
    }
}
