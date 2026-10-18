import AppKit
import SwiftUI
import VardisClaude
import VardisCore

struct ClaudeSessionsView: View {
    @Environment(ClaudeModel.self) private var claude
    @AppStorage(Pref.claudeGroupBy) private var groupBy = "project"
    @State private var query = ""
    @State private var hits: [SessionHit]?
    @State private var selection: String?
    @State private var project: String?
    @State private var account: String?

    /// Topic grouping is not offered: there is no reliable topic signal in transcripts yet. "topic" falls back to project.
    private var grouping: String { groupBy == "date" ? "date" : "project" }

    private var filtered: [ClaudeSession] {
        let base: [ClaudeSession]
        if let hits {
            let byID = Dictionary(claude.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            base = hits.compactMap { byID[$0.sessionID] }
        } else {
            base = claude.sessions
        }
        return base.filter { s in
            (project == nil || s.projectPath == project) && (account == nil || s.home == account)
        }
    }

    private var groups: [(key: String, sessions: [ClaudeSession])] {
        let list = filtered
        if grouping == "date" {
            var order: [String] = []
            var map: [String: [ClaudeSession]] = [:]
            for s in list {
                let k = Self.dateGroup(s.lastActivityAt)
                if map[k] == nil { order.append(k) }
                map[k, default: []].append(s)
            }
            return order.map { ($0, map[$0] ?? []) }
        }
        var order: [String] = []
        var map: [String: [ClaudeSession]] = [:]
        for s in list {
            let k = ClaudeModel.projectName(s.projectPath)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(s)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var selected: ClaudeSession? {
        selection.flatMap(claude.session(id:)) ?? filtered.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 420)
            Rectangle().fill(Theme.separator).frame(width: 1)
            Group {
                if let s = selected {
                    SessionReader(session: s, hit: hits?.first { $0.sessionID == s.id }).id(s.id).transition(.opacity)
                } else {
                    ClaudeEmpty(symbol: "bubble.left", title: hits == nil ? "No sessions yet" : "No matches",
                                detail: hits == nil ? "Sessions appear here as soon as Claude Code writes them." : "Try fewer or different words.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.quick, value: selected?.id)
        }
        .background(Theme.window)
        .claudePresence("claude.sessions")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { hits = nil; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await claude.search(q)
            guard !Task.isCancelled else { return }
            hits = found
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search sessions", text: $query).textFieldStyle(.plain).font(.bodyV)
                if let hits { Text("\(hits.count) \(hits.count == 1 ? "match" : "matches")").font(.captionV).foregroundStyle(Theme.textTertiary) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator))
            HStack(spacing: 8) {
                Menu {
                    Button("Project") { groupBy = "project" }
                    Button("Date") { groupBy = "date" }
                } label: { Text("Group: \(grouping == "date" ? "Date" : "Project")") }
                    .menuStyle(.button).fixedSize()
                Menu {
                    Button("All projects") { project = nil }
                    Divider()
                    ForEach(projects, id: \.self) { p in Button(ClaudeModel.projectName(p)) { project = p } }
                } label: { Text(project.map { ClaudeModel.projectName($0) } ?? "All projects").lineLimit(1) }
                    .menuStyle(.button).fixedSize()
                if claude.accounts.count > 1 {
                    Menu {
                        Button("All accounts") { account = nil }
                        Divider()
                        ForEach(claude.accounts) { a in Button(a.name) { account = a.id } }
                    } label: { Text(account.flatMap { id in claude.accounts.first { $0.id == id }?.name } ?? "All accounts") }
                        .menuStyle(.button).fixedSize()
                }
                Spacer()
            }
            .controlSize(.small)
            IndexingLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(groups, id: \.key) { g in
                        HStack {
                            Image(systemName: grouping == "date" ? "calendar" : "folder").font(.system(size: 11)).foregroundStyle(Theme.claude)
                            Text(g.key).font(.headlineV).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text("\(g.sessions.count) \(g.sessions.count == 1 ? "session" : "sessions")").font(.captionV).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 4)
                        ForEach(g.sessions.prefix(hits == nil ? 60 : 200)) { s in
                            SessionRow(session: s, hit: hits?.first { $0.sessionID == s.id }, showProject: grouping == "date", isSelected: s.id == selected?.id)
                                .onTapGesture { selection = s.id }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private var projects: [String] {
        var seen = Set<String>()
        return claude.sessions.compactMap(\.projectPath).filter { seen.insert($0).inserted }
    }

    static func dateGroup(_ d: Date?) -> String {
        guard let d else { return "Undated" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let w = cal.dateInterval(of: .weekOfYear, for: Date()), w.contains(d) { return "Earlier this week" }
        return d.formatted(.dateTime.month(.wide).year())
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let hit: SessionHit?
    let showProject: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title.isEmpty ? "Untitled session" : session.title).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
            if let hit, !hit.snippet.isEmpty {
                Text(Self.highlighted(hit.snippet)).font(.captionV).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Text(meta).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .modifier(HoverHighlight(cornerRadius: 8))
        .contentShape(Rectangle())
        .motion(Motion.quick, value: isSelected)
    }

    private var meta: String {
        var parts: [String] = []
        if showProject { parts.append(ClaudeModel.projectName(session.projectPath)) }
        parts.append(ClaudeFmt.day(session.lastActivityAt))
        parts.append("\(ClaudeFmt.tokens(session.tokens.total)) tokens")
        parts.append(ClaudeFmt.usd(session.costUSD))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Bold for the matched words between the snippet markers.
    static func highlighted(_ snippet: String) -> AttributedString {
        let m = SessionHit.snippetMarkers
        var out = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: m.open) {
            out += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            if let close = rest.range(of: m.close) {
                var bold = AttributedString(String(rest[..<close.lowerBound]))
                bold.font = .captionStrongV
                bold.foregroundColor = Theme.text
                out += bold
                rest = rest[close.upperBound...]
            }
        }
        out += AttributedString(String(rest))
        return out
    }
}

private struct SessionReader: View {
    let session: ClaudeSession
    let hit: SessionHit?
    @Environment(ClaudeModel.self) private var claude
    @State private var turns: [Turn] = []
    @State private var copied = false

    private var files: Int { Set(turns.flatMap(\.filesChanged)).count }
    private var steps: Int { turns.reduce(0) { $0 + $1.steps } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title.isEmpty ? "Untitled session" : session.title).font(.largeTitleV).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                        Text(meta).font(.calloutV).foregroundStyle(Theme.textTertiary)
                    }
                    linked
                    conversation
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 20)
            }
            resumeBar.padding(.horizontal, 40).padding(.bottom, 24).padding(.top, 8)
        }
        .task(id: session.id) { turns = await claude.turns(sessionID: session.id) }
        .task(id: session.lastActivityAt) { turns = await claude.turns(sessionID: session.id) }
    }

    private var meta: String {
        var parts = [ClaudeModel.projectName(session.projectPath)]
        if claude.accounts.count > 1, let a = claude.accounts.first(where: { $0.id == session.home }) { parts.append(a.name) }
        if let start = session.startedAt {
            let end = session.lastActivityAt.map { Calendar.current.isDate($0, inSameDayAs: start) ? ClaudeFmt.time($0) : ClaudeFmt.when($0) } ?? ""
            parts.append(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + ClaudeFmt.time(start) + (end.isEmpty ? "" : "\u{2013}" + end))
        }
        parts.append("\(ClaudeFmt.tokens(session.tokens.total)) tokens")
        parts.append("\(ClaudeFmt.usd(session.costUSD)) API-equivalent")
        return parts.joined(separator: " \u{00B7} ")
    }

    private var linked: some View {
        HStack(alignment: .top, spacing: 36) {
            info("arrow.triangle.branch", "Branch", session.gitBranch ?? "–")
            info("doc.text", "Files changed", "\(files) \(files == 1 ? "file" : "files")")
            info("bubble.left.and.bubble.right", "Turns", "\(turns.count) \u{00B7} \(steps) steps")
            info("cpu", "Model", ContextWindow.displayName(session.model))
            if session.failedToolCalls > 0 { info("exclamationmark.triangle", "Failed tools", "\(session.failedToolCalls) of \(session.toolCalls)") }
            Spacer()
        }
    }

    private func info(_ symbol: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label)
            }
            .font(.captionV).foregroundStyle(Theme.textTertiary)
            Text(value).font(.headlineV).foregroundStyle(Theme.text).lineLimit(1)
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Conversation", trailing: "\(turns.count) turns \u{00B7} \(steps) steps").padding(.bottom, 8)
            Hairline()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(turns, id: \.index) { t in
                    row(who: "You", tone: Theme.textSecondary, text: t.prompt, trailing: nil, trailingTone: Theme.textTertiary)
                    if t.steps > 0 || t.reply != nil {
                        row(who: "Claude", tone: Theme.claude, text: t.reply ?? "Worked without a written reply.", trailing: t.summary,
                            trailingTone: t.failures > 0 ? Theme.red : Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func row(who: String, tone: Color, text: String, trailing: String?, trailingTone: Color) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(who).font(.captionStrongV).foregroundStyle(tone).frame(width: 48, alignment: .leading)
                Text(text).font(.bodyV).foregroundStyle(Theme.text).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 12)
                if let trailing { Text(trailing).font(.captionV).foregroundStyle(trailingTone).lineLimit(1).fixedSize() }
            }
            .padding(.vertical, 11)
            Hairline()
        }
    }

    private var resumeBar: some View {
        let cmd = claude.resumeCommand(for: session)
        let terminal = TerminalLauncher.preferred
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Resume in \(TerminalLauncher.appURL(terminal) == nil ? "Terminal" : terminal)") { TerminalLauncher.run(cmd) }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
    }
}
