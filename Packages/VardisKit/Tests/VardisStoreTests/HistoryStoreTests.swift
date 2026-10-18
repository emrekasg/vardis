import Foundation
import Testing
import VardisCore
@testable import VardisStore

func snapshot(at t: TimeInterval, cpu: Double, apps: Int = 30, battery: Double? = 0.5) -> Snapshot {
    let appList: [AppSample] = (0..<apps).map { (i: Int) -> AppSample in
        AppSample(id: "app.\(i)", name: "App \(i)", bundleURL: nil, isSystem: false, processIDs: [Int32(i)],
                  cpu: Double(i) / 100.0, memory: UInt64(apps - i) * 1_000_000, energyWatts: Double(i) / 10.0,
                  diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0)
    }
    return Snapshot(
        timestamp: Date(timeIntervalSince1970: t),
        cpu: CPUSample(user: cpu, system: 0, perCore: [cpu]),
        memory: MemorySample(total: 8_000_000_000, app: 1_000_000_000, wired: 0, compressed: 0, cached: 0, free: 0, swapUsed: 0, pressure: .normal),
        disk: DiskSample(totalBytes: 0, freeBytes: 0, readBytesPerSecond: 100, writeBytesPerSecond: 200),
        network: NetworkSample(receivedBytesPerSecond: 10, sentBytesPerSecond: 20, receivedTotal: 0, sentTotal: 0),
        battery: battery.map { BatterySample(charge: $0, isCharging: false, onBattery: true, timeRemaining: nil, watts: nil, cycleCount: nil, health: nil) },
        gpu: nil, apps: appList, processCount: apps, uptime: 0)
}

/// Aligned to 10 minutes so bucket boundaries are easy to reason about.
let base: TimeInterval = 1_800_000_000

@Test func rawAppendAndQuery() async throws {
    let store = try HistoryStore(url: nil)
    for i in 0..<60 { try await store.append(snapshot(at: base + Double(i), cpu: Double(i % 2))) }
    let pts = try await store.series(.cpu, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base + 59))
    #expect(pts.count == 60)
    #expect(pts[1].avg == 1 && pts[1].max == 1)
    // gpu is nil in every snapshot: no points.
    #expect(try await store.series(.gpu, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base + 59)).isEmpty)
    let top = try await store.topApps(at: Date(timeIntervalSince1970: base + 30.5), limit: 5)
    #expect(top.count == 5 && top[0].appID == "app.29" && top[0].timestamp == Date(timeIntervalSince1970: base + 30))
    // Top 10 by cpu (app.20...29) plus top 10 by memory (app.0...9) are stored.
    #expect(try await store.topApps(at: Date(timeIntervalSince1970: base), limit: 100).count == 20)
}

@Test func compactRollsTiersAndIsIdempotent() async throws {
    let store = try HistoryStore(url: nil)
    // 2 hours of 1 s data: cpu alternates 0 / 1, so every bucket has avg 0.5, max 1.
    let span = 7_200
    for i in 0..<span { try await store.append(snapshot(at: base + Double(i), cpu: Double(i % 2), apps: 12)) }
    let now = Date(timeIntervalSince1970: base + Double(span))
    try await store.compact(now: now)

    func range(_ seconds: TimeInterval) -> (Date, Date) { (now.addingTimeInterval(-seconds), now) }

    // Last 30 min: raw tier still holds the last hour.
    let (a, b) = range(1_800)
    let raw = try await store.series(.cpu, from: a, to: b)
    #expect(raw.count == 1_800)

    // Last 2 h: raw no longer reaches back -> 10 s tier.
    let ten = try await store.series(.cpu, from: Date(timeIntervalSince1970: base), to: now)
    #expect(ten.count == span / 10)
    #expect(ten.allSatisfy { abs($0.avg - 0.5) < 1e-9 && $0.max == 1 })

    // Battery averages carry through.
    let bat = try await store.series(.battery, from: Date(timeIntervalSince1970: base), to: now)
    #expect(bat.first?.avg == 0.5)

    let counts1 = try await rowCounts(store)
    try await store.compact(now: now)
    let counts2 = try await rowCounts(store)
    #expect(counts1 == counts2)

    // 1 min and 10 min tiers exist with correct weighting.
    #expect(counts1[2] == span / 60)
    #expect(counts1[3] == span / 600)
    #expect(counts1[0] == 3_600) // raw keep window = 1 h

    // Apps at a 10 s point: averaged over the bucket.
    let apps = try await store.topApps(at: Date(timeIntervalSince1970: base + 15), limit: 3)
    #expect(apps.first?.timestamp == Date(timeIntervalSince1970: base + 10))
    #expect(apps.first?.appID == "app.11")
    #expect(abs((apps.first?.cpu ?? 0) - 0.11) < 1e-9)
}

@Test func coarseTiersAfterExpiry() async throws {
    let store = try HistoryStore(url: nil)
    // Sparse 1 s samples every 5 s over 3 days, compacted hourly as the app would.
    let day = 86_400
    var t = 0
    var nextCompact = 3_600
    while t < 3 * day {
        try await store.append(snapshot(at: base + Double(t), cpu: 0.25, apps: 3, battery: nil))
        t += 5
        if t >= nextCompact {
            try await store.compact(now: Date(timeIntervalSince1970: base + Double(t)))
            nextCompact += 3_600
        }
    }
    let now = Date(timeIntervalSince1970: base + Double(t))
    try await store.compact(now: now)
    let counts = try await rowCounts(store)
    #expect(counts[1]! <= day / 10 + 1) // 10 s tier trimmed to 24 h

    // 3 days back: only the 1 min tier reaches; plus a fresh tail from finer tiers.
    let pts = try await store.series(.cpu, from: Date(timeIntervalSince1970: base), to: now)
    #expect(pts.count >= 3 * day / 60 - 2)
    #expect(pts.allSatisfy { abs($0.avg - 0.25) < 1e-9 })
    #expect(zip(pts, pts.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
    #expect(try await store.series(.battery, from: Date(timeIntervalSince1970: base), to: now).isEmpty)

    // Prune to 1 day keeps nothing older.
    try await store.prune(retention: 86_400, now: now)
    let after = try await store.series(.cpu, from: Date(timeIntervalSince1970: base), to: now)
    #expect(after.allSatisfy { $0.timestamp >= now.addingTimeInterval(-86_400) })
    #expect(!after.isEmpty)
    #expect(try await store.topApps(at: Date(timeIntervalSince1970: base + 100), limit: 3).isEmpty)
}

@Test func schemaVersionRecorded() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-hist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.sqlite")
    do {
        let s = try HistoryStore(url: url)
        try await s.append(snapshot(at: base, cpu: 0.3))
    }
    // Reopen: migration is a no-op and data survives.
    let s2 = try HistoryStore(url: url)
    let pts = try await s2.series(.cpu, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base))
    #expect(pts.count == 1)
    let db = try Database(url: url)
    let v = try db.prepare("SELECT version FROM schema_version WHERE component = 'history'").all { $0.int(0) }
    #expect(v == [HistoryStore.schemaVersion])
}

@Test func appendTiming() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-hist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
    let snaps = (0..<3_600).map { snapshot(at: base + Double($0), cpu: 0.5, apps: 60) }
    let clock = ContinuousClock()
    let start = clock.now
    for s in snaps { try await store.append(s) }
    let elapsed = clock.now - start
    let perAppend = Double(elapsed.components.attoseconds) / 1e15 / 3_600 + Double(elapsed.components.seconds) * 1_000 / 3_600
    print("HISTORY append: 3600 in \(elapsed), \(String(format: "%.3f", perAppend)) ms each")
    #expect(perAppend < 1.0)
}

extension HistoryStore {
    func debugRowCounts() throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for t in HistoryTier.allCases {
            out[t.rawValue] = try countRows(tier: t)
            out[t.rawValue + 10] = try countRows(tier: t, apps: true)
        }
        return out
    }
}

func rowCounts(_ s: HistoryStore) async throws -> [Int64: Int] { try await s.debugRowCounts() }

@Test func focusSpansRoundTripClippedAndPruned() async throws {
    let store = try HistoryStore(url: nil)
    let t = { (s: TimeInterval) in Date(timeIntervalSince1970: base + s) }
    try await store.appendFocus([
        FocusSpan(start: t(0), end: t(600), bundleID: "com.apple.Safari", name: "Safari"),
        FocusSpan(start: t(600), end: t(600.5), bundleID: "x", name: "Blink"), // under a second: dropped
        FocusSpan(start: t(700), end: t(1_000), bundleID: "com.apple.dt.Xcode", name: "Xcode"),
    ])
    let all = try await store.focus(from: t(300), to: t(800))
    #expect(all.map(\.name) == ["Safari", "Xcode"])
    #expect(all[0].start == t(300) && all[0].duration == 300 && all[1].end == t(800))
    try await store.prune(retention: 0, now: t(650))
    #expect(try await store.focus(from: t(0), to: t(2_000)).map(\.name) == ["Xcode"])
}

@Test func dailyStatsAggregatePerLocalDay() async throws {
    let store = try HistoryStore(url: nil)
    // Two days of minute points at cpu 0.2 and 0.6.
    for d in 0..<2 {
        for m in 0..<120 {
            try await store.append(snapshot(at: base + Double(d) * 86_400 + Double(m) * 60, cpu: d == 0 ? 0.2 : 0.6, apps: 3))
        }
    }
    let stats = try await store.dailyStats(from: Date(timeIntervalSince1970: base - 86_400), to: Date(timeIntervalSince1970: base + 3 * 86_400), utcOffset: 0)
    #expect(stats.count == 2)
    #expect(abs(stats[0].cpu - 0.2) < 1e-9 && abs(stats[1].cpu - 0.6) < 1e-9)
    #expect(stats[0].recorded == 120) // raw tier: one second per row
    #expect(stats[0].energyJoules > 0)
}

@Test func migratesSchema2ToSchema3() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-hist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.sqlite")
    do {
        let s = try HistoryStore(url: url)
        try await s.append(snapshot(at: base, cpu: 0.3))
    }
    // Turn it back into a schema 2 file: drop what schema 3 added.
    do {
        let db = try Database(url: url)
        try db.execute("DROP TABLE app_focus; ALTER TABLE history_points DROP COLUMN disk_free_avg; ALTER TABLE history_points DROP COLUMN disk_free_max; ALTER TABLE history_points DROP COLUMN on_battery_avg; ALTER TABLE history_points DROP COLUMN on_battery_max; UPDATE schema_version SET version = 2 WHERE component = 'history';")
    }
    let s2 = try HistoryStore(url: url)
    #expect(try await s2.series(.cpu, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base)).count == 1)
    try await s2.append(snapshot(at: base + 1, cpu: 0.3))
    #expect(try await s2.series(.onBattery, from: Date(timeIntervalSince1970: base + 1), to: Date(timeIntervalSince1970: base + 1)).first?.avg == 1)
    try await s2.appendFocus([FocusSpan(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 5), bundleID: "a", name: "A")])
}
