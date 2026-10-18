import Foundation
import VardisStore

/// Local index of Claude Code transcripts: sessions, usage, turns and full-text search.
///
/// Derived data only; deleting the file rebuilds it. `refresh()` reads only bytes appended since the last run.
public actor ClaudeIndex {
    private let db: Database
    private let homesProvider: @Sendable () -> [ClaudeHome]
    private let pricing: Pricing
    private var files: [String: FileRecord]?

    /// Characters of one message that go into the search index.
    static let ftsTextLimit = 2_000
    static let promptLimit = 2_000
    static let titleLimit = 80

    /// - Parameters:
    ///   - databaseURL: SQLite file. `nil` keeps the index in memory.
    ///   - homes: Config dirs to scan. Defaults to `ClaudeDiscovery.discover()` on every refresh.
    public init(databaseURL: URL?, homes: (@Sendable () -> [ClaudeHome])? = nil, pricing: Pricing = .bundled) throws {
        db = try Database(url: databaseURL)
        try IndexSchema.migrate(db)
        homesProvider = homes ?? { ClaudeDiscovery.discover() }
        self.pricing = pricing
    }

    // MARK: - Refresh

    /// Scans every home and indexes bytes appended since the last refresh. Files are parsed in parallel,
    /// written serially, one transaction per file.
    /// `progress(done, total)` is called after each batch of changed files (from the index's executor).
    @discardableResult
    public func refresh(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> RefreshStats {
        let started = Date()
        var stats = RefreshStats()
        if files == nil { files = (try? loadFiles()) ?? [:] }
        var work: [Job] = []
        for home in homesProvider() {
            let list = TranscriptFiles.list(projects: home.projectsURL)
            stats.filesSeen += list.count
            for f in list {
                let known = files?[f.path]
                if let known, known.size == f.size, known.mtime == f.mtime { continue }
                let truncated = known.map { f.size < $0.offset } ?? false
                work.append(Job(file: f, home: home, known: known, from: truncated ? 0 : (known?.offset ?? 0), truncated: truncated))
            }
        }
        // Main transcripts first so sessions get their project path from the main chain.
        work.sort { !$0.file.isSubagent && $1.file.isSubagent }

        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        if !work.isEmpty { progress?(0, work.count) }
        var i = 0
        while i < work.count {
            let batch = Array(work[i..<min(i + width * 2, work.count)])
            i += batch.count
            let parsed = await withTaskGroup(of: (Int, ParseResult?).self) { group in
                for (n, job) in batch.enumerated() {
                    group.addTask { (n, try? TranscriptParser.parse(url: URL(fileURLWithPath: job.file.path), from: job.from)) }
                }
                var out = [ParseResult?](repeating: nil, count: batch.count)
                for await (n, r) in group { out[n] = r }
                return out
            }
            for (job, result) in zip(batch, parsed) {
                guard let result, let touched = try? store(job, result) else { continue }
                stats.filesChanged += 1
                stats.bytesRead += result.bytesRead
                stats.linesParsed += result.lineCount
                stats.malformedLines += result.malformedLines
                stats.sessionsTouched += touched
            }
            progress?(i, work.count)
        }
        // Large first runs grow the WAL to hundreds of MB; fold it back so the index stays its real size.
        if !work.isEmpty { try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        stats.duration = Date().timeIntervalSince(started)
        return stats
    }

    private struct FileRecord: Sendable { var id: Int64; var offset: UInt64; var size: UInt64; var mtime: Double }

    private struct Job: Sendable {
        var file: TranscriptFile
        var home: ClaudeHome
        var known: FileRecord?
        var from: UInt64
        var truncated: Bool
    }

    private func loadFiles() throws -> [String: FileRecord] {
        var out: [String: FileRecord] = [:]
        try db.prepare("SELECT path, id, offset, size, mtime FROM files").query { r in
            out[r.text(0) ?? ""] = FileRecord(id: r.int(1), offset: UInt64(r.int(2)), size: UInt64(r.int(3)), mtime: r.double(4))
            return true
        }
        return out
    }

    private func store(_ job: Job, _ parsed: ParseResult) throws -> Int {
        let f = job.file
        return try db.transaction {
            let fileID: Int64
            if let known = job.known {
                fileID = known.id
                if job.truncated {
                    try db.prepare("DELETE FROM fts WHERE rowid IN (SELECT rowid FROM fts_meta WHERE file_id = ?1)").run([.int(fileID)])
                    try db.prepare("DELETE FROM fts_meta WHERE file_id = ?1").run([.int(fileID)])
                    try db.prepare("DELETE FROM turns WHERE file_id = ?1").run([.int(fileID)])
                }
            } else {
                try db.prepare("INSERT INTO files(path, home, session_id, offset, size, mtime) VALUES(?1, ?2, ?3, 0, 0, 0)")
                    .run([.text(f.path), .text(job.home.id), .text(f.pathSessionID)])
                fileID = db.lastInsertRowID
            }
            var batch = Batch(fileID: fileID, file: f, home: job.home)
            for (n, e) in parsed.events.enumerated() {
                batch.line = n < parsed.lineRanges.count ? parsed.lineRanges[n] : 0..<0
                try apply(e, to: &batch)
            }
            try flush(&batch)
            try db.prepare("UPDATE files SET offset = ?1, size = ?2, mtime = ?3 WHERE id = ?4")
                .run([.int(Int64(parsed.offset)), .int(Int64(f.size)), .double(f.mtime), .int(fileID)])
            files?[f.path] = FileRecord(id: fileID, offset: parsed.offset, size: f.size, mtime: f.mtime)
            return batch.sessions.count
        }
    }

    // MARK: - Applying events

    private struct SessionState {
        var id: String
        var home: String
        var projectPath: String?
        var slug: String
        var gitBranch: String?
        var title: String?
        var titleKind: Int
        var firstPrompt: String?
        var startedAt: Double?
        var lastActivityAt: Double?
        var userPrompts: Int
        var toolCalls: Int
        var failed: Int
    }

    private struct TurnState {
        var idx: Int
        var fileID: Int64
        var ts: Double?
        var prompt: String
        var steps: Int
        var failures: Int
        var files: [String]
        var reply: String?
        var lastMsg: String?
    }

    private struct PendingUsage {
        var sessionID: String
        var ts: Double
        var model: String
        var usage: TokenUsage
        var sidechain: Bool
    }

    private struct Batch {
        var fileID: Int64
        var file: TranscriptFile
        var home: ClaudeHome
        var sessions: [String: SessionState] = [:]
        var turns: [String: TurnState] = [:]
        var turnLoaded: Set<String> = []
        var usage: [String: PendingUsage] = [:]
        var usageOrder: [String] = []
        /// Byte range of the line being applied.
        var line: Range<UInt64> = 0..<0
    }

    private func session(_ id: String, _ b: inout Batch) throws -> SessionState {
        if let s = b.sessions[id] { return s }
        var found: SessionState?
        try db.prepare("""
            SELECT home, project_path, project_slug, git_branch, title, title_kind, first_prompt, started_at, last_activity_at,
                   user_prompts, tool_calls, failed_tool_calls FROM sessions WHERE id = ?1
            """).query([.text(id)]) { r in
            found = SessionState(id: id, home: r.text(0) ?? b.home.id, projectPath: r.text(1), slug: r.text(2) ?? b.file.slug, gitBranch: r.text(3),
                                 title: r.text(4), titleKind: Int(r.int(5)), firstPrompt: r.text(6),
                                 startedAt: r.isNull(7) ? nil : r.double(7), lastActivityAt: r.isNull(8) ? nil : r.double(8),
                                 userPrompts: Int(r.int(9)), toolCalls: Int(r.int(10)), failed: Int(r.int(11)))
            return true
        }
        let s = found ?? SessionState(id: id, home: b.home.id, projectPath: nil, slug: b.file.slug, gitBranch: nil, title: nil, titleKind: 0,
                                      firstPrompt: nil, startedAt: nil, lastActivityAt: nil, userPrompts: 0, toolCalls: 0, failed: 0)
        b.sessions[id] = s
        return s
    }

    private func currentTurn(_ id: String, _ b: inout Batch) throws -> TurnState? {
        if b.turnLoaded.contains(id) { return b.turns[id] }
        b.turnLoaded.insert(id)
        try db.prepare("SELECT idx, file_id, ts, prompt, steps, failures, files, reply, last_msg FROM turns WHERE session_id = ?1 ORDER BY idx DESC LIMIT 1")
            .query([.text(id)]) { r in
                let files = (r.text(6) ?? "").split(separator: "\n").map(String.init)
                b.turns[id] = TurnState(idx: Int(r.int(0)), fileID: r.int(1), ts: r.isNull(2) ? nil : r.double(2), prompt: r.text(3) ?? "",
                                        steps: Int(r.int(4)), failures: Int(r.int(5)), files: files, reply: r.text(7), lastMsg: r.text(8))
                return true
            }
        return b.turns[id]
    }

    private func apply(_ e: TranscriptEvent, to b: inout Batch) throws {
        switch e {
        case .title(let t):
            let id = t.sessionID ?? b.file.pathSessionID
            var s = try session(id, &b)
            if t.kind.rawValue >= s.titleKind {
                s.title = String(t.text.prefix(200))
                s.titleKind = t.kind.rawValue
            }
            b.sessions[id] = s

        case .user(let u):
            let id = u.meta.sessionID ?? b.file.pathSessionID
            var s = try session(id, &b)
            touch(&s, u.meta)
            let ts = u.meta.timestamp?.timeIntervalSince1970
            if !u.meta.isSidechain {
                let failures = u.toolResults.filter(\.isError).count
                s.failed += failures
                if u.isPrompt, let text = u.text {
                    s.userPrompts += 1
                    if s.firstPrompt == nil { s.firstPrompt = Self.titleFromPrompt(text) }
                    let prev = try currentTurn(id, &b)
                    if let prev { try writeTurn(id, prev) }
                    b.turns[id] = TurnState(idx: (prev?.idx ?? -1) + 1, fileID: b.fileID, ts: ts, prompt: String(text.prefix(Self.promptLimit)),
                                            steps: 0, failures: 0, files: [], reply: nil, lastMsg: nil)
                    try insertFTS(text, sessionID: id, role: .user, ts: ts, b)
                } else if failures > 0, var t = try currentTurn(id, &b) {
                    t.failures += failures
                    b.turns[id] = t
                }
            }
            b.sessions[id] = s

        case .assistant(let a):
            let id = a.meta.sessionID ?? b.file.pathSessionID
            var s = try session(id, &b)
            touch(&s, a.meta)
            let ts = a.meta.timestamp?.timeIntervalSince1970 ?? b.file.mtime
            let key = a.dedupeKey
            if var p = b.usage[key] {
                p.usage = p.usage.merged(with: a.usage)
                b.usage[key] = p
            } else {
                b.usage[key] = PendingUsage(sessionID: id, ts: ts, model: a.model, usage: a.usage, sidechain: a.meta.isSidechain)
                b.usageOrder.append(key)
            }
            if !a.meta.isSidechain {
                s.toolCalls += a.toolUses.count
                if var t = try currentTurn(id, &b) {
                    if t.lastMsg != key { t.steps += 1; t.lastMsg = key }
                    for tool in a.toolUses where tool.changesFile {
                        if let p = tool.filePath, !t.files.contains(p) { t.files.append(p) }
                    }
                    if let text = a.text, let line = text.split(whereSeparator: \.isNewline).first {
                        t.reply = String(line.prefix(200))
                    }
                    b.turns[id] = t
                }
                if let text = a.text { try insertFTS(text, sessionID: id, role: .assistant, ts: ts, b) }
            }
            b.sessions[id] = s
        }
    }

    private func touch(_ s: inout SessionState, _ m: LineMeta) {
        if let ts = m.timestamp?.timeIntervalSince1970 {
            s.startedAt = min(s.startedAt ?? ts, ts)
            s.lastActivityAt = max(s.lastActivityAt ?? ts, ts)
        }
        if !m.isSidechain {
            if s.projectPath == nil, let cwd = m.cwd, !cwd.isEmpty { s.projectPath = cwd }
            if let br = m.gitBranch, !br.isEmpty { s.gitBranch = br }
        }
    }

    static func titleFromPrompt(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if collapsed.count <= titleLimit { return collapsed }
        return String(collapsed.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private func insertFTS(_ text: String, sessionID: String, role: SessionHit.Role, ts: Double?, _ b: Batch) throws {
        guard !b.line.isEmpty else { return }
        let t = text.count > Self.ftsTextLimit ? String(text.prefix(Self.ftsTextLimit)) : text
        try db.prepare("INSERT INTO fts(text) VALUES(?1)").run([.text(t)])
        let rowid = db.lastInsertRowID
        try db.prepare("INSERT INTO fts_meta(rowid, session_id, role, ts, file_id, line_offset, line_length) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)")
            .run([.int(rowid), .text(sessionID), .int(role == .user ? 0 : 1), ts.map { .double($0) } ?? .null, .int(b.fileID),
                  .int(Int64(b.line.lowerBound)), .int(Int64(b.line.count))])
    }

    private func writeTurn(_ sessionID: String, _ t: TurnState) throws {
        try db.prepare("""
            INSERT OR REPLACE INTO turns(session_id, idx, file_id, ts, prompt, steps, failures, files, reply, last_msg)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            """).run([.text(sessionID), .int(Int64(t.idx)), .int(t.fileID), t.ts.map { .double($0) } ?? .null, .text(t.prompt),
                      .int(Int64(t.steps)), .int(Int64(t.failures)), .text(t.files.joined(separator: "\n")),
                      t.reply.map { .text($0) } ?? .null, t.lastMsg.map { .text($0) } ?? .null])
    }

    private func flush(_ b: inout Batch) throws {
        let find = try db.prepare("""
            SELECT session_id, ts, model, input, output, cache_creation, cache_creation_1h, cache_read, cost, priced, sidechain
            FROM usage_events WHERE key = ?1
            """)
        let put = try db.prepare("""
            INSERT OR REPLACE INTO usage_events(key, session_id, ts, model, input, output, cache_creation, cache_creation_1h, cache_read, cost, priced, sidechain)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """)
        let slotAdd = try db.prepare("""
            INSERT INTO usage_slots(slot, session_id, model, messages, main_messages, unpriced, input, output, cache_creation, cache_creation_1h, cache_read, cost)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(slot, session_id, model) DO UPDATE SET
                messages = messages + excluded.messages, main_messages = main_messages + excluded.main_messages,
                unpriced = unpriced + excluded.unpriced, input = input + excluded.input, output = output + excluded.output,
                cache_creation = cache_creation + excluded.cache_creation, cache_creation_1h = cache_creation_1h + excluded.cache_creation_1h,
                cache_read = cache_read + excluded.cache_read, cost = cost + excluded.cost
            """)
        struct Stored { var session: String; var ts: Double; var model: String; var usage: TokenUsage; var cost: Double; var priced: Bool; var sidechain: Bool }
        func addToSlot(_ e: Stored, sign: Int64) throws {
            let slot = Int64((e.ts / 900).rounded(.down))
            let u = e.usage
            try slotAdd.run([.int(slot), .text(e.session), .text(e.model), .int(sign), .int(e.sidechain ? 0 : sign), .int(e.priced ? 0 : sign),
                             .int(sign * Int64(u.input)), .int(sign * Int64(u.output)), .int(sign * Int64(u.cacheCreation)),
                             .int(sign * Int64(u.cacheCreation1h)), .int(sign * Int64(u.cacheRead)), .double(Double(sign) * e.cost)])
        }
        var touchedSessions = Set<String>()
        for key in b.usageOrder {
            guard let p = b.usage[key] else { continue }
            let hash = Self.hashKey(key)
            var old: Stored?
            try find.query([.int(hash)]) { r in
                old = Stored(session: r.text(0) ?? "", ts: r.double(1), model: r.text(2) ?? "",
                             usage: TokenUsage(input: Int(r.int(3)), output: Int(r.int(4)), cacheCreation: Int(r.int(5)), cacheRead: Int(r.int(7)),
                                               cacheCreation1h: Int(r.int(6))),
                             cost: r.double(8), priced: r.int(9) != 0, sidechain: r.int(10) != 0)
                return true
            }
            // The stored row keeps its first session, model and side; usage only grows, ts only moves earlier.
            var new = old ?? Stored(session: p.sessionID, ts: p.ts, model: p.model, usage: p.usage, cost: 0, priced: true, sidechain: p.sidechain)
            if let old {
                new.usage = old.usage.merged(with: p.usage)
                new.ts = min(old.ts, p.ts)
                if new.usage == old.usage && new.ts == old.ts { continue }
            }
            let c = pricing.cost(new.usage, model: new.model)
            new.cost = c.usd
            new.priced = c.isPriced
            if let old { try addToSlot(old, sign: -1) }
            try addToSlot(new, sign: 1)
            let u = new.usage
            try put.run([.int(hash), .text(new.session), .double(new.ts), .text(new.model), .int(Int64(u.input)), .int(Int64(u.output)),
                         .int(Int64(u.cacheCreation)), .int(Int64(u.cacheCreation1h)), .int(Int64(u.cacheRead)),
                         .double(new.cost), .int(new.priced ? 1 : 0), .int(new.sidechain ? 1 : 0)])
            touchedSessions.insert(new.session)
        }
        if !touchedSessions.isEmpty { try db.execute("DELETE FROM usage_slots WHERE messages <= 0") }
        for id in touchedSessions where b.sessions[id] == nil { _ = try session(id, &b) }
        for (id, t) in b.turns { try writeTurn(id, t) }
        let save = try db.prepare("""
            INSERT INTO sessions(id, home, project_path, project_slug, git_branch, title, title_kind, first_prompt, started_at, last_activity_at,
                                 user_prompts, tool_calls, failed_tool_calls)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(id) DO UPDATE SET home = excluded.home, project_path = excluded.project_path, project_slug = excluded.project_slug,
                git_branch = excluded.git_branch, title = excluded.title, title_kind = excluded.title_kind, first_prompt = excluded.first_prompt,
                started_at = excluded.started_at, last_activity_at = excluded.last_activity_at, user_prompts = excluded.user_prompts,
                tool_calls = excluded.tool_calls, failed_tool_calls = excluded.failed_tool_calls
            """)
        let totals = try db.prepare("""
            UPDATE sessions SET (input, output, cache_creation, cache_read, cost_usd, has_unpriced, message_count) = (
                SELECT COALESCE(SUM(input), 0), COALESCE(SUM(output), 0), COALESCE(SUM(cache_creation), 0), COALESCE(SUM(cache_read), 0),
                       COALESCE(SUM(cost), 0), COALESCE(MAX(unpriced > 0), 0), sessions.user_prompts + COALESCE(SUM(main_messages), 0)
                FROM usage_slots WHERE session_id = ?1),
              model = (SELECT model FROM usage_slots WHERE session_id = ?1 AND model <> '' AND model <> '<synthetic>'
                       GROUP BY model ORDER BY SUM(output) DESC LIMIT 1)
            WHERE id = ?1
            """)
        for s in b.sessions.values {
            func t(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
            func d(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
            try save.run([.text(s.id), .text(s.home), t(s.projectPath), .text(s.slug), t(s.gitBranch), t(s.title), .int(Int64(s.titleKind)),
                          t(s.firstPrompt), d(s.startedAt), d(s.lastActivityAt), .int(Int64(s.userPrompts)), .int(Int64(s.toolCalls)), .int(Int64(s.failed))])
            try totals.run([.text(s.id)])
        }
    }

    /// 64-bit FNV-1a, stable across launches (Swift's `hashValue` is seeded per process).
    static func hashKey(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Int64(bitPattern: h)
    }

    // MARK: - Queries

    private static let sessionColumns = """
        id, home, project_path, git_branch, COALESCE(title, first_prompt, ''), started_at, last_activity_at, message_count, tool_calls,
        failed_tool_calls, input, output, cache_creation, cache_read, cost_usd, model, has_unpriced
        """

    private static func session(from r: Row) -> ClaudeSession {
        ClaudeSession(id: r.text(0) ?? "", home: r.text(1) ?? "", projectPath: r.text(2), gitBranch: r.text(3), title: r.text(4) ?? "",
                      startedAt: r.isNull(5) ? nil : Date(timeIntervalSince1970: r.double(5)),
                      lastActivityAt: r.isNull(6) ? nil : Date(timeIntervalSince1970: r.double(6)),
                      messageCount: Int(r.int(7)), toolCalls: Int(r.int(8)), failedToolCalls: Int(r.int(9)),
                      tokens: TokenUsage(input: Int(r.int(10)), output: Int(r.int(11)), cacheCreation: Int(r.int(12)), cacheRead: Int(r.int(13))),
                      costUSD: r.double(14), model: r.text(15), hasUnpricedUsage: r.int(16) != 0)
    }

    /// Newest activity first. `projectFilter` matches the project path exactly.
    public func sessions(limit: Int = 100, offset: Int = 0, projectFilter: String? = nil) throws -> [ClaudeSession] {
        if let projectFilter {
            return try db.prepare("SELECT \(Self.sessionColumns) FROM sessions WHERE project_path = ?1 ORDER BY last_activity_at DESC LIMIT ?2 OFFSET ?3")
                .all([.text(projectFilter), .int(Int64(limit)), .int(Int64(offset))], Self.session(from:))
        }
        return try db.prepare("SELECT \(Self.sessionColumns) FROM sessions ORDER BY last_activity_at DESC LIMIT ?1 OFFSET ?2")
            .all([.int(Int64(limit)), .int(Int64(offset))], Self.session(from:))
    }

    public func session(id: String) throws -> ClaudeSession? {
        try db.prepare("SELECT \(Self.sessionColumns) FROM sessions WHERE id = ?1").all([.text(id)], Self.session(from:)).first
    }

    /// Most recent hit per session, newest first. Every word must match; the last word matches as a prefix.
    /// Ordered by rowid (insertion order) rather than bm25 so FTS5 can stop at LIMIT: ranking every match of a
    /// common word costs 30+ ms on a large index.
    public func search(_ query: String, limit: Int = 50) throws -> [SessionHit] {
        guard let match = Self.ftsQuery(query), limit > 0 else { return [] }
        // Pass 1: newest matching rows, first one per session.
        struct Pick { var session: String; var role: Int64; var ts: Double?; var fileID: Int64; var offset: Int64; var length: Int64 }
        var picked: [Pick] = []
        var seen = Set<String>()
        var scanned = 0
        try db.prepare(Self.searchSQL).query([.text(match)]) { r in
            scanned += 1
            let sid = r.text(0) ?? ""
            if seen.insert(sid).inserted {
                picked.append(Pick(session: sid, role: r.int(1), ts: r.isNull(2) ? nil : r.double(2), fileID: r.int(3), offset: r.int(4), length: r.int(5)))
            }
            return picked.count < limit && scanned < Self.searchScanLimit
        }
        // An early stop leaves the statement mid-step, which pins a read snapshot and blocks WAL checkpoints.
        _ = try db.prepare(Self.searchSQL)
        // Pass 2: titles, and snippets cut from the transcript line itself (the index stores no text).
        let meta = try db.prepare("SELECT COALESCE(title, first_prompt, ''), project_path FROM sessions WHERE id = ?1")
        let path = try db.prepare("SELECT path FROM files WHERE id = ?1")
        let terms = Self.searchTerms(query)
        var hits: [SessionHit] = []
        for p in picked {
            var title = "", project: String?
            try meta.query([.text(p.session)]) { r in title = r.text(0) ?? ""; project = r.text(1); return true }
            var file: String?
            try path.query([.int(p.fileID)]) { r in file = r.text(0); return true }
            let text = file.flatMap { Self.lineText(path: $0, offset: UInt64(max(0, p.offset)), length: Int(p.length)) }
            hits.append(SessionHit(sessionID: p.session, title: title, projectPath: project, role: p.role == 0 ? .user : .assistant,
                                   timestamp: p.ts.map { Date(timeIntervalSince1970: $0) },
                                   snippet: text.map { Snippet.make($0, terms: terms) } ?? ""))
        }
        return hits
    }

    private static let searchSQL = """
        SELECT m.session_id, m.role, m.ts, m.file_id, m.line_offset, m.line_length
        FROM fts JOIN fts_meta m ON m.rowid = fts.rowid WHERE fts MATCH ?1 ORDER BY fts.rowid DESC
        """

    static func searchTerms(_ q: String) -> [String] {
        q.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
    }

    /// Text of the user or assistant message on one transcript line.
    static func lineText(path: String, offset: UInt64, length: Int) -> String? {
        guard length > 0, length < 64 << 20, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: length), data.count == length else { return nil }
        switch TranscriptParser.event(line: data) {
        case .user(let u): return u.text
        case .assistant(let a): return a.text
        default: return nil
        }
    }

    /// Upper bound on matching rows read for one query (keeps very common words fast).
    static let searchScanLimit = 2_000

    static func ftsQuery(_ q: String) -> String? {
        let words = q.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in i == words.count - 1 ? "\"\(w)\"*" : "\"\(w)\"" }.joined(separator: " ")
    }

    /// Usage per local hour or local calendar day in `[from, to)`. Buckets without usage are omitted.
    /// SQL groups by 15-minute slots (cheap integer math; correct for every UTC offset), Swift folds them into
    /// local buckets with the current calendar.
    public func usage(from: Date, to: Date, bucket: UsageBucket.Size, calendar: Calendar = .current) throws -> [UsageBucket] {
        var out: [Date: UsageBucket] = [:]
        try db.prepare("""
            SELECT slot, SUM(input), SUM(output), SUM(cache_creation), SUM(cache_read), SUM(cost), SUM(cache_creation_1h)
            FROM usage_slots WHERE slot >= ?1 AND slot < ?2 GROUP BY slot
            """).query(Self.slotRange(from, to)) { r in
            let slot = Date(timeIntervalSince1970: Double(r.int(0)) * 900)
            let start: Date = switch bucket {
            case .day: calendar.startOfDay(for: slot)
            case .hour: calendar.dateInterval(of: .hour, for: slot)?.start ?? slot
            }
            var b = out[start] ?? UsageBucket(start: start, tokens: .zero, costUSD: 0)
            b.tokens += Self.tokens(r, 1, oneHour: 6)
            b.costUSD += r.double(5)
            out[start] = b
            return true
        }
        return out.values.sorted { $0.start < $1.start }
    }

    public func usageByProject(from: Date, to: Date) throws -> [ProjectUsage] {
        try db.prepare("""
            SELECT COALESCE(s.project_path, s.project_slug, ''), COUNT(DISTINCT u.session_id), SUM(u.input), SUM(u.output),
                   SUM(u.cache_creation), SUM(u.cache_read), SUM(u.cost), SUM(u.cache_creation_1h)
            FROM usage_slots u JOIN sessions s ON s.id = u.session_id
            WHERE u.slot >= ?1 AND u.slot < ?2 GROUP BY 1 ORDER BY SUM(u.cost) DESC
            """).all(Self.slotRange(from, to)) { r in
            ProjectUsage(projectPath: r.text(0) ?? "", sessions: Int(r.int(1)), tokens: Self.tokens(r, 2, oneHour: 7), costUSD: r.double(6))
        }
    }

    /// Usage per config dir (`ClaudeHome.id`), most expensive first.
    public func usageByHome(from: Date, to: Date) throws -> [HomeUsage] {
        try db.prepare("""
            SELECT s.home, COUNT(DISTINCT u.session_id), SUM(u.input), SUM(u.output), SUM(u.cache_creation), SUM(u.cache_read), SUM(u.cost), SUM(u.cache_creation_1h)
            FROM usage_slots u JOIN sessions s ON s.id = u.session_id
            WHERE u.slot >= ?1 AND u.slot < ?2 GROUP BY 1 ORDER BY SUM(u.cost) DESC
            """).all(Self.slotRange(from, to)) { r in
            HomeUsage(home: r.text(0) ?? "", sessions: Int(r.int(1)), tokens: Self.tokens(r, 2, oneHour: 7), costUSD: r.double(6))
        }
    }

    public func usageByModel(from: Date, to: Date) throws -> [ModelUsage] {
        try db.prepare("""
            SELECT model, SUM(messages), SUM(input), SUM(output), SUM(cache_creation), SUM(cache_read), SUM(cost), SUM(unpriced) = 0, SUM(cache_creation_1h)
            FROM usage_slots WHERE slot >= ?1 AND slot < ?2 AND model <> '<synthetic>' GROUP BY model ORDER BY SUM(cost) DESC
            """).all(Self.slotRange(from, to)) { r in
            ModelUsage(model: r.text(0) ?? "", messages: Int(r.int(1)), tokens: Self.tokens(r, 2, oneHour: 8), costUSD: r.double(6), isPriced: r.int(7) != 0)
        }
    }

    /// 15-minute slots overlapping `[from, to)`. Range queries are exact to the slot.
    static func slotRange(_ from: Date, _ to: Date) -> [SQLValue] {
        let lo = from == .distantPast ? Int64.min : Int64((from.timeIntervalSince1970 / 900).rounded(.down))
        let hi = to == .distantFuture ? Int64.max : Int64((to.timeIntervalSince1970 / 900).rounded(.up))
        return [.int(lo), .int(hi)]
    }

    private static func tokens(_ r: Row, _ i: Int32, oneHour: Int32) -> TokenUsage {
        TokenUsage(input: Int(r.int(i)), output: Int(r.int(i + 1)), cacheCreation: Int(r.int(i + 2)), cacheRead: Int(r.int(i + 3)), cacheCreation1h: Int(r.int(oneHour)))
    }

    public func turns(sessionID: String) throws -> [Turn] {
        try db.prepare("SELECT idx, ts, prompt, steps, files, failures, reply FROM turns WHERE session_id = ?1 ORDER BY idx").all([.text(sessionID)]) { r in
            Turn(index: Int(r.int(0)), timestamp: r.isNull(1) ? nil : Date(timeIntervalSince1970: r.double(1)), prompt: r.text(2) ?? "",
                 steps: Int(r.int(3)), filesChanged: (r.text(4) ?? "").split(separator: "\n").map(String.init), failures: Int(r.int(5)), reply: r.text(6))
        }
    }

    /// `cd <cwd> && claude --resume <id>`, shell-escaped. Adds `CLAUDE_CONFIG_DIR=` for non-default homes.
    public func resumeCommand(sessionID: String) throws -> String? {
        guard let s = try session(id: sessionID) else { return nil }
        return Self.resumeCommand(sessionID: s.id, cwd: s.projectPath, home: ClaudeHome(url: URL(fileURLWithPath: s.home, isDirectory: true)))
    }

    public static func resumeCommand(sessionID: String, cwd: String?, home: ClaudeHome? = nil) -> String {
        var cmd = "claude --resume " + Shell.quote(sessionID)
        if let home, !home.isDefault { cmd = "CLAUDE_CONFIG_DIR=" + Shell.quote(home.url.path) + " " + cmd }
        guard let cwd, !cwd.isEmpty else { return cmd }
        return "cd " + Shell.quote(cwd) + " && " + cmd
    }
}

public enum Shell {
    /// POSIX single-quote escaping; plain words pass through unchanged.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "_@%+=:,./-".unicodeScalars.contains(c))
        }
        if safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
