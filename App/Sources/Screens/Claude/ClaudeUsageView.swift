import SwiftUI
import VardisClaude
import VardisCore

struct ClaudeUsageView: View {
    @Environment(ClaudeModel.self) private var claude
    @AppStorage(Pref.claudeAPICost) private var showCost = true

    private var monthTokens: TokenUsage { claude.monthDays.reduce(.zero) { $0 + $1.tokens } }
    private var monthCost: Double { claude.monthDays.reduce(0) { $0 + $1.costUSD } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                DailyBars(days: claude.monthDays)
                legend
                HStack(alignment: .top, spacing: 40) {
                    projectTable.frame(maxWidth: .infinity)
                    modelTable.frame(maxWidth: .infinity)
                    if claude.accounts.count > 1 || claude.monthHomes.count > 1 { accountTable.frame(maxWidth: .infinity) }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
        }
        .background(Theme.window)
        .claudePresence("claude.usage")
    }

    // MARK: Headline + stats

    private var headline: some View {
        let t = monthTokens
        let prompt = t.input + t.cacheCreation + t.cacheRead
        let hit = prompt > 0 ? Double(t.cacheRead) / Double(prompt) : 0
        let activeDays = claude.monthDays.filter { !$0.tokens.isZero }.count
        let monthSessions = claude.monthProjects.reduce(0) { $0 + $1.sessions }
        let busiest = claude.monthHours.max { $0.tokens.total < $1.tokens.total }
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(Date().formatted(.dateTime.month(.wide))) so far \u{00B7} all accounts").font(.calloutV).foregroundStyle(Theme.textTertiary)
                    IndexingLine()
                }
                Text(showCost ? ClaudeFmt.usd(monthCost) : ClaudeFmt.tokens(t.total)).font(.system(size: 34, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text)
                    .contentTransition(.numericText()).motion(Motion.quick, value: monthCost)
                Text(valueLine).font(.calloutV).foregroundStyle(Theme.textSecondary)
            }
            .frame(minWidth: 380, alignment: .leading)
            ClaudeStat(label: "Tokens", value: ClaudeFmt.tokens(t.total), caption: "\(activeDays) \(activeDays == 1 ? "day" : "days")")
            ClaudeStat(label: "Sessions", value: "\(monthSessions)",
                       caption: activeDays > 0 ? String(format: "%.1f per day", Double(monthSessions) / Double(activeDays)) : nil)
            ClaudeStat(label: "Cache hit", value: Fmt.percent(hit), caption: cacheSaved.map { "saved \(ClaudeFmt.usd($0))" })
            ClaudeStat(label: "Busiest", value: busiest.map { ClaudeFmt.weekdayTime($0.start) } ?? "–",
                       caption: busiest.map { "\(ClaudeFmt.tokens($0.tokens.total)) tokens in 1 hour" })
        }
    }

    private var valueLine: String {
        guard showCost else { return "Tokens this month" }
        var s = "API-equivalent value"
        if let plan = claude.activeAccount?.plan, let price = Self.planPrice(plan), monthCost > 0 {
            s += String(format: " \u{00B7} %.1f\u{00D7} the $%d you pay for %@", monthCost / Double(price), price, plan)
        }
        return s
    }

    /// Monthly list price of a plan, for the "N× what you pay" line.
    static func planPrice(_ plan: String) -> Int? {
        if plan.hasPrefix("Max 20") { return 200 }
        if plan.hasPrefix("Max 5") || plan == "Max" { return 100 }
        if plan == "Pro" { return 20 }
        return nil
    }

    /// What cache reads saved against paying full input price, per model.
    private var cacheSaved: Double? {
        let saved = claude.monthModels.reduce(0.0) { sum, m in
            guard let p = Pricing.bundled.price(for: m.model).0 else { return sum }
            return sum + Double(m.tokens.cacheRead) * (p.input - p.cacheRead) / 1_000_000
        }
        return saved > 0 ? saved : nil
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(DailyBars.series, id: \.0) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.1).frame(width: 8, height: 8)
                    Text(s.0).font(.captionV).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Text("Read from Claude Code\u{2019}s session files on this Mac \u{00B7} bundled API prices").font(.captionV).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Tables

    private var projectTable: some View {
        let rows = claude.monthProjects
        let top = Array(rows.prefix(6))
        let rest = rows.dropFirst(6)
        let maxTokens = Double(rows.map(\.tokens.total).max() ?? 1)
        var display = top.map { UsageRow(id: $0.projectPath, title: ClaudeModel.projectName($0.projectPath), subtitle: "\($0.sessions) \($0.sessions == 1 ? "session" : "sessions")",
                                         tokens: $0.tokens.total, cost: $0.costUSD, color: Theme.accent) }
        if !rest.isEmpty {
            display.append(UsageRow(id: "more", title: "\(rest.count) more", subtitle: "\(rest.reduce(0) { $0 + $1.sessions }) sessions",
                                    tokens: rest.reduce(0) { $0 + $1.tokens.total }, cost: rest.reduce(0) { $0 + $1.costUSD }, color: Theme.accent))
        }
        return UsageTable(title: "By project", rows: display, maxTokens: maxTokens, showCost: showCost)
    }

    private var modelTable: some View {
        let rows = claude.monthModels.filter { $0.tokens.total > 0 }
        let maxTokens = Double(rows.map(\.tokens.total).max() ?? 1)
        return UsageTable(title: "By model", rows: rows.map { m in
            let window = ContextWindow.size(model: m.model) >= ContextWindow.extended ? "1M context" : "\(m.messages.formatted()) messages"
            return UsageRow(id: m.model, title: ContextWindow.displayName(m.model), subtitle: m.isPriced ? window : "not priced",
                            tokens: m.tokens.total, cost: m.costUSD, color: Theme.claude)
        }, maxTokens: maxTokens, showCost: showCost)
    }

    private var accountTable: some View {
        let rows = claude.monthHomes
        let maxTokens = Double(rows.map(\.tokens.total).max() ?? 1)
        return UsageTable(title: "By account", rows: rows.map { h in
            let a = claude.accounts.first { $0.id == h.home }
            return UsageRow(id: h.home, title: a?.name ?? ClaudeHome(url: URL(fileURLWithPath: h.home)).label,
                            subtitle: a?.plan ?? "\(h.sessions) sessions", tokens: h.tokens.total, cost: h.costUSD, color: Theme.textSecondary)
        }, maxTokens: maxTokens, showCost: showCost)
    }
}

private struct UsageRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tokens: Int
    let cost: Double
    let color: Color
}

private struct UsageTable: View {
    let title: String
    let rows: [UsageRow]
    let maxTokens: Double
    let showCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, trailing: showCost ? "Tokens \u{00B7} Cost" : "Tokens").padding(.bottom, 8)
            Hairline()
            if rows.isEmpty { Text("Nothing this month").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 12) }
            ForEach(rows) { r in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                        Text(r.subtitle).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Meter(value: maxTokens > 0 ? Double(r.tokens) / maxTokens : 0, color: r.color).frame(width: 64)
                    Text(ClaudeFmt.tokens(r.tokens)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
                    if showCost { Text(ClaudeFmt.usd(r.cost)).font(.numeric).foregroundStyle(Theme.text).frame(width: 72, alignment: .trailing) }
                }
                .padding(.vertical, 10)
                Hairline()
            }
        }
    }
}

/// Stacked daily bars for the current month (output on top, input, cache read at the base), drawn in one Canvas.
/// Hovering a bar shows that day's numbers.
struct DailyBars: View {
    let days: [UsageBucket]
    @State private var hover: Int?

    static let series: [(String, Color)] = [("Output", Theme.claude), ("Input", Theme.accent), ("Cache read", Theme.accent.opacity(0.35))]

    private var month: [Date] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return [] }
        var out: [Date] = []
        var d = interval.start
        while d < interval.end { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d) ?? interval.end }
        return out
    }

    var body: some View {
        let dates = month
        let byDay = Dictionary(days.map { (Calendar.current.startOfDay(for: $0.start), $0) }, uniquingKeysWith: { a, _ in a })
        let values = dates.map { byDay[$0] }
        let top = Double(values.compactMap { $0.map(Self.height) }.max() ?? 1)
        VStack(spacing: 6) {
            GeometryReader { g in
                let step = g.size.width / CGFloat(max(1, dates.count))
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        let w = max(3, step * 0.72)
                        for frac in [0.5, 1.0] {
                            var p = Path()
                            let y = size.height * (1 - frac) + 0.5
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(p, with: .color(Theme.separator), lineWidth: 1)
                        }
                        for (i, b) in values.enumerated() {
                            let x = CGFloat(i) * step + (step - w) / 2
                            guard let b, top > 0 else {
                                ctx.fill(Path(CGRect(x: x, y: size.height - 1, width: w, height: 1)), with: .color(Theme.separator))
                                continue
                            }
                            let dim = hover != nil && hover != i
                            var y = size.height
                            let parts: [(Int, Color)] = [(b.tokens.cacheRead, Self.series[2].1), (b.tokens.input + b.tokens.cacheCreation, Self.series[1].1), (b.tokens.output, Self.series[0].1)]
                            for (n, color) in parts where n > 0 {
                                let h = max(1, size.height * CGFloat(Double(n) / top))
                                y -= h
                                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color.opacity(dim ? 0.45 : 1)))
                            }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let i = Int(p.x / step)
                            hover = (0..<dates.count).contains(i) && values[i] != nil ? i : nil
                        case .ended: hover = nil
                        }
                    }
                    if let i = hover, let b = values[i] {
                        tooltip(dates[i], b)
                            .fixedSize()
                            .offset(x: min(max(0, CGFloat(i) * step - 60), g.size.width - 220), y: -8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .motion(Motion.quick, value: hover)
            }
            .frame(height: 180)
            HStack {
                ForEach(Array(dates.enumerated()).filter { $0.offset % 5 == 0 || $0.offset == dates.count - 1 }, id: \.offset) { i, d in
                    Text(ClaudeFmt.day(d)).font(.captionV).foregroundStyle(Theme.textTertiary)
                    if i != dates.count - 1 { Spacer() }
                }
            }
        }
    }

    private static func height(_ b: UsageBucket) -> Int { b.tokens.output + b.tokens.input + b.tokens.cacheCreation + b.tokens.cacheRead }

    private func tooltip(_ day: Date, _ b: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.captionStrongV).foregroundStyle(Theme.text)
            Text("\(ClaudeFmt.tokens(b.tokens.total)) tokens \u{00B7} \(ClaudeFmt.usd(b.costUSD))").font(.captionV).foregroundStyle(Theme.textSecondary)
            Text("\(ClaudeFmt.tokens(b.tokens.output)) out \u{00B7} \(ClaudeFmt.tokens(b.tokens.input + b.tokens.cacheCreation)) in \u{00B7} \(ClaudeFmt.tokens(b.tokens.cacheRead)) cache read")
                .font(.captionV).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
