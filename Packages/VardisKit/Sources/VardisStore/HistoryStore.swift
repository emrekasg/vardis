import Foundation
import VardisCore

public enum Metric: String, CaseIterable, Sendable, Codable {
    case cpu, memoryUsed, swap, diskRead, diskWrite, netIn, netOut, battery, gpu

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

    public init(timestamp: Date, appID: String, name: String, cpu: Double, memory: UInt64, energy: Double) {
        self.timestamp = timestamp
        self.appID = appID
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.energy = energy
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

/// Tiered history: 1 s (1 h) -> 10 s (24 h) -> 1 min (30 d) -> 10 min (retention).
/// Each tier keeps avg + max per metric, and the top 10 apps by CPU and by memory per point.
public actor HistoryStore {
    public static let schemaVersion: Int64 = 1
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
                let metricCols = Metric.allCases.map { "\($0.column)_avg REAL, \($0.column)_max REAL" }.joined(separator: ", ")
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
            let ins = try db.prepare("INSERT OR REPLACE INTO history_apps(tier, ts, app_id, name, cpu, memory, energy) VALUES(0, ?1, ?2, ?3, ?4, ?5, ?6)")
            for a in apps {
                try ins.run([.int(ts), .text(a.id), .text(a.name), .double(a.cpu), .double(Double(a.memory)), .double(a.energyWatts)])
            }
        }
    }

    /// Union of the top N by CPU and the top N by memory.
    static func topApps(_ apps: [AppSample]) -> [AppSample] {
        let byCPU = apps.sorted { $0.cpu > $1.cpu }.prefix(appsPerRanking)
        let byMem = apps.sorted { $0.memory > $1.memory }.prefix(appsPerRanking)
        var seen = Set<String>()
        return (byCPU + byMem).filter { seen.insert($0.id).inserted }
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

    /// Top apps by CPU at the finest tier point at or just before `at`.
    public func topApps(at: Date, limit: Int) throws -> [AppPoint] {
        let t = Int64(at.timeIntervalSince1970.rounded(.down))
        let find = try db.prepare("SELECT max(ts) FROM history_apps WHERE tier = ?1 AND ts <= ?2 AND ts > ?3")
        for tier in HistoryTier.allCases {
            guard let ts = try find.all([.int(tier.rawValue), .int(t), .int(t - 2 * tier.width)], { $0.isNull(0) ? nil : $0.int(0) }).first ?? nil else { continue }
            return try db.prepare("SELECT ts, app_id, name, cpu, memory, energy FROM history_apps WHERE tier = ?1 AND ts = ?2 ORDER BY cpu DESC, memory DESC LIMIT ?3")
                .all([.int(tier.rawValue), .int(ts), .int(Int64(max(0, limit)))]) {
                    AppPoint(timestamp: Date(timeIntervalSince1970: TimeInterval($0.int(0))), appID: $0.text(1) ?? "", name: $0.text(2) ?? "",
                             cpu: $0.double(3), memory: UInt64(max(0, $0.double(4))), energy: $0.double(5))
                }
        }
        return []
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
    INSERT OR IGNORE INTO history_apps(tier, ts, app_id, name, cpu, memory, energy)
    SELECT ?1, b, app_id, name, cpu, memory, energy FROM (
        SELECT b, app_id, name, cpu, memory, energy,
            ROW_NUMBER() OVER (PARTITION BY b ORDER BY cpu DESC, app_id) AS rc,
            ROW_NUMBER() OVER (PARTITION BY b ORDER BY memory DESC, app_id) AS rm
        FROM (
            SELECT (a.ts / ?2) * ?2 AS b, a.app_id AS app_id, max(a.name) AS name,
                sum(a.cpu * p.n) / max(t.n) AS cpu,
                sum(a.memory * p.n) / max(t.n) AS memory,
                sum(a.energy * p.n) / max(t.n) AS energy
            FROM history_apps a
            JOIN history_points p ON p.tier = a.tier AND p.ts = a.ts
            JOIN (SELECT (ts / ?2) * ?2 AS tb, sum(n) AS n FROM history_points
                  WHERE tier = ?3 AND ts >= ?4 AND ts < ?5 GROUP BY tb) t ON t.tb = (a.ts / ?2) * ?2
            WHERE a.tier = ?3 AND a.ts >= ?4 AND a.ts < ?5
            GROUP BY b, a.app_id
        )
    ) WHERE rc <= \(appsPerRanking) OR rm <= \(appsPerRanking)
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
