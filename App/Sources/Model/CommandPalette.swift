import Foundation
import VardisClaude
import VardisCore

/// What a palette row does when chosen.
enum PaletteTarget: Equatable {
    case screen(Screen)
    case app(id: String)
    case session(id: String)
    case action(PaletteAction)
}

enum PaletteAction: String, CaseIterable {
    case rescanDisk, openSettings, togglePause, toggleAppearance, quit
}

enum PaletteSection: Int, CaseIterable, Comparable {
    case screens, apps, sessions, actions

    var title: String {
        switch self {
        case .screens: "Screens"
        case .apps: "Apps"
        case .sessions: "Claude sessions"
        case .actions: "Actions"
        }
    }

    /// Most rows shown per section, so a keystroke never lays out hundreds of rows.
    var cap: Int {
        switch self {
        case .screens: 11
        case .apps: 5
        case .sessions: 6
        case .actions: 5
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct PaletteEntry: Identifiable, Equatable {
    let id: String
    let section: PaletteSection
    let title: String
    let subtitle: String?
    let symbol: String?
    let bundleURL: URL?
    let shortcut: String?
    let target: PaletteTarget
    /// Lowercased title, built once when the palette opens.
    let key: String
    /// Indices in `key` where a word starts.
    let wordStarts: [String.Index]

    init(id: String, section: PaletteSection, title: String, subtitle: String? = nil, symbol: String? = nil,
         bundleURL: URL? = nil, shortcut: String? = nil, target: PaletteTarget) {
        self.id = id
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.bundleURL = bundleURL
        self.shortcut = shortcut
        self.target = target
        let k = title.lowercased()
        key = k
        var starts: [String.Index] = []
        var prev: Character = " "
        for i in k.indices {
            let c = k[i]
            if !prev.isLetter && !prev.isNumber && (c.isLetter || c.isNumber) { starts.append(i) }
            prev = c
        }
        wordStarts = starts
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.title == b.title && a.subtitle == b.subtitle }
}

/// Matching for the command palette: prefix beats word start beats substring beats letters in order.
enum PaletteMatcher {
    static func score(_ e: PaletteEntry, _ q: String) -> Int? {
        if q.isEmpty { return 0 }
        let k = e.key
        if k.hasPrefix(q) { return 4000 - k.count }
        for i in e.wordStarts where k[i...].hasPrefix(q) { return 3000 - k.count }
        if k.contains(q) { return 2000 - k.count }
        // Every word of a multi-word query starts a word, in any order: "chrome goo" finds "Google Chrome".
        let words = q.split(separator: " ")
        if words.count > 1, words.allSatisfy({ w in e.wordStarts.contains { k[$0...].hasPrefix(w) } }) { return 1500 - k.count }
        // Letters in order from a word start ("tmach" finds "Time Machine"), only for short keys so long titles
        // do not match everything.
        if q.count >= 2, k.count <= 40, let first = q.first,
           e.wordStarts.contains(where: { k[$0] == first && isSubsequence(q, of: String(k[$0...])) }) { return 500 - k.count }
        return nil
    }

    private static func isSubsequence(_ q: String, of k: String) -> Bool {
        var it = q.makeIterator()
        var next = it.next()
        for c in k where c == next {
            next = it.next()
            if next == nil { return true }
        }
        return next == nil
    }

    /// Ranked, capped and grouped results. With an empty query: screens and actions only.
    static func results(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var bySection: [PaletteSection: [(Int, PaletteEntry)]] = [:]
        for e in entries {
            if q.isEmpty && (e.section == .apps || e.section == .sessions) { continue }
            guard let s = score(e, q) else { continue }
            bySection[e.section, default: []].append((s, e))
        }
        var out: [PaletteEntry] = []
        for section in PaletteSection.allCases {
            guard var list = bySection[section] else { continue }
            if !q.isEmpty { list.sort { $0.0 > $1.0 } }
            out.append(contentsOf: list.prefix(section.cap).map(\.1))
        }
        return out
    }
}

@MainActor
enum PaletteIndex {
    /// Everything the palette can find, built once per opening from data already in memory.
    static func build(live: LiveModel, claude: ClaudeModel) -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        for (i, s) in Screen.sidebarOrder.enumerated() {
            let title = s.group == "Claude Code" ? "Claude \(s.title)" : s.title
            out.append(PaletteEntry(id: "screen.\(s.rawValue)", section: .screens, title: title, symbol: s.symbol,
                                    shortcut: i < 9 ? "\u{2318}\(i + 1)" : nil, target: .screen(s)))
        }
        for app in live.snapshot?.apps.prefix(600) ?? [] {
            out.append(PaletteEntry(id: "app.\(app.id)", section: .apps, title: app.name,
                                    subtitle: "\(Fmt.bytes(app.memory)), \(app.processCount == 1 ? "1 process" : "\(app.processCount) processes")",
                                    bundleURL: app.bundleURL, target: .app(id: app.id)))
        }
        for s in claude.sessions.prefix(5000) where !s.title.isEmpty {
            out.append(PaletteEntry(id: "session.\(s.id)", section: .sessions, title: s.title,
                                    subtitle: ClaudeModel.projectName(s.projectPath) + ", " + ClaudeFmt.day(s.lastActivityAt),
                                    symbol: "bubble.left", target: .session(id: s.id)))
        }
        let actions: [(PaletteAction, String, String, String?)] = [
            (.rescanDisk, "Rescan disk", "arrow.clockwise", nil),
            (.openSettings, "Open Settings", "gearshape", "\u{2318},"),
            (.togglePause, live.isPaused ? "Resume live updates" : "Pause live updates", live.isPaused ? "play" : "pause", nil),
            (.toggleAppearance, "Toggle appearance", "circle.lefthalf.filled", nil),
            (.quit, "Quit Vardis", "power", "\u{2318}Q"),
        ]
        for (a, title, symbol, shortcut) in actions {
            out.append(PaletteEntry(id: "action.\(a.rawValue)", section: .actions, title: title, symbol: symbol, shortcut: shortcut, target: .action(a)))
        }
        return out
    }
}
