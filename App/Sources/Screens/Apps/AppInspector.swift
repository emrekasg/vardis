import SwiftUI
import VardisCore
import VardisSampling
import VardisStore

/// One app in depth: identity and signature, live numbers, history, what happened to it, its processes and ports.
struct AppInspector: View {
    @Environment(LiveModel.self) private var live
    @Environment(HistoryModel.self) private var history
    @State private var prefs = NowPrefs.shared
    let app: AppSample
    let started: Date?
    let flagged: Bool
    let close: () -> Void

    @State private var processes: [ProcessSample] = []
    @State private var signature: CodeSignature?
    @State private var ports: [ServerProcess]?
    @State private var events: [HistoryEvent] = []
    @State private var past = AppHistory()
    @State private var range: NowDetailPanel.HistoryRange = .hour

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    liveNumbers
                    charts
                    if flagged { leakNote }
                    operations
                    processTree
                    portsSection
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
            }
            Hairline()
            actions
        }
        .background(Theme.surface)
        .id(app.id)
        .task(id: app.id) { await loadOnce() }
        .task(id: "\(app.id)-\(range.rawValue)") { past = await history.appHistory(id: app.id, last: range.seconds, points: 120) }
        .task(id: "\(app.id)-\(live.tick)") { processes = await live.processes(inApp: app.id) }
    }

    private func loadOnce() async {
        signature = nil
        ports = nil
        if let url = app.bundleURL ?? processes.first.map({ URL(fileURLWithPath: $0.executablePath) }) {
            signature = await Task.detached(priority: .userInitiated) { CodeSignature.read(url: url) }.value
        }
        events = await history.events(forApp: app.name, id: app.id)
        // Ports are read once per open, for this app's pids only.
        ports = await PortScanner().scan(pids: app.processIDs)
        if signature == nil, let path = processes.first?.executablePath, !path.isEmpty {
            signature = await Task.detached(priority: .userInitiated) { CodeSignature.read(url: URL(fileURLWithPath: path)) }.value
        }
    }

    // MARK: Header

    private var bundleInfo: [String: Any] { app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:] }

    private var header: some View {
        let version = bundleInfo["CFBundleShortVersionString"] as? String
        return HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleURL: app.bundleURL, name: app.name, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.titleV).foregroundStyle(Theme.text).lineLimit(2)
                Text([version.map { "Version \($0)" }, app.bundleURL != nil ? app.id : AppKind.subtitle(app)].compactMap { $0 }.joined(separator: ", "))
                    .font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(2).textSelection(.enabled)
                if let signature {
                    HStack(spacing: 6) {
                        Image(systemName: signature.kind == .unsigned || signature.kind == .adHoc ? "exclamationmark.shield" : "checkmark.shield")
                        Text(signature.label + (signature.teamID.map { ", team \($0)" } ?? ""))
                    }
                    .font(.captionV)
                    .foregroundStyle(signature.kind == .unsigned ? Theme.orange : Theme.textSecondary)
                    .help(signature.authority ?? "No signing certificate")
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Theme.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .motion(Motion.quick, value: signature)
    }

    private var liveNumbers: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU").font(.captionV).foregroundStyle(Theme.textTertiary)
                BigNumber(value: Fmt.percent(app.cpu).replacingOccurrences(of: "%", with: ""), unit: "%", font: .numericL)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory").font(.captionV).foregroundStyle(Theme.textTertiary)
                BigNumber(value: splitUnit(Fmt.bytes(app.memory)).0, unit: splitUnit(Fmt.bytes(app.memory)).1, font: .numericL)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(app.processCount == 1 ? "1 process" : "\(app.processCount) processes")
                if let started { Text("Up \(DurationFmt.compact(Date().timeIntervalSince(started)))") }
                Text(Fmt.watts(app.energyWatts))
            }
            .font(.calloutV).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }

    // MARK: History

    private var charts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.headlineV).foregroundStyle(Theme.text)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(NowDetailPanel.HistoryRange.allCases) { Text($0 == .hour ? "1 h" : "24 h").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if past.times.count > 1 {
                chartLabel("Memory")
                TimeChart(times: past.times, series: [ChartSeries(id: "Memory", color: Theme.Metric.memory, values: past.memory)],
                          format: { Fmt.bytes(double: $0) })
                    .frame(height: 80)
                chartLabel("CPU")
                TimeChart(times: past.times, series: [ChartSeries(id: "CPU", color: Theme.Metric.cpu, values: past.cpu)], format: Fmt.percent)
                    .frame(height: 56)
            } else {
                Text("Not in history yet. Vardis records the busiest apps; this one shows up once it ranks.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Sparkline(values: live.appMemory[app.id]?.elements ?? [], color: Theme.Metric.memory).frame(height: 40)
            }
        }
    }

    private func chartLabel(_ t: String) -> some View {
        Text(t).font(.captionV).foregroundStyle(Theme.textTertiary)
    }

    private var leakNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory keeps growing").font(.headlineV).foregroundStyle(Theme.text)
                Text(events.first { $0.kind == .memoryGrowth }?.detail ?? "Memory rose steadily for hours without a restart. Restarting frees it.")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Operations

    private var operations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Operations").font(.headlineV).foregroundStyle(Theme.text)
            if events.isEmpty {
                Text("Nothing recorded in the last 7 days.").font(.calloutV).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(Self.condense(events).prefix(12).enumerated()), id: \.offset) { _, e in
                        EventRow(event: e)
                    }
                }
            }
        }
    }

    /// A kept-awake spell is one line: its end (with the length) stands in for its start. Events are newest first.
    static func condense(_ events: [HistoryEvent]) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        var openEnd = false
        for e in events {
            if e.kind == .keptAwakeEnded { openEnd = true; out.append(e); continue }
            if e.kind == .keptAwakeStarted, openEnd { openEnd = false; continue }
            out.append(e)
        }
        return out
    }

    // MARK: Processes

    private var processTree: some View {
        let tree = Self.flatten(processes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processes").font(.headlineV).foregroundStyle(Theme.text)
                Spacer()
                Text("CPU").frame(width: 50, alignment: .trailing)
                Text("Memory").frame(width: 70, alignment: .trailing)
            }
            .font(.captionV).foregroundStyle(Theme.textTertiary)
            VStack(spacing: 0) {
                ForEach(tree, id: \.0.pid) { p, depth in
                    HStack(spacing: 6) {
                        if depth > 0 {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
                        }
                        Text(p.name).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Text("\(p.pid)").font(.captionV).foregroundStyle(Theme.textTertiary).monospacedDigit()
                        Spacer(minLength: 6)
                        Text(Fmt.percent(p.cpu)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: 50, alignment: .trailing)
                        Text(Fmt.bytes(p.memory)).font(.numeric).foregroundStyle(Theme.text).frame(width: 70, alignment: .trailing)
                    }
                    .padding(.leading, CGFloat(min(depth, 6)) * 14)
                    .padding(.vertical, 5)
                    .help(p.executablePath)
                    Hairline()
                }
            }
        }
    }

    /// Depth-first by parent pid; roots are processes whose parent is outside the app. Siblings by memory.
    static func flatten(_ list: [ProcessSample]) -> [(ProcessSample, Int)] {
        let pids = Set(list.map(\.pid))
        var children: [Int32: [ProcessSample]] = [:]
        for p in list where pids.contains(p.parentPID) && p.parentPID != p.pid { children[p.parentPID, default: []].append(p) }
        var out: [(ProcessSample, Int)] = []
        var seen = Set<Int32>()
        func visit(_ p: ProcessSample, _ d: Int) {
            guard seen.insert(p.pid).inserted else { return }
            out.append((p, d))
            for c in (children[p.pid] ?? []).sorted(by: { $0.memory > $1.memory }) { visit(c, d + 1) }
        }
        for root in list.filter({ !pids.contains($0.parentPID) || $0.parentPID == $0.pid }).sorted(by: { $0.memory > $1.memory }) { visit(root, 0) }
        for p in list where !seen.contains(p.pid) { visit(p, 0) }
        return out
    }

    // MARK: Ports

    @ViewBuilder
    private var portsSection: some View {
        if let ports {
            let all = ports.flatMap { s in s.ports.map { (s, $0) } }
            VStack(alignment: .leading, spacing: 6) {
                Text("Listening ports").font(.headlineV).foregroundStyle(Theme.text)
                if all.isEmpty {
                    Text("None. This app is not waiting for connections.").font(.calloutV).foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text("\(item.1.transport.rawValue) \(item.1.port)").font(.numeric).foregroundStyle(Theme.text)
                            Text(item.1.localOnly ? "this Mac only" : "reachable from the network")
                                .font(.captionV).foregroundStyle(item.1.localOnly ? Theme.textTertiary : Theme.orange)
                            Spacer()
                            Text("\(item.0.name) \(item.0.pid)").font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button { prefs.togglePin(app.id) } label: {
                Label(prefs.isPinned(app.id) ? "Unpin" : "Pin to Now", systemImage: prefs.isPinned(app.id) ? "pin.slash" : "pin")
            }
            .help(prefs.isPinned(app.id) ? "Remove from the watch list on Now" : "Watch this app on Now")
            Button { AppActions.reveal(app, executable: processes.first?.executablePath) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            Spacer()
            if app.bundleURL != nil {
                Button("Restart\u{2026}") { AppActions.restart(app) }
                    .help("Quit and open again")
            }
            Button("Quit\u{2026}") { AppActions.quit(app) }
                .help("Quit (⌘⌫)")
            Menu {
                Button("Force Quit\u{2026}") { AppActions.forceQuit(app) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More")
        }
        .controlSize(.regular)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.surface)
    }
}

private struct EventRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time).font(.captionV).foregroundStyle(Theme.textTertiary).monospacedDigit().frame(width: 62, alignment: .leading)
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.calloutV).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var time: String {
        Calendar.current.isDateInToday(event.timestamp)
            ? event.timestamp.formatted(.dateTime.hour().minute())
            : event.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var title: String {
        switch event.kind {
        case .appLaunched: "Launched"
        case .appQuit: "Quit"
        case .cpuHog: "High CPU"
        case .cpuHogEnded: "CPU back to normal"
        case .memoryGrowth: "Memory kept growing"
        case .keptAwakeStarted: "Keeping the Mac awake"
        case .keptAwakeEnded: event.value.map { "Kept the Mac awake for \(DurationFmt.compact($0))" } ?? "Kept the Mac awake"
        case .memoryPressure: "Memory pressure changed"
        case .swapGrew: "Swap grew"
        case .sleep: "Mac slept"
        case .wake: "Mac woke"
        }
    }

    private var detail: String? {
        switch event.kind {
        case .appLaunched, .appQuit: nil
        case .keptAwakeEnded: event.detail.isEmpty ? nil : event.detail
        default: event.detail.isEmpty ? nil : event.detail
        }
    }

    private var symbol: String {
        switch event.kind {
        case .appLaunched: "play.fill"
        case .appQuit: "stop.fill"
        case .cpuHog, .cpuHogEnded: "flame"
        case .memoryGrowth: "chart.line.uptrend.xyaxis"
        case .keptAwakeStarted, .keptAwakeEnded: "cup.and.saucer"
        default: "circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .cpuHog, .memoryGrowth: Theme.orange
        case .keptAwakeStarted, .keptAwakeEnded: Theme.accent
        default: Theme.textTertiary
        }
    }
}
