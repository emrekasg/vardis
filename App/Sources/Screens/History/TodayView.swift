import SwiftUI
import VardisCore
import VardisStore

struct TodayView: View {
    @Environment(HistoryModel.self) private var history

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.calloutV).foregroundStyle(Theme.textTertiary)
                        .padding(.bottom, 6)
                    if let t = history.today {
                        Text(t.summary)
                            .font(.largeTitleV).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .motion(Motion.screen, value: t.summary)
                        if let note = t.note {
                            Text(note).font(.bodyV).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                        }
                        TodayChart(data: t)
                            .padding(.top, 26)
                        StandoutList(items: t.standouts)
                            .padding(.top, 30)
                    } else {
                        Text("Vardis is recording. Today fills in as the day goes on.")
                            .font(.largeTitleV).foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.separator).frame(width: 1)
            RightNowRail()
                .frame(width: 300)
        }
        .background(Theme.window)
        .task {
            // Fresh numbers while the screen is visible; what is on screen stays until they land.
            while !Task.isCancelled {
                await history.refreshToday()
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
            }
        }
    }
}

// MARK: Chart

private struct TodayChart: View {
    let data: TodayData
    @State private var hoverX: CGFloat?

    static let palette: [Color] = [Theme.Metric.cpu, Theme.Metric.memory, Theme.Metric.network]
    static let rest = Theme.textTertiary.opacity(0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in
                let size = g.size
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { ctx, size in draw(ctx, size) }
                    if let x = hoverX, let (i, b) = bucket(at: x, width: size.width) {
                        Rectangle().fill(Theme.text.opacity(0.7)).frame(width: 1, height: size.height).offset(x: x)
                        Tooltip(time: data.dayStart.addingTimeInterval(Double(i) * TodayData.bucket), bucket: b)
                            .fixedSize()
                            .offset(x: min(x + 10, size.width - 250), y: 4)
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
            .frame(height: 210)
            EventDots(data: data).frame(height: 18).padding(.top, 6)
            HStack(spacing: 0) {
                ForEach(0..<7) { i in
                    Text(String(format: "%02d:00", i * 4)).font(.captionV).foregroundStyle(Theme.textTertiary)
                    if i < 6 { Spacer() }
                }
            }
            .padding(.top, 4)
            HStack(spacing: 16) {
                ForEach(Array(data.top.enumerated()), id: \.offset) { i, a in legend(Self.palette[i], a.name) }
                legend(Self.rest, "Everything else")
                Spacer()
                Text("CPU share by app · events below the axis").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 16)
        }
    }

    private func legend(_ c: Color, _ name: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(name).font(.calloutV).foregroundStyle(Theme.textSecondary)
        }
    }

    private var scale: Double { max(0.25, (data.buckets.compactMap { $0?.total }.max() ?? 0) * 1.15) }

    private func bucket(at x: CGFloat, width: CGFloat) -> (Int, TodayData.Bucket)? {
        let n = data.buckets.count
        let i = Int(x / width * CGFloat(n))
        guard i >= 0, i < n, let b = data.buckets[i] else { return nil }
        return (i, b)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = data.buckets.count
        let step = size.width / CGFloat(n)
        // Grid lines at 1/3 and 2/3 height.
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

        // Layers bottom to top: everything else, then the top apps (largest on top).
        let k = data.top.count
        typealias Layer = (color: Color, value: (TodayData.Bucket) -> Double)
        var layers: [Layer] = [(Self.rest, { b in max(0, b.total - b.apps.reduce(0, +)) })]
        for j in (0..<k).reversed() {
            let value: (TodayData.Bucket) -> Double = { b in b.apps[j] }
            layers.append((Self.palette[j], value))
        }
        let s = scale
        func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1, v / s)) * size.height }

        // Contiguous runs of recorded buckets.
        var runs: [[Int]] = []
        var cur: [Int] = []
        for i in 0..<n {
            if data.buckets[i] != nil { cur.append(i) } else if !cur.isEmpty { runs.append(cur); cur = [] }
        }
        if !cur.isEmpty { runs.append(cur) }

        for run in runs {
            var lower = run.map { _ in 0.0 }
            for (color, value) in layers {
                let upper = zip(run, lower).map { i, lo in lo + value(data.buckets[i]!) }
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

private struct Tooltip: View {
    let time: Date
    let bucket: TodayData.Bucket

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(time.formatted(date: .omitted, time: .shortened))\(bucket.topApp.map { " · \($0)" } ?? "")")
                .font(.headlineV).foregroundStyle(Theme.text)
            Text("CPU \(Fmt.percent(bucket.total))\(bucket.topApp.map { " · \($0) \(Fmt.percent(bucket.topAppCPU))" } ?? "")")
                .font(.calloutV).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}

private struct EventDots: View {
    let data: TodayData

    var body: some View {
        GeometryReader { g in
            let events = data.events.filter(EventStyle.isNotable)
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                let f = e.timestamp.timeIntervalSince(data.dayStart) / 86_400
                Circle().fill(EventStyle.color(e))
                    .frame(width: 7, height: 7)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .help("\(e.timestamp.formatted(date: .omitted, time: .shortened)) · \(EventStyle.text(e))")
                    .position(x: CGFloat(f) * g.size.width, y: g.size.height / 2)
            }
        }
    }
}

// MARK: What stood out

private struct StandoutList: View {
    let items: [Standout]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What stood out").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 10)
            Hairline()
            if items.isEmpty {
                Text("Nothing yet. Heavy CPU, memory that keeps growing, big disk writes and apps keeping the Mac awake show up here.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 14)
            }
            ForEach(items) { s in
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemName: s.symbol, color: s.tone.color, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.headlineV).foregroundStyle(Theme.text)
                        Text(s.detail).font(.calloutV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let b = s.badge { Badge(b, tone: .orange) }
                }
                .padding(.vertical, 14)
                Hairline()
            }
        }
    }
}

// MARK: Right now

private struct RightNowRail: View {
    @Environment(LiveModel.self) private var live
    @Environment(CleanupModel.self) private var cleanup

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
            }
            .padding(.horizontal, 22).padding(.top, 30)
        }
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
