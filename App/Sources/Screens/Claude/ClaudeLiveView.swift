import AppKit
import SwiftUI
import VardisClaude
import VardisCore

struct ClaudeLiveView: View {
    @Environment(ClaudeModel.self) private var claude
    @State private var selection: Int32?

    private var selected: LiveSessionInfo? {
        claude.live.first { $0.id == selection } ?? claude.live.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 340)
            Rectangle().fill(Theme.separator).frame(width: 1)
            Group {
                if let s = selected {
                    LiveDetail(info: s).id(s.id).transition(.opacity)
                } else {
                    ClaudeEmpty(symbol: "waveform.path.ecg", title: "No Claude Code sessions running",
                                detail: "Start `claude` in a terminal and it shows up here within a few seconds.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.quick, value: selected?.id)
        }
        .background(Theme.window)
        .claudePresence("claude.live")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(claude.live.count) running").font(.titleV).foregroundStyle(Theme.text)
                Text(subtitle).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                IndexingLine().padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(claude.live) { s in
                        LiveRow(info: s, isSelected: s.id == selected?.id)
                            .onTapGesture { selection = s.id }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(ClaudeFmt.tokens(claude.lastHourTokens)) tokens in the last hour"]
        if let a = claude.activeAccount, claude.accounts.count > 1 { parts.append("\(a.name) account") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Short state text and color, shared with the menu bar.
struct LiveStatusText {
    let text: String
    let color: Color
    let dot: Color

    init(_ s: LiveSessionInfo) {
        switch s.status() {
        case .running(let tool):
            text = tool == "Bash" ? "Running a command" : "Running \(tool)"
            color = Theme.textSecondary; dot = Theme.green
        case .working: text = "Working"; color = Theme.textSecondary; dot = Theme.green
        case .waiting: text = "Waiting for you"; color = Theme.orange; dot = Theme.orange
        case .idle(let age): text = age >= 3600 ? "Idle \(Int(age / 3600)) h \(Int(age.truncatingRemainder(dividingBy: 3600) / 60)) m" : age >= 60 ? "Idle \(Int(age / 60)) m" : "Idle"; color = Theme.textTertiary; dot = Theme.textTertiary
        }
    }
}

private struct LiveRow: View {
    let info: LiveSessionInfo
    let isSelected: Bool

    var body: some View {
        let status = LiveStatusText(info)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(status.dot).frame(width: 7, height: 7)
                Text(info.projectName).font(.headlineV).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(ClaudeFmt.elapsed(since: info.process.startedAt)).font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 4) {
                if let b = info.branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(b).lineLimit(1)
                    Text("\u{00B7}")
                }
                Text(ContextWindow.displayName(info.model))
                if info.activity.contextWindow >= ContextWindow.extended { Text("\u{00B7} 1M") }
            }
            .font(.captionV).foregroundStyle(Theme.textTertiary)
            .padding(.leading, 14)
            HStack(spacing: 8) {
                Text(status.text).font(.captionV).foregroundStyle(status.color).lineLimit(1)
                Spacer()
                Meter(value: info.activity.contextFraction, color: contextColor(info.activity.contextFraction)).frame(width: 60)
                Text(Fmt.percent(info.activity.contextFraction)).font(.captionV).foregroundStyle(Theme.textTertiary).frame(width: 32, alignment: .trailing)
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .modifier(HoverHighlight(cornerRadius: 8))
        .contentShape(Rectangle())
        .motion(Motion.quick, value: isSelected)
    }
}

func contextColor(_ f: Double) -> Color {
    f >= 0.85 ? Theme.red : f >= 0.6 ? Theme.orange : Theme.accent
}

private struct LiveDetail: View {
    let info: LiveSessionInfo
    @Environment(ClaudeModel.self) private var claude
    @State private var focusFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                activityBanner
                stats
                HStack(alignment: .top, spacing: 36) {
                    ActivityFeed(tools: info.activity.tools, cwd: info.process.cwd)
                        .frame(maxWidth: .infinity)
                    ChildProcesses(nodes: info.children)
                        .frame(width: 300)
                }
                ContextChart(points: info.activity.contextSeries, window: info.activity.contextWindow)
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.projectName).font(.largeTitleV).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Text(ClaudeModel.tildePath(info.process.cwd))
                    if let b = info.branch {
                        Text("\u{00B7}")
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(b)
                    }
                    Text("\u{00B7} \(ContextWindow.displayName(info.model)) \u{00B7} pid \(String(info.process.pid)) \u{00B7} started \(ClaudeFmt.time(info.process.startedAt))")
                }
                .font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Open transcript") {
                    if let url = info.process.transcriptURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(info.process.transcriptURL == nil)
                Button(focusFailed ? "Terminal not found" : "Focus terminal") {
                    focusFailed = !claude.focusTerminal(info)
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(claude.terminalName(info).map { "Bring \($0) to the front" } ?? "")
            }
        }
    }

    @ViewBuilder private var activityBanner: some View {
        let status = LiveStatusText(info)
        HStack(spacing: 10) {
            Circle().fill(status.dot).frame(width: 7, height: 7)
            if let t = info.activity.runningTool {
                Text("Running \(t.name)").font(.headlineV).foregroundStyle(Theme.text)
                Text(t.detail).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let start = t.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Fmt.duration(Date().timeIntervalSince(start))).font(.numeric).foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Text(status.text).font(.headlineV).foregroundStyle(Theme.text)
                if let last = info.activity.lastEventAt {
                    Text("last activity \(ClaudeFmt.time(last))").font(.calloutV).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(status.dot.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var stats: some View {
        let a = info.activity
        let t = info.session?.tokens ?? .zero
        let cached = t.cacheRead + t.cacheCreation
        return HStack(alignment: .top, spacing: 20) {
            ClaudeStat(label: "Context", value: Fmt.percent(a.contextFraction),
                       caption: "\(ClaudeFmt.tokens(a.contextTokens)) of \(a.contextWindow >= ContextWindow.extended ? "1M" : ClaudeFmt.tokens(a.contextWindow))",
                       meter: (a.contextFraction, contextColor(a.contextFraction)))
            ClaudeStat(label: "Tokens", value: ClaudeFmt.tokens(t.total),
                       caption: "\(ClaudeFmt.tokens(t.input)) in \u{00B7} \(ClaudeFmt.tokens(t.output)) out \u{00B7} \(ClaudeFmt.tokens(cached)) cached")
            ClaudeStat(label: "Cost", value: info.session.map { ClaudeFmt.usd($0.costUSD) } ?? "–", caption: "API-equivalent")
            ClaudeStat(label: "Tool calls", value: "\(info.session?.toolCalls ?? a.tools.count)",
                       caption: "\(info.session?.failedToolCalls ?? 0) failed \u{00B7} \(a.subagentCalls) subagents")
        }
    }
}

private struct ActivityFeed: View {
    let tools: [ToolActivity]
    let cwd: String

    /// Paths inside the project read relative to it; others start with ~.
    private func shorten(_ detail: String) -> String {
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if detail.hasPrefix(prefix) { return String(detail.dropFirst(prefix.count)) }
        return detail.hasPrefix("/") ? ClaudeModel.tildePath(detail) : detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Activity", trailing: "Live", trailingTone: Theme.green).padding(.bottom, 8)
            Hairline()
            if tools.isEmpty {
                Text("No tool calls yet").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 12)
            }
            ForEach(tools.prefix(12)) { t in
                HStack(spacing: 10) {
                    Text(ClaudeFmt.time(t.startedAt)).font(.numeric).foregroundStyle(Theme.textTertiary).frame(width: 44, alignment: .leading)
                    Image(systemName: Self.symbol(t.name)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14)
                    Text(t.name).font(.headlineV).foregroundStyle(Theme.text).frame(width: 64, alignment: .leading).lineLimit(1)
                    Text(shorten(t.detail)).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if t.isSidechain { Badge("subagent") }
                    switch t.state {
                    case .running: Badge("running", tone: .green)
                    case .failed: Badge("failed", tone: .red)
                    case .ok: EmptyView()
                    }
                }
                .padding(.vertical, 9)
                Hairline()
            }
        }
        .motion(Motion.quick, value: tools.first?.id)
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash": "play.fill"
        case "Read": "doc"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "Task", "Agent": "sparkle"
        case "WebFetch", "WebSearch": "globe"
        case "TodoWrite": "checklist"
        default: name.hasPrefix("mcp__") ? "powerplug" : "wrench.and.screwdriver"
        }
    }
}

private struct ChildProcesses: View {
    let nodes: [ProcessNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Started by this session").padding(.bottom, 8)
            Hairline()
            if nodes.isEmpty {
                Text("Nothing running under this session").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 12)
            }
            ForEach(nodes.prefix(10)) { n in
                HStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14)
                    Text(n.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(n.residentBytes)).font(.numeric).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 9)
                .help("pid \(n.pid)")
                Hairline()
            }
            Text("Vardis never stops anything a session started.").font(.captionV).foregroundStyle(Theme.textTertiary).padding(.top, 8)
        }
    }
}

/// Context size over the session, as an area under a line, with the window's limit as a guide.
private struct ContextChart: View {
    let points: [ContextPoint]
    let window: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Context over this session", trailing: compactions > 0 ? "Compacted \(compactions == 1 ? "once" : "\(compactions) times")" : nil)
            Canvas(rendersAsynchronously: false) { ctx, size in
                guard points.count > 1, let first = points.first?.time, let last = points.last?.time else { return }
                let span = max(1, last.timeIntervalSince(first))
                let top = Double(max(window, points.map(\.tokens).max() ?? 1))
                func pt(_ p: ContextPoint) -> CGPoint {
                    CGPoint(x: size.width * p.time.timeIntervalSince(first) / span, y: size.height * (1 - Double(p.tokens) / top))
                }
                var line = Path()
                for (i, p) in points.enumerated() { i == 0 ? line.move(to: pt(p)) : line.addLine(to: pt(p)) }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Theme.accent.opacity(0.14)))
                ctx.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
                var limit = Path()
                limit.move(to: CGPoint(x: 0, y: 0.5)); limit.addLine(to: CGPoint(x: size.width, y: 0.5))
                ctx.stroke(limit, with: .color(Theme.orange.opacity(0.7)), lineWidth: 1)
            }
            .frame(height: 90)
            HStack {
                Text(ClaudeFmt.time(points.first?.time)).font(.captionV).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(ClaudeFmt.time(points.last?.time)).font(.captionV).foregroundStyle(Theme.textTertiary)
            }
        }
        .opacity(points.count > 1 ? 1 : 0.4)
    }

    /// Drops of more than half the context between two messages.
    private var compactions: Int {
        zip(points, points.dropFirst()).filter { $1.tokens < $0.tokens / 2 && $0.tokens > 50_000 }.count
    }
}
