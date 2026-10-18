import AppKit
import SwiftUI
import VardisClaude
import VardisCore
import VardisStore

struct TodayView: View {
    @Environment(HistoryModel.self) private var history

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DayPicker().padding(.bottom, 8)
                    if let t = history.today {
                        // Another day is loading: keep the last one, dimmed, instead of a spinner.
                        DayContent(data: t)
                            .opacity(t.dayStart == history.day ? 1 : 0.5)
                            .motion(Motion.quick, value: t.dayStart == history.day)
                    } else {
                        Text("Vardis is recording. Today fills in as the day goes on.")
                            .font(.largeTitleV).foregroundStyle(Theme.text)
                    }
                    SummaryToggle().padding(.top, 30)
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.separator).frame(width: 1)
            RightNowRail()
                .frame(width: 300)
        }
        .background(Theme.window)
        .task(id: history.day) {
            // Fresh numbers while the screen is visible; past days do not change, so they load once.
            while !Task.isCancelled {
                await history.refreshToday()
                guard history.today?.isToday ?? true else { return }
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
            }
        }
    }
}

private struct DayContent: View {
    let data: TodayData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(data.summary)
                .font(.largeTitleV).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.screen, value: data.summary)
            if let note = data.note {
                Text(note).font(.bodyV).foregroundStyle(Theme.textSecondary).padding(.top, 6)
            }
            DayChart(data: data).padding(.top, 22)
            if let c = data.comparison {
                NormalDay(items: c).padding(.top, 28)
            }
            StandoutList(data: data).padding(.top, 30)
            if !data.foreground.isEmpty || !data.background.isEmpty {
                UsageSection(data: data).padding(.top, 30)
            }
            if !data.batterySessions.isEmpty {
                BatterySessions(sessions: data.batterySessions).padding(.top, 30)
            }
        }
    }
}

// MARK: Day picker

private struct DayPicker: View {
    @Environment(HistoryModel.self) private var history

    private enum Choice: Hashable { case today, yesterday, other }

    var body: some View {
        let cal = Calendar.current
        let choice: Choice = cal.isDateInToday(history.day) ? .today : (cal.isDateInYesterday(history.day) ? .yesterday : .other)
        HStack(spacing: 12) {
            Text(history.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.calloutV).foregroundStyle(Theme.textTertiary)
            Spacer()
            Picker("", selection: Binding(get: { choice }, set: { c in
                switch c {
                case .today: history.showDay(Date())
                case .yesterday: history.showDay(Date().addingTimeInterval(-86_400))
                case .other: break
                }
            })) {
                Text("Today").tag(Choice.today)
                Text("Yesterday").tag(Choice.yesterday)
                if choice == .other { Text(history.day.formatted(.dateTime.day().month(.abbreviated))).tag(Choice.other) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            DatePicker("", selection: Binding(get: { history.day }, set: { history.showDay($0) }),
                       in: Date().addingTimeInterval(-90 * 86_400)...Date(), displayedComponents: .date)
                .datePickerStyle(.field).labelsHidden().fixedSize()
                .help("Show another day")
        }
    }
}

// MARK: Chart

private struct DayChart: View {
    let data: TodayData
    @Environment(Navigation.self) private var nav
    @State private var metric: DayMetric = .cpu
    @State private var hoverX: CGFloat?

    static let palette: [Color] = [Theme.Metric.cpu, Theme.Metric.memory, Theme.Metric.network]
    static let rest = Theme.textTertiary.opacity(0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(caption).font(.captionV).foregroundStyle(Theme.textTertiary)
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(DayMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.bottom, 12)
            GeometryReader { g in
                let size = g.size
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { ctx, size in draw(ctx, size) }
                    if let x = hoverX, let i = index(at: x, width: size.width), let rows = tooltipRows(i) {
                        Rectangle().fill(Theme.text.opacity(0.35)).frame(width: 1, height: size.height).offset(x: x)
                        ChartTooltip(title: title(i), rows: rows)
                            .fixedSize()
                            .offset(x: x + 12 > size.width - 200 ? x - 212 : x + 12, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverX = p.x
                    case .ended: hoverX = nil
                    }
                }
            }
            .frame(height: 200)
            .motion(Motion.screen, value: metric)
            EventDots(data: data) { d in
                TimeMachineFocus.shared.open(at: d)
                nav.screen = .timeMachine
            }
            .frame(height: 18).padding(.top, 6)
            HStack(spacing: 0) {
                ForEach(0..<7) { i in
                    Text(String(format: "%02d:00", i * 4)).font(.captionV).foregroundStyle(Theme.textTertiary)
                    if i < 6 { Spacer() }
                }
            }
            .padding(.top, 4)
            if metric == .cpu {
                HStack(spacing: 16) {
                    ForEach(Array(data.top.enumerated()), id: \.offset) { i, a in legend(Self.palette[i], a.name) }
                    legend(Self.rest, "Everything else")
                    Spacer()
                }
                .padding(.top, 14)
            }
        }
    }

    private var caption: String {
        switch metric {
        case .cpu: "CPU share by app · click an event to rewind to it"
        case .memory: "Memory in use · click an event to rewind to it"
        case .energy: "Power the recorded apps drew"
        case .disk: "Disk reads and writes"
        case .network: "Network in and out"
        }
    }

    private var color: Color {
        switch metric {
        case .cpu: Theme.Metric.cpu
        case .memory: Theme.Metric.memory
        case .energy: Theme.Metric.battery
        case .disk: Theme.Metric.disk
        case .network: Theme.Metric.network
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .cpu: Fmt.percent(v)
        case .memory: Fmt.bytes(UInt64(max(0, v)))
        case .energy: Fmt.watts(v)
        case .disk, .network: Fmt.rate(v)
        }
    }

    private func legend(_ c: Color, _ name: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(name).font(.calloutV).foregroundStyle(Theme.textSecondary)
        }
    }

    private var values: [Double?] {
        metric == .cpu ? data.buckets.map { $0?.total } : (data.metrics[metric] ?? [])
    }

    private var scale: Double {
        let m = values.compactMap { $0 }.max() ?? 0
        return metric == .cpu ? max(0.25, m * 1.15) : max(0.0001, m * 1.15)
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        let n = data.buckets.count
        let i = Int(x / max(1, width) * CGFloat(n))
        guard i >= 0, i < n, values[safe: i].flatMap({ $0 }) != nil else { return nil }
        return i
    }

    private func title(_ i: Int) -> String {
        let t = data.dayStart.addingTimeInterval(Double(i) * TodayData.bucket)
        return t.formatted(date: .omitted, time: .shortened)
    }

    private func tooltipRows(_ i: Int) -> [(String, Color, String)]? {
        if metric == .cpu, let b = data.buckets[i] {
            var rows: [(String, Color, String)] = [("CPU", Theme.Metric.cpu, Fmt.percent(b.total))]
            if let app = b.topApp { rows.append((app, Theme.textTertiary, Fmt.percent(b.topAppCPU))) }
            return rows
        }
        guard let v = values[safe: i] ?? nil else { return nil }
        return [(metric.title, color, format(v))]
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = data.buckets.count
        guard n > 0 else { return }
        let step = size.width / CGFloat(n)
        for f in [0.33, 0.66] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height * f))
            p.addLine(to: CGPoint(x: size.width, y: size.height * f))
            ctx.stroke(p, with: .color(Theme.separator), lineWidth: 1)
        }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: size.height - 0.5))
        base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        ctx.stroke(base, with: .color(Theme.separator), lineWidth: 1)

        typealias Layer = (color: Color, value: (Int) -> Double)
        var layers: [Layer]
        let present: (Int) -> Bool
        if metric == .cpu {
            // Layers bottom to top: everything else, then the top apps (largest on top).
            layers = [(Self.rest, { i in data.buckets[i].map { max(0, $0.total - $0.apps.reduce(0, +)) } ?? 0 })]
            for j in (0..<data.top.count).reversed() {
                layers.append((Self.palette[j], { i in data.buckets[i]?.apps[safe: j] ?? 0 }))
            }
            present = { data.buckets[$0] != nil }
        } else {
            let v = values
            layers = [(color.opacity(0.55), { i in v[safe: i].flatMap { $0 } ?? 0 })]
            present = { i in v[safe: i].flatMap { $0 } != nil }
        }
        let s = scale
        func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1, v / s)) * size.height }

        // Contiguous runs of recorded buckets; gaps stay empty.
        var runs: [[Int]] = []
        var cur: [Int] = []
        for i in 0..<n {
            if present(i) { cur.append(i) } else if !cur.isEmpty { runs.append(cur); cur = [] }
        }
        if !cur.isEmpty { runs.append(cur) }

        for run in runs {
            var lower = run.map { _ in 0.0 }
            for (color, value) in layers {
                let upper = zip(run, lower).map { i, lo in lo + value(i) }
                var p = Path()
                for (j, i) in run.enumerated() {
                    let x = (CGFloat(i) + 0.5) * step
                    if j == 0 { p.move(to: CGPoint(x: x - step / 2, y: y(upper[j]))) }
                    p.addLine(to: CGPoint(x: x, y: y(upper[j])))
                    if j == run.count - 1 { p.addLine(to: CGPoint(x: x + step / 2, y: y(upper[j]))) }
                }
                for (j, i) in run.enumerated().reversed() {
                    let x = (CGFloat(i) + 0.5) * step
                    if j == run.count - 1 { p.addLine(to: CGPoint(x: x + step / 2, y: y(lower[j]))) }
                    p.addLine(to: CGPoint(x: x, y: y(lower[j])))
                    if j == 0 { p.addLine(to: CGPoint(x: x - step / 2, y: y(lower[j]))) }
                }
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(color == Self.rest ? 1 : 0.85)))
                lower = upper
            }
        }
    }
}

private struct EventDots: View {
    let data: TodayData
    let open: (Date) -> Void

    var body: some View {
        GeometryReader { g in
            let events = data.events.filter(EventStyle.isNotable).filter { !SystemDaemons.isSystem($0.app) }
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                let f = e.timestamp.timeIntervalSince(data.dayStart) / 86_400
                Button { open(e.timestamp) } label: {
                    Circle().fill(EventStyle.color(e))
                        .frame(width: 7, height: 7)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(e.timestamp.formatted(date: .omitted, time: .shortened)) · \(EventStyle.text(e)) · click to see it in Time Machine")
                .position(x: CGFloat(f) * g.size.width, y: g.size.height / 2)
            }
        }
    }
}

// MARK: Normal day

private struct NormalDay: View {
    let items: [TodayData.Comparison]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Compared with a normal day").font(.headlineV).foregroundStyle(Theme.text)
                Text("average of the last \(items.first?.days ?? 0) recorded days").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title).font(.calloutV).foregroundStyle(Theme.textSecondary)
                        Text(c.value).font(.numericL).foregroundStyle(Theme.text)
                        Text(line(c)).font(.captionV).foregroundStyle(tone(c))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
                    .staggeredAppear(i)
                }
            }
        }
    }

    private func line(_ c: TodayData.Comparison) -> String {
        guard let r = c.ratio else { return "normally \(c.normal)" }
        if r > 1.15 { return "\(Fmt.percent(r - 1)) above a normal \(c.normal)" }
        if r < 0.87 { return "\(Fmt.percent(1 - r)) below a normal \(c.normal)" }
        return "about normal (\(c.normal))"
    }

    private func tone(_ c: TodayData.Comparison) -> Color {
        guard let r = c.ratio else { return Theme.textTertiary }
        return r > 1.5 ? Theme.orange : Theme.textTertiary
    }
}

// MARK: What stood out

private struct StandoutList: View {
    let data: TodayData
    @Environment(CleanupModel.self) private var cleanup
    @Environment(Navigation.self) private var nav
    @State private var restarting: String?
    @State private var restartError: String?

    private var items: [Standout] {
        var list = data.standouts
        let ready = cleanup.defaultReclaimable
        if data.isToday, ready >= 5_000_000_000 {
            list.append(Standout(id: "cleanup", symbol: "internaldrive", tone: .neutral, title: "\(Fmt.bytes(ready)) of developer files can go",
                                 detail: "Build products and caches that tools make again. Nothing moves until you confirm.", actions: [.reviewCleanup]))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What stood out").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 10)
            Hairline()
            if items.isEmpty {
                Text("Nothing yet. Heavy CPU, memory that keeps growing, big disk writes and apps keeping the Mac awake show up here.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 14)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemName: s.symbol, color: s.tone.color, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.headlineV).foregroundStyle(Theme.text)
                        Text(s.detail).font(.calloutV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if !s.actions.isEmpty {
                            HStack(spacing: 14) {
                                ForEach(s.actions, id: \.self) { a in
                                    Button(label(a)) { run(a) }.buttonStyle(.link).font(.calloutV)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                    if let b = s.badge { Badge(b, tone: .orange) }
                }
                .padding(.vertical, 14)
                .staggeredAppear(i)
                Hairline()
            }
        }
        .confirmationDialog("Restart \(restarting ?? "the app")?", isPresented: Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } })) {
            Button("Quit and Reopen") {
                guard let name = restarting else { return }
                Task { restartError = await AppRestarter.restart(name: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vardis asks the app to quit, the way ⌘Q does, then opens it again. Unsaved work is up to the app; most ask first.")
        }
        .alert("Could not restart", isPresented: Binding(get: { restartError != nil }, set: { if !$0 { restartError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(restartError ?? "") }
    }

    private func label(_ a: StandoutAction) -> String {
        switch a {
        case .showMoment: "Show in Time Machine"
        case .restartApp: "Restart app…"
        case .reviewCleanup: "Review cleanup"
        }
    }

    private func run(_ a: StandoutAction) {
        switch a {
        case .showMoment(let d):
            TimeMachineFocus.shared.open(at: d)
            nav.screen = .timeMachine
        case .restartApp(let name):
            restarting = name
        case .reviewCleanup:
            NotificationCenter.default.post(name: .vardisOpenDiskCleanup, object: nil)
            nav.screen = .diskCleanup
        }
    }
}

/// Quits an app politely and opens it again. Only after the person confirmed.
@MainActor
enum AppRestarter {
    /// Returns an error message, or nil when the app came back.
    static func restart(name: String) async -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name && $0.activationPolicy == .regular }),
              let url = app.bundleURL
        else { return "\(name) is not running as an app Vardis can reopen." }
        guard app.terminate() else { return "\(name) did not accept the request to quit." }
        for _ in 0..<50 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(200)) }
        guard app.isTerminated else { return "\(name) has not quit yet; it may be asking you something. Nothing was forced." }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return "\(name) quit but did not open again: \(error.localizedDescription)"
        }
    }
}

// MARK: What you actually used

private struct UsageSection: View {
    let data: TodayData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What you actually used").font(.headlineV).foregroundStyle(Theme.text)
            Text("Time each app was in front, and apps that drew energy while you were elsewhere").font(.captionV).foregroundStyle(Theme.textTertiary)
                .padding(.top, 2).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("In front").font(.captionStrongV).foregroundStyle(Theme.textTertiary).padding(.bottom, 6)
                    Hairline()
                    if data.foreground.isEmpty {
                        Text("Fills in as you switch between apps.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 10)
                    }
                    let top = data.foreground.first?.seconds ?? 1
                    ForEach(Array(data.foreground.enumerated()), id: \.element.id) { i, a in
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                AppIconView(bundleURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleID), name: a.name, size: 18)
                                Text(a.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                Text(Fmt.duration(a.seconds)).font(.numeric).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(height: 30)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 1).fill(Theme.Metric.cpu.opacity(0.5))
                                    .frame(width: g.size.width * CGFloat(a.seconds / top), height: 2)
                            }
                            .frame(height: 2)
                            .padding(.bottom, 4)
                        }
                        .staggeredAppear(i)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mostly in the background").font(.captionStrongV).foregroundStyle(Theme.textTertiary).padding(.bottom, 6)
                    Hairline()
                    if data.background.isEmpty {
                        Text("No app drew much energy without being used.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 10)
                    }
                    ForEach(Array(data.background.enumerated()), id: \.element.id) { i, a in
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text(a.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                Text("\(Fmt.percent(a.energyShare)) of energy").font(.numeric).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(height: 30)
                            Text(a.foreground < 60 ? "Never in front today" : "In front for \(Fmt.duration(a.foreground))")
                                .font(.captionV).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                            Hairline()
                        }
                        .staggeredAppear(i)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Battery

private struct BatterySessions: View {
    let sessions: [TodayData.BatterySession]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("On battery").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 10)
            Hairline()
            ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(s.start.formatted(date: .omitted, time: .shortened))–\(s.ongoing ? "now" : s.end.formatted(date: .omitted, time: .shortened))")
                        .font(.numeric).foregroundStyle(Theme.text).frame(width: 120, alignment: .leading)
                    Text(Fmt.duration(s.end.timeIntervalSince(s.start))).font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .leading)
                    Text(s.used.map { "\(Fmt.percent($0)) used" } ?? "").font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .leading)
                    Text(s.topApps.isEmpty ? "" : "Most energy: " + s.topApps.joined(separator: ", "))
                        .font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Spacer()
                }
                .frame(height: 32)
                .staggeredAppear(i)
                Hairline()
            }
        }
    }
}

// MARK: Footer

private struct SummaryToggle: View {
    @Environment(HistoryModel.self) private var history

    var body: some View {
        @Bindable var h = history
        Toggle(isOn: $h.summaryNotification) {
            Text("Send me a one-line summary of the day at 21:00").font(.calloutV).foregroundStyle(Theme.textSecondary)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: Right now

private struct RightNowRail: View {
    @Environment(LiveModel.self) private var live
    @Environment(CleanupModel.self) private var cleanup
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Right now").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 14)
                if let s = live.snapshot {
                    let byCPU = s.apps.sorted { $0.cpu > $1.cpu }.prefix(2)
                    RailRow(title: "CPU", value: Fmt.percent(s.cpu.total), fraction: s.cpu.total, color: Theme.Metric.cpu,
                            caption: byCPU.map { "\($0.name) \(Fmt.percent($0.cpu))" }.joined(separator: " · "))
                    RailRow(title: "Memory", value: Fmt.bytes(s.memory.used),
                            fraction: s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0, color: Theme.Metric.memory,
                            caption: "of \(Fmt.bytes(s.memory.total)) · pressure \(s.memory.pressure.rawValue) · swap \(Fmt.bytes(s.memory.swapUsed))")
                    RailRow(title: "Disk", value: "\(Fmt.bytes(s.disk.freeBytes)) free",
                            fraction: s.disk.totalBytes > 0 ? 1 - Double(s.disk.freeBytes) / Double(s.disk.totalBytes) : 0, color: Theme.Metric.disk,
                            caption: cleanup.totalBytes > 0 ? "\(Fmt.bytes(cleanup.selectedBytes)) ready in Disk Cleanup" : "Writing \(Fmt.rate(s.disk.writeBytesPerSecond))")
                    if let b = s.battery {
                        RailRow(title: "Battery", value: Fmt.percent(b.charge), fraction: b.charge, color: Theme.Metric.battery,
                                caption: [b.isCharging ? "Charging" : (b.onBattery ? "On battery" : "On power adapter"),
                                          b.cycleCount.map { "\($0) cycles" }, b.health.map { "\(Fmt.percent($0)) health" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    RailRow(title: "Network", value: "↓ \(Fmt.rate(s.network.receivedBytesPerSecond))", fraction: nil, color: Theme.Metric.network,
                            caption: "↑ \(Fmt.rate(s.network.sentBytesPerSecond)) · \(Fmt.bytes(s.network.receivedTotal)) received since boot")
                }
                if let today = claude.monthDays.first(where: { Calendar.current.isDateInToday($0.start) }), total(today.tokens) > 0 {
                    RailRow(title: "Claude Code today", value: Self.tokens(total(today.tokens)), fraction: nil, color: Theme.claude,
                            caption: "tokens, \(Self.tokens(today.tokens.output)) of them written · about \(today.costUSD.formatted(.currency(code: "USD"))) at API prices")
                }
            }
            .padding(.horizontal, 22).padding(.top, 30)
        }
    }

    private func total(_ t: TokenUsage) -> Int { t.input + t.output + t.cacheCreation + t.cacheRead }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1e3) }
        return "\(n)"
    }
}

private struct RailRow: View {
    let title: String
    let value: String
    let fraction: Double?
    let color: Color
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.calloutV).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).font(.numericL).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .motion(Motion.value, value: value)
            }
            if let fraction { Meter(value: fraction, color: color) }
            Text(caption).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(2)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Hairline() }
    }
}
