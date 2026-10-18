import Foundation
import VardisCore

public enum Metric: String, CaseIterable, Sendable, Codable {
    case cpu, memoryUsed, swap, diskRead, diskWrite, netIn, netOut, battery, gpu
    /// Added in schema 2.
    case pressure, compressed
    /// Added in schema 3: free bytes on the startup disk, and 1 while running on battery (0 on power).
    case diskFree, onBattery

    /// Columns created by schema 1; later metrics are added by `ALTER TABLE`.
    static let schema1: [Metric] = [.cpu, .memoryUsed, .swap, .diskRead, .diskWrite, .netIn, .netOut, .battery, .gpu]
    static let schema2: [Metric] = [.pressure, .compressed]
    static let schema3: [Metric] = [.diskFree, .onBattery]

    /// Column prefix in `history_points`. Fixed strings only, never user input.
    var column: String {
        switch self {
        case .cpu: "cpu"
        case .memoryUsed: "mem"
        case .swap: "swap"
        case .diskRead: "disk_r"
        case .diskWrite: "disk_w"
        case .netIn: "net_in"
        case .netOut: "net_out"
        case .battery: "battery"
        case .gpu: "gpu"
        case .pressure: "pressure"
        case .compressed: "compressed"
        case .diskFree: "disk_free"
        case .onBattery: "on_battery"
        }
    }

    /// Memory pressure as a number: normal 0, warning 0.5, critical 1.
    public static func pressureValue(_ p: MemoryPressure) -> Double {
        switch p {
        case .normal: 0
        case .warning: 0.5
        case .critical: 1
        }
    }

    /// Units: cpu, battery, gpu are 0...1; memory and swap are bytes; disk and network are bytes per second.
    func value(in s: Snapshot) -> Double? {
        switch self {
        case .cpu: s.cpu.total
        case .memoryUsed: Double(s.memory.used)
        case .swap: Double(s.memory.swapUsed)
        case .diskRead: s.disk.readBytesPerSecond
        case .diskWrite: s.disk.writeBytesPerSecond
        case .netIn: s.network.receivedBytesPerSecond
        case .netOut: s.network.sentBytesPerSecond
        case .battery: s.battery?.charge
        case .gpu: s.gpu?.utilization
        case .pressure: Metric.pressureValue(s.memory.pressure)
        case .compressed: Double(s.memory.compressed)
        case .diskFree: s.disk.totalBytes > 0 ? Double(s.disk.freeBytes) : nil
        case .onBattery: s.battery.map { $0.onBattery ? 1 : 0 }
        }
    }
}

public struct Point: Sendable, Equatable {
    /// Start of the bucket.
    public var timestamp: Date
    public var avg: Double
    public var max: Double

    public init(timestamp: Date, avg: Double, max: Double) {
        self.timestamp = timestamp
        self.avg = avg
        self.max = max
    }
}

public struct AppPoint: Sendable, Equatable {
    public var timestamp: Date
    public var appID: String
    public var name: String
    /// Average over the bucket, fraction of the whole Mac.
    public var cpu: Double
    public var memory: UInt64
    public var energy: Double
    /// Bytes per second written to disk, averaged over the bucket (schema 2).
    public var diskWrite: Double

    public init(timestamp: Date, appID: String, name: String, cpu: Double, memory: UInt64, energy: Double, diskWrite: Double = 0) {
        self.timestamp = timestamp
        self.appID = appID
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.energy = energy
        self.diskWrite = diskWrite
    }
}

public enum HistoryTier: Int64, CaseIterable, Sendable {
    case raw = 0, tenSeconds = 1, minute = 2, tenMinutes = 3

    /// Bucket width in seconds.
    public var width: Int64 {
        switch self {
        case .raw: 1
        case .tenSeconds: 10
        case .minute: 60
        case .tenMinutes: 600
        }
    }

    /// How long `compact` keeps rows; nil = until `prune`.
    public var keep: TimeInterval? {
        switch self {
        case .raw: 3_600
        case .tenSeconds: 86_400
        case .minute: 30 * 86_400
        case .tenMinutes: nil
        }
    }
}

/// A stretch of time one app was frontmost.
public struct FocusSpan: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var bundleID: String
    public var name: String
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(start: Date, end: Date, bundleID: String, name: String) {
        self.start = start
        self.end = end
        self.bundleID = bundleID
        self.name = name
    }
}

/// One local day of history in a few numbers.
public struct DayStat: Sendable, Equatable {
    /// Start of the local day.
    public var day: Date
    public var recorded: TimeInterval
    /// Average CPU (0...1) and memory in use (bytes).
    public var cpu: Double
    public var memory: Double
    /// Energy the recorded apps drew, joules.
    public var energyJoules: Double
    public var averageWatts: Double { recorded > 0 ? energyJoules / recorded : 0 }
}

/// Tiered history: 1 s (1 h) -> 10 s (24 h) -> 1 min (30 d) -> 10 min (retention).
/// Each tier keeps avg + max per metric, and the top 10 apps by CPU, by memory and by disk writes per point.
/// Notable events (launches, pressure changes, kept awake, ...) live in `history_events`.
public actor HistoryStore {
    public static let schemaVersion: Int64 = 3
    static let appsPerRanking = 10

    private let db: Database

    /// Pass `nil` for an in-memory store.
    public init(url: URL?) throws {
        db = try Database(url: url)
        try Self.migrate(db)
    }

    // MARK: Schema

    private static func migrate(_ db: Database) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version(component TEXT PRIMARY KEY, version INTEGER NOT NULL)")
        let current = try db.prepare("SELECT version FROM schema_version WHERE component = 'history'").all { $0.int(0) }.first ?? 0
        if current > schemaVersion {
            throw DatabaseError(code: -1, message: "history schema \(current) is newer than this build (\(schemaVersion))")
        }
        guard current < schemaVersion else { return }
        try db.transaction {
            if current < 1 {
                let metricCols = Metric.schema1.map { "\($0.column)_avg REAL, \($0.column)_max REAL" }.joined(separator: ", ")
                try db.execute("""
                CREATE TABLE history_points(
                    tier INTEGER NOT NULL, ts INTEGER NOT NULL, n INTEGER NOT NULL, \(metricCols),
                    PRIMARY KEY(tier, ts)) WITHOUT ROWID;
                CREATE TABLE history_apps(
                    tier INTEGER NOT NULL, ts INTEGER NOT NULL, app_id TEXT NOT NULL, name TEXT NOT NULL,
                    cpu REAL NOT NULL, memory REAL NOT NULL, energy REAL NOT NULL,
                    PRIMARY KEY(tier, ts, app_id)) WITHOUT ROWID;
                """)
            }
            if current < 2 {
                for m in Metric.schema2 {
                    try db.execute("ALTER TABLE history_points ADD COLUMN \(m.column)_avg REAL")
                    try db.execute("ALTER TABLE history_points ADD COLUMN \(m.column)_max REAL")
                }
                try db.execute("""
                ALTER TABLE history_apps ADD COLUMN disk_w REAL NOT NULL DEFAULT 0;
                CREATE TABLE history_events(
                    id INTEGER PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, app TEXT, detail TEXT NOT NULL, value REAL);
                CREATE INDEX history_events_ts ON history_events(ts);
                """)
            }
            if current < 3 {
                for m in Metric.schema3 {
                    try db.execute("ALTER TABLE history_points ADD COLUMN \(m.column)_avg REAL")
                    try db.execute("ALTER TABLE history_points ADD COLUMN \(m.column)_max REAL")
                }
                try db.execute("""
                CREATE TABLE app_focus(id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, bundle_id TEXT NOT NULL, name TEXT NOT NULL);
                CREATE INDEX app_focus_end ON app_focus(end);
                """)
            }
            try db.prepare("INSERT OR REPLACE INTO schema_version(component, version) VALUES('history', ?1)").run([.int(schemaVersion)])
        }
    }

    // MARK: Write

    private static let insertPointSQL: String = {
        let cols = Metric.allCases.map { "\($0.column)_avg, \($0.column)_max" }.joined(separator: ", ")
        let params = (0..<(Metric.allCases.count * 2)).map { "?\($0 + 3)" }.joined(separator: ", ")
        return "INSERT OR REPLACE INTO history_points(tier, ts, n, \(cols)) VALUES(0, ?1, ?2, \(params))"
    }()

    /// One transaction per snapshot: one point row plus the top apps.
    public func append(_ s: Snapshot) throws {
        let ts = Int64(s.timestamp.timeIntervalSince1970.rounded(.down))
        var values: [SQLValue] = [.int(ts), .int(1)]
        values.reserveCapacity(2 + Metric.allCases.count * 2)
        for m in Metric.allCases {
            let v: SQLValue = m.value(in: s).map { .double($0) } ?? .null
            values.append(v)
            values.append(v)
        }
        let apps = Self.topApps(s.apps)
        try db.transaction {
            try db.prepare(Self.insertPointSQL).run(values)
            try db.prepare("DELETE FROM history_apps WHERE tier = 0 AND ts = ?1").run([.int(ts)])
            let ins = try db.prepare("INSERT OR REPLACE INTO history_apps(tier, ts, app_id, name, cpu, memory, energy, disk_w) VALUES(0, ?1, ?2, ?3, ?4, ?5, ?6, ?7)")
            for a in apps {
                try ins.run([.int(ts), .text(a.id), .text(a.name), .double(a.cpu), .double(Double(a.memory)), .double(a.energyWatts), .double(a.diskWriteBytesPerSecond)])
            }
        }
    }

    /// Union of the top N by CPU, the top N by memory and the top N apps that wrote to disk.
    static func topApps(_ apps: [AppSample]) -> [AppSample] {
        let byCPU = apps.sorted { $0.cpu > $1.cpu }.prefix(appsPerRanking)
        let byMem = apps.sorted { $0.memory > $1.memory }.prefix(appsPerRanking)
        let byDisk = apps.filter { $0.diskWriteBytesPerSecond > 0 }.sorted { $0.diskWriteBytesPerSecond > $1.diskWriteBytesPerSecond }.prefix(appsPerRanking)
        var seen = Set<String>()
        return (byCPU + byMem + byDisk).filter { seen.insert($0.id).inserted }
    }

    // MARK: Read

    /// Points from the finest tier whose data reaches back to `from`, plus any newer
    /// not-yet-compacted points from finer tiers so the tail is current.
    public func series(_ metric: Metric, from: Date, to: Date) throws -> [Point] {
        let lo = Int64(from.timeIntervalSince1970.rounded(.down))
        let hi = Int64(to.timeIntervalSince1970.rounded(.down))
        guard hi >= lo else { return [] }
        let tier = try tierCovering(lo)
        let c = metric.column
        let q = try db.prepare("SELECT ts, \(c)_avg, \(c)_max FROM history_points WHERE tier = ?1 AND ts >= ?2 AND ts <= ?3 AND \(c)_avg IS NOT NULL ORDER BY ts")
        let map: (Row) -> Point = { Point(timestamp: Date(timeIntervalSince1970: TimeInterval($0.int(0))), avg: $0.double(1), max: $0.double(2)) }
        // Coarse buckets start before `from`; include the one that contains it.
        var points = try q.all([.int(tier.rawValue), .int(lo - (lo % tier.width)), .int(hi)], map)

        var tailStart = try (db.prepare("SELECT max(ts) FROM history_points WHERE tier = ?1").all([.int(tier.rawValue)]) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil)
            .map { $0 + tier.width } ?? lo
        for finer in HistoryTier.allCases.filter({ $0.rawValue < tier.rawValue }).reversed() {
            let tail = try q.all([.int(finer.rawValue), .int(max(tailStart, lo)), .int(hi)], map)
            points += tail
            if let last = tail.last { tailStart = Int64(last.timestamp.timeIntervalSince1970) + finer.width }
        }
        return points
    }

    private func tierCovering(_ lo: Int64) throws -> HistoryTier {
        let q = try db.prepare("SELECT min(ts) FROM history_points WHERE tier = ?1")
        var best: (HistoryTier, Int64)?
        for t in HistoryTier.allCases {
            guard let minTs = try q.all([.int(t.rawValue)], { $0.isNull(0) ? nil : $0.int(0) }).first ?? nil else { continue }
            if minTs <= lo { return t }
            if best == nil || minTs < best!.1 { best = (t, minTs) }
        }
        return best?.0 ?? .raw
    }

    public enum AppOrder: Sendable { case cpu, memory }

    /// Top apps at the finest tier point at or just before `at`, by CPU (default) or memory.
    public func topApps(at: Date, limit: Int, by order: AppOrder = .cpu) throws -> [AppPoint] {
        let t = Int64(at.timeIntervalSince1970.rounded(.down))
        let find = try db.prepare("SELECT max(ts) FROM history_apps WHERE tier = ?1 AND ts <= ?2 AND ts > ?3")
        for tier in HistoryTier.allCases {
            guard let ts = try find.all([.int(tier.rawValue), .int(t), .int(t - 2 * tier.width)], { $0.isNull(0) ? nil : $0.int(0) }).first ?? nil else { continue }
            let orderBy = order == .cpu ? "cpu DESC, memory DESC" : "memory DESC, cpu DESC"
            return try db.prepare("SELECT ts, app_id, name, cpu, memory, energy, disk_w FROM history_apps WHERE tier = ?1 AND ts = ?2 ORDER BY \(orderBy) LIMIT ?3")
                .all([.int(tier.rawValue), .int(ts), .int(Int64(max(0, limit)))], Self.appPoint)
        }
        return []
    }

    private static func appPoint(_ r: Row) -> AppPoint {
        AppPoint(timestamp: Date(timeIntervalSince1970: TimeInterval(r.int(0))), appID: r.text(1) ?? "", name: r.text(2) ?? "",
                 cpu: r.double(3), memory: UInt64(max(0, r.double(4))), energy: r.double(5), diskWrite: r.double(6))
    }

    /// Non-overlapping (tier, from, to) segments covering `lo...hi`: the tier that reaches back to
    /// `lo`, then newer rows from finer tiers that are not compacted yet. Same rule as `series`.
    private func segments(_ lo: Int64, _ hi: Int64) throws -> [(HistoryTier, Int64, Int64)] {
        guard hi >= lo else { return [] }
        let tier = try tierCovering(lo)
        var out = [(tier, lo - (lo % tier.width), hi)]
        let maxQ = try db.prepare("SELECT max(ts) FROM history_points WHERE tier = ?1 AND ts >= ?2 AND ts <= ?3")
        func last(_ t: HistoryTier, _ a: Int64) throws -> Int64? {
            try maxQ.all([.int(t.rawValue), .int(a), .int(hi)]) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil
        }
        var tailStart = try last(tier, Int64.min).map { $0 + tier.width } ?? lo
        for finer in HistoryTier.allCases.filter({ $0.rawValue < tier.rawValue }).reversed() {
            let a = max(tailStart, lo)
            out.append((finer, a, hi))
            if let l = try last(finer, a) { tailStart = l + finer.width }
        }
        return out
    }

    /// Every stored app row between `from` and `to`, oldest first, from the same tiers `series` uses.
    public func appSeries(from: Date, to: Date) throws -> [AppPoint] {
        let lo = Int64(from.timeIntervalSince1970.rounded(.down))
        let hi = Int64(to.timeIntervalSince1970.rounded(.down))
        let q = try db.prepare("SELECT ts, app_id, name, cpu, memory, energy, disk_w FROM history_apps WHERE tier = ?1 AND ts >= ?2 AND ts <= ?3 ORDER BY ts")
        var out: [AppPoint] = []
        for (tier, a, b) in try segments(lo, hi) {
            out += try q.all([.int(tier.rawValue), .int(a), .int(b)], Self.appPoint)
        }
        return out
    }

    /// Bucket width in seconds of each point `series` returns for this range (finest first is the tail).
    public func bucketWidth(from: Date) throws -> TimeInterval {
        TimeInterval(try tierCovering(Int64(from.timeIntervalSince1970.rounded(.down))).width)
    }

    /// Every metric's average at the finest tier point at or just before `at`.
    public func moment(at: Date) throws -> [Metric: Double] {
        let t = Int64(at.timeIntervalSince1970.rounded(.down))
        let cols = Metric.allCases.map { "\($0.column)_avg" }.joined(separator: ", ")
        let q = try db.prepare("SELECT \(cols) FROM history_points WHERE tier = ?1 AND ts <= ?2 AND ts > ?3 ORDER BY ts DESC LIMIT 1")
        for tier in HistoryTier.allCases {
            let rows = try q.all([.int(tier.rawValue), .int(t), .int(t - 2 * tier.width)]) { r -> [Metric: Double] in
                var out: [Metric: Double] = [:]
                for (i, m) in Metric.allCases.enumerated() where !r.isNull(Int32(i)) { out[m] = r.double(Int32(i)) }
                return out
            }
            if let first = rows.first { return first }
        }
        return [:]
    }

    /// Oldest stored point, i.e. when recording started (within retention).
    public func earliest() throws -> Date? {
        try db.prepare("SELECT min(ts) FROM history_points").all { $0.isNull(0) ? nil : Date(timeIntervalSince1970: TimeInterval($0.int(0))) }.first ?? nil
    }

    // MARK: Events

    public func append(events: [HistoryEvent]) throws {
        guard !events.isEmpty else { return }
        try db.transaction {
            let ins = try db.prepare("INSERT INTO history_events(ts, kind, app, detail, value) VALUES(?1, ?2, ?3, ?4, ?5)")
            for e in events {
                try ins.run([.double(e.timestamp.timeIntervalSince1970), .text(e.kind.rawValue), e.app.map { .text($0) } ?? .null, .text(e.detail),
                             e.value.map { .double($0) } ?? .null])
            }
        }
    }

    /// Events between `from` and `to`, oldest first. Unknown kinds (from a newer build) are skipped.
    public func events(from: Date, to: Date) throws -> [HistoryEvent] {
        try db.prepare("SELECT ts, kind, app, detail, value FROM history_events WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts, id")
            .all([.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { r -> HistoryEvent? in
                guard let kind = HistoryEvent.Kind(rawValue: r.text(1) ?? "") else { return nil }
                return HistoryEvent(timestamp: Date(timeIntervalSince1970: r.double(0)), kind: kind, app: r.text(2), detail: r.text(3) ?? "",
                                    value: r.isNull(4) ? nil : r.double(4))
            }
            .compactMap { $0 }
    }

    // MARK: Foreground apps

    /// Appends a stretch of time an app was frontmost. Stretches under a second are dropped.
    public func appendFocus(_ spans: [FocusSpan]) throws {
        let keep = spans.filter { $0.end.timeIntervalSince($0.start) >= 1 }
        guard !keep.isEmpty else { return }
        try db.transaction {
            let ins = try db.prepare("INSERT INTO app_focus(start, end, bundle_id, name) VALUES(?1, ?2, ?3, ?4)")
            for f in keep {
                try ins.run([.double(f.start.timeIntervalSince1970), .double(f.end.timeIntervalSince1970), .text(f.bundleID), .text(f.name)])
            }
        }
    }

    /// Stretches overlapping `from...to`, clipped to it, oldest first.
    public func focus(from: Date, to: Date) throws -> [FocusSpan] {
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        return try db.prepare("SELECT start, end, bundle_id, name FROM app_focus WHERE end > ?1 AND start < ?2 ORDER BY start")
            .all([.double(lo), .double(hi)]) { r in
                FocusSpan(start: Date(timeIntervalSince1970: max(lo, r.double(0))), end: Date(timeIntervalSince1970: min(hi, r.double(1))),
                          bundleID: r.text(2) ?? "", name: r.text(3) ?? "")
            }
    }

    // MARK: Daily summaries

    /// Per local day between `from` and `to`: time recorded, average CPU and memory, and the
    /// energy the recorded apps drew. Read from the one tier that reaches back to `from` (minute
    /// points for the last 30 days), aggregated in SQLite so a week costs a few milliseconds.
    public func dailyStats(from: Date, to: Date, utcOffset: Int) throws -> [DayStat] {
        let lo = Int64(from.timeIntervalSince1970.rounded(.down))
        let hi = Int64(to.timeIntervalSince1970.rounded(.down))
        guard hi > lo else { return [] }
        let tier = try tierCovering(lo)
        let off = Int64(utcOffset)
        var out: [Int64: DayStat] = [:]
        try db.prepare("""
        SELECT (ts + ?4) / 86400 AS d, count(*), sum(cpu_avg * n) / sum(CASE WHEN cpu_avg IS NULL THEN NULL ELSE n END),
               sum(mem_avg * n) / sum(CASE WHEN mem_avg IS NULL THEN NULL ELSE n END)
        FROM history_points WHERE tier = ?1 AND ts >= ?2 AND ts < ?3 GROUP BY d
        """).query([.int(tier.rawValue), .int(lo), .int(hi), .int(off)]) { r in
            let d = r.int(0)
            out[d] = DayStat(day: Date(timeIntervalSince1970: TimeInterval(d * 86_400 - off)), recorded: TimeInterval(r.int(1) * tier.width),
                             cpu: r.double(2), memory: r.double(3), energyJoules: 0)
            return true
        }
        try db.prepare("""
        SELECT (ts + ?4) / 86400 AS d, sum(energy) FROM history_apps WHERE tier = ?1 AND ts >= ?2 AND ts < ?3 GROUP BY d
        """).query([.int(tier.rawValue), .int(lo), .int(hi), .int(off)]) { r in
            out[r.int(0)]?.energyJoules = r.double(1) * Double(tier.width)
            return true
        }
        return out.values.sorted { $0.day < $1.day }
    }

    /// Row count of one tier, for tests and diagnostics.
    func countRows(tier: HistoryTier, apps: Bool = false) throws -> Int {
        let table = apps ? "history_apps" : "history_points"
        return Int(try db.prepare("SELECT count(*) FROM \(table) WHERE tier = ?1").all([.int(tier.rawValue)]) { $0.int(0) }.first ?? 0)
    }

    // MARK: Maintenance

    /// Deletes every row older than `now - retention`, in all tiers.
    public func prune(retention: TimeInterval, now: Date) throws {
        let cutoff = Int64((now.timeIntervalSince1970 - retention).rounded(.down))
        try db.transaction {
            try db.prepare("DELETE FROM history_points WHERE ts < ?1").run([.int(cutoff)])
            try db.prepare("DELETE FROM history_apps WHERE ts < ?1").run([.int(cutoff)])
            try db.prepare("DELETE FROM history_events WHERE ts < ?1").run([.double(Double(cutoff))])
            try db.prepare("DELETE FROM app_focus WHERE end < ?1").run([.double(Double(cutoff))])
        }
    }

    /// Rolls complete buckets of each tier into the next coarser one, then drops rows past each
    /// tier's keep window. Rolled buckets are never rewritten, so running it twice changes nothing.
    public func compact(now: Date) throws {
        let nowTs = Int64(now.timeIntervalSince1970.rounded(.down))
        try db.transaction {
            for fine in HistoryTier.allCases.dropLast() {
                let coarse = HistoryTier(rawValue: fine.rawValue + 1)!
                try rollUp(from: fine, to: coarse, nowTs: nowTs)
            }
            for tier in HistoryTier.allCases {
                guard let keep = tier.keep else { continue }
                let cutoff = nowTs - Int64(keep)
                try db.prepare("DELETE FROM history_points WHERE tier = ?1 AND ts < ?2").run([.int(tier.rawValue), .int(cutoff)])
                try db.prepare("DELETE FROM history_apps WHERE tier = ?1 AND ts < ?2").run([.int(tier.rawValue), .int(cutoff)])
            }
        }
    }

    private static let rollPointsSQL: String = {
        let aggs = Metric.allCases.map { m in
            let c = m.column
            return "sum(\(c)_avg * n) / sum(CASE WHEN \(c)_avg IS NULL THEN NULL ELSE n END), max(\(c)_max)"
        }.joined(separator: ", ")
        let cols = Metric.allCases.map { "\($0.column)_avg, \($0.column)_max" }.joined(separator: ", ")
        return """
        INSERT OR IGNORE INTO history_points(tier, ts, n, \(cols))
        SELECT ?1, (ts / ?2) * ?2 AS b, sum(n), \(aggs)
        FROM history_points WHERE tier = ?3 AND ts >= ?4 AND ts < ?5 GROUP BY b
        """
    }()

    /// App averages are time-weighted over the whole bucket: an app absent from a finer point counts as 0.
    private static let rollAppsSQL = """
    INSERT OR IGNORE INTO history_apps(tier, ts, app_id, name, cpu, memory, energy, disk_w)
    SELECT ?1, b, app_id, name, cpu, memory, energy, disk_w FROM (
        SELECT b, app_id, name, cpu, memory, energy, disk_w,
            ROW_NUMBER() OVER (PARTITION BY b ORDER BY cpu DESC, app_id) AS rc,
            ROW_NUMBER() OVER (PARTITION BY b ORDER BY memory DESC, app_id) AS rm,
            ROW_NUMBER() OVER (PARTITION BY b ORDER BY disk_w DESC, app_id) AS rd
        FROM (
            SELECT (a.ts / ?2) * ?2 AS b, a.app_id AS app_id, max(a.name) AS name,
                sum(a.cpu * p.n) / max(t.n) AS cpu,
                sum(a.memory * p.n) / max(t.n) AS memory,
                sum(a.energy * p.n) / max(t.n) AS energy,
                sum(a.disk_w * p.n) / max(t.n) AS disk_w
            FROM history_apps a
            JOIN history_points p ON p.tier = a.tier AND p.ts = a.ts
            JOIN (SELECT (ts / ?2) * ?2 AS tb, sum(n) AS n FROM history_points
                  WHERE tier = ?3 AND ts >= ?4 AND ts < ?5 GROUP BY tb) t ON t.tb = (a.ts / ?2) * ?2
            WHERE a.tier = ?3 AND a.ts >= ?4 AND a.ts < ?5
            GROUP BY b, a.app_id
        )
    ) WHERE rc <= \(appsPerRanking) OR rm <= \(appsPerRanking) OR (rd <= \(appsPerRanking) AND disk_w > 0)
    """

    private func rollUp(from fine: HistoryTier, to coarse: HistoryTier, nowTs: Int64) throws {
        let w = coarse.width
        // Only buckets that have ended and that the coarse tier does not hold yet.
        let end = nowTs - (nowTs % w)
        let lastCoarse = try db.prepare("SELECT max(ts) FROM history_points WHERE tier = ?1").all([.int(coarse.rawValue)]) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil
        let start = lastCoarse.map { $0 + w } ?? Int64.min
        guard start < end else { return }
        let args: [SQLValue] = [.int(coarse.rawValue), .int(w), .int(fine.rawValue), .int(start), .int(end)]
        try db.prepare(Self.rollAppsSQL).run(args)
        try db.prepare(Self.rollPointsSQL).run(args)
    }
}
