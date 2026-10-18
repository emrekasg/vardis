import SwiftUI
import VardisCore
import VardisStore

struct TimeMachineView: View {
    @Environment(HistoryModel.self) private var history
    @FocusState private var focused: Bool

    private static let step: TimeInterval = 600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let week = history.week, week.recordedFrom != nil {
                    WeekStripView(week: week)
                        .padding(.bottom, 30)
                    if let m = history.moment {
                        MomentView(moment: m)
                    }
                } else {
                    Text("Time Machine fills in as Vardis records.").font(.largeTitleV).foregroundStyle(Theme.text)
                    Text("Every few seconds Vardis notes what the Mac was doing. Come back in an hour to rewind through it.")
                        .font(.bodyV).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                }
            }
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { move(-Self.step); return .handled }
        .onKeyPress(.rightArrow) { move(Self.step); return .handled }
        .onAppear { focused = true }
        .task { await history.refreshWeek() }
    }

    private func move(_ dt: TimeInterval) {
        guard let t = history.selected else { return }
        history.select(t.addingTimeInterval(dt))
    }
}

// MARK: Strip

private struct WeekStripView: View {
    @Environment(HistoryModel.self) private var history
    let week: WeekStrip
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").font(.headlineV).foregroundStyle(Theme.text)
                Text("Hourly peak CPU · orange where memory ran short").font(.captionV).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Drag, or use ← → to step 10 minutes").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { ctx, size in draw(ctx, size) }
                    if let t = history.selected {
                        Playhead(height: g.size.height)
                            .offset(x: x(for: t, width: w) - 7)
                            .animation(dragging ? nil : Motion.travel, value: t)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        history.select(time(at: v.location.x, width: w))
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 72)
            DayAxis(week: week)
        }
    }

    private var span: TimeInterval { max(1, week.end.timeIntervalSince(week.start)) }

    private func x(for t: Date, width: CGFloat) -> CGFloat {
        CGFloat(t.timeIntervalSince(week.start) / span) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Date {
        let f = min(1, max(0, Double(x / max(1, width))))
        let t = week.start.addingTimeInterval(f * span)
        return Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 60).rounded() * 60)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = week.hours.count
        guard n > 0 else { return }
        let step = size.width / CGFloat(n)
        let w = max(1, step - 1)
        let cal = Calendar.current
        for (i, h) in week.hours.enumerated() {
            let x = CGFloat(i) * step
            if cal.component(.hour, from: h.start) == 0, i > 0 {
                var p = Path()
                p.move(to: CGPoint(x: x - 0.5, y: 0))
                p.addLine(to: CGPoint(x: x - 0.5, y: size.height))
                ctx.stroke(p, with: .color(Theme.separator), lineWidth: 1)
            }
            guard let c = h.cpuMax else {
                continue
            }
            let height = max(2, CGFloat(min(1, c)) * (size.height - 4))
            let rect = CGRect(x: x, y: size.height - height, width: w, height: height)
            let short = (h.pressureMax ?? 0) >= 0.5
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(short ? Theme.orange : Theme.Metric.cpu.opacity(0.75)))
        }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: size.height - 0.5))
        base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        ctx.stroke(base, with: .color(Theme.separator), lineWidth: 1)
    }
}

private struct DayAxis: View {
    let week: WeekStrip

    var body: some View {
        GeometryReader { g in
            let span = max(1, week.end.timeIntervalSince(week.start))
            let cal = Calendar.current
            let days = (0...7).compactMap { d -> Date? in
                cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: week.start)).flatMap { $0 > week.start && $0 < week.end ? $0 : nil }
            }
            ForEach(days, id: \.self) { d in
                Text(d.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.captionV).foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                    .position(x: CGFloat(d.timeIntervalSince(week.start) / span) * g.size.width + 3, y: 7)
                    .offset(x: 18)
            }
        }
        .frame(height: 14)
    }
}

private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Theme.text).frame(width: 9, height: 9)
            Rectangle().fill(Theme.text).frame(width: 2, height: max(0, height - 9))
        }
        .frame(width: 14)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

// MARK: Moment

private struct MomentView: View {
    let moment: MomentData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(moment.at.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                .font(.calloutV).foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 6)
            Text(moment.headline)
                .font(.largeTitleV).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.quick, value: moment.headline)
            Text(moment.detail).font(.bodyV).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if moment.cause != .noData {
                HStack(alignment: .top, spacing: 32) {
                    AppsAtMoment(moment: moment).frame(maxWidth: .infinity)
                    MomentStats(values: moment.values).frame(width: 260)
                }
                .padding(.top, 28)
            }
            AroundIt(moment: moment).padding(.top, 30)
        }
    }
}

private struct AppsAtMoment: View {
    let moment: MomentData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("At \(moment.at.formatted(date: .omitted, time: .shortened))").font(.headlineV).foregroundStyle(Theme.text)
                Spacer()
                Text("Memory").frame(width: 90, alignment: .trailing)
                Text("CPU").frame(width: 70, alignment: .trailing)
            }
            .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 8)
            Hairline()
            if moment.apps.isEmpty {
                Text("No app details were kept for this moment.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 10)
            }
            ForEach(moment.apps, id: \.appID) { a in
                HStack {
                    Text(a.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(a.memory)).font(.numeric).foregroundStyle(moment.cause == .memory ? Theme.text : Theme.textSecondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(Fmt.percent(a.cpu)).font(.numeric).foregroundStyle(moment.cause == .cpu ? Theme.text : Theme.textSecondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .frame(height: 30)
                Hairline()
            }
        }
    }
}

private struct MomentStats: View {
    let values: [Metric: Double]

    var body: some View {
        let pressure = values[.pressure] ?? 0
        VStack(alignment: .leading, spacing: 0) {
            Text("Memory").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 8)
            Hairline()
            stat("Pressure", pressure >= 1 ? "Critical" : (pressure >= 0.5 ? "Warning" : "Normal"),
                 tone: pressure >= 1 ? Theme.red : (pressure >= 0.5 ? Theme.orange : Theme.green))
            stat("Swap used", Fmt.bytes(UInt64(max(0, values[.swap] ?? 0))))
            stat("Compressed", Fmt.bytes(UInt64(max(0, values[.compressed] ?? 0))))
            stat("In use", Fmt.bytes(UInt64(max(0, values[.memoryUsed] ?? 0))))
            stat("CPU", Fmt.percent(values[.cpu] ?? 0))
            stat("Disk writes", Fmt.rate(values[.diskWrite] ?? 0))
        }
    }

    private func stat(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.calloutV).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).font(.numeric).foregroundStyle(tone ?? Theme.text)
            }
            .frame(height: 30)
            Hairline()
        }
    }
}

private struct AroundIt: View {
    let moment: MomentData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What happened around it").font(.headlineV).foregroundStyle(Theme.text)
            Text("15 minutes either side").font(.captionV).foregroundStyle(Theme.textTertiary).padding(.top, 2).padding(.bottom, 8)
            Hairline()
            if moment.events.isEmpty {
                Text("No launches, quits, sleeps or warnings in this window.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 10)
            }
            ForEach(Array(moment.events.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 12) {
                    Text(e.timestamp.formatted(date: .omitted, time: .shortened)).font(.numeric).foregroundStyle(Theme.textTertiary)
                        .frame(width: 54, alignment: .leading)
                    Image(systemName: EventStyle.symbol(e)).font(.system(size: 12)).foregroundStyle(EventStyle.color(e)).frame(width: 16)
                    Text(EventStyle.text(e)).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    let dt = e.timestamp.timeIntervalSince(moment.at)
                    Text(abs(dt) < 60 ? "at this moment" : "\(Int(abs(dt) / 60)) min \(dt < 0 ? "before" : "after")")
                        .font(.captionV).foregroundStyle(Theme.textTertiary)
                }
                .frame(height: 30)
                Hairline()
            }
        }
    }
}
