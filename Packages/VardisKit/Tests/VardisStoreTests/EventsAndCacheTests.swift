import Foundation
import Testing
import VardisCore
@testable import VardisStore

private func snap(_ t: TimeInterval, pressure: MemoryPressure = .normal, swap: UInt64 = 0, apps: [(String, Double)] = []) -> Snapshot {
    Snapshot(timestamp: Date(timeIntervalSince1970: t), cpu: CPUSample(user: 0.1, system: 0, perCore: [0.1]),
             memory: MemorySample(total: 8_000_000_000, app: 1, wired: 0, compressed: 0, cached: 0, free: 0, swapUsed: swap, pressure: pressure),
             disk: DiskSample(totalBytes: 0, freeBytes: 0, readBytesPerSecond: 0, writeBytesPerSecond: 0),
             network: NetworkSample(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, receivedTotal: 0, sentTotal: 0),
             battery: nil, gpu: nil,
             apps: apps.map { AppSample(id: $0.0, name: $0.0, bundleURL: nil, isSystem: false, processIDs: [1], cpu: $0.1, memory: 1, energyWatts: 0,
                                        diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0) },
             processCount: 1, uptime: 0)
}

@Test func pressureAndSwapSteps() {
    var d = SnapshotDetector()
    #expect(d.ingest(snap(0)).isEmpty)
    #expect(d.ingest(snap(1, pressure: .warning)).map(\.detail) == ["warning"])
    #expect(d.ingest(snap(2, pressure: .warning)).isEmpty)
    #expect(d.ingest(snap(3, pressure: .normal)).map(\.detail) == ["normal"])
    #expect(d.ingest(snap(4, swap: 500_000_000)).isEmpty)
    let grew = d.ingest(snap(5, swap: 2_100_000_000))
    #expect(grew.map(\.kind) == [.swapGrew] && grew[0].detail == "Swap reached 2.0 GB")
    #expect(d.ingest(snap(6, swap: 2_500_000_000)).isEmpty)
    #expect(d.ingest(snap(7, swap: 1_000_000_000)).isEmpty) // shrinking resets the level silently
    #expect(d.ingest(snap(8, swap: 2_000_000_000)).map(\.kind) == [.swapGrew])
}

@Test func cpuHogNeedsTwoMinutes() {
    var d = SnapshotDetector()
    var events: [HistoryEvent] = []
    for t in stride(from: 0.0, through: 110, by: 5) { events += d.ingest(snap(t, apps: [("Xcode", 0.9)])) }
    #expect(events.isEmpty)
    for t in stride(from: 115.0, through: 300, by: 5) { events += d.ingest(snap(t, apps: [("Xcode", 0.85)])) }
    #expect(events.map(\.kind) == [.cpuHog])
    #expect(events[0].timestamp == Date(timeIntervalSince1970: 0)) // dated to when the spell began
    // Dipping to 0.7 does not end it (hysteresis); 0.3 does.
    events += d.ingest(snap(305, apps: [("Xcode", 0.7)]))
    events += d.ingest(snap(310, apps: [("Xcode", 0.3)]))
    #expect(events.map(\.kind) == [.cpuHog, .cpuHogEnded])
    #expect(events[1].value == 310)
}

@Test func memoryTrendFindsSteadyGrowthOnly() {
    // 6 h of 1-minute points growing 100 MB/h with a little noise.
    var leak: [(t: TimeInterval, bytes: Double)] = []
    for i in 0..<360 {
        let noise: Double = i % 2 == 0 ? 5e6 : -5e6
        let growth: Double = Double(i) * 100e6 / 60
        leak.append((t: Double(i) * 60, bytes: 1e9 + growth + noise))
    }
    let f = try! #require(MemoryTrend.fit(leak))
    #expect(abs(f.bytesPerHour - 100e6) < 1e6)
    #expect(f.r2 > 0.99)
    #expect(MemoryTrend.isSteadyGrowth(f))

    // Same average growth but a sawtooth (caches filling and freeing): low R².
    var saw: [(t: TimeInterval, bytes: Double)] = []
    for i in 0..<360 {
        let tooth: Double = Double(i % 60) * 30e6
        saw.append((t: Double(i) * 60, bytes: 1e9 + tooth + Double(i) * 1e6))
    }
    let g = try! #require(MemoryTrend.fit(saw))
    #expect(!MemoryTrend.isSteadyGrowth(g))

    // Flat: no growth.
    let flat: [(t: TimeInterval, bytes: Double)] = (0..<360).map { i in (t: Double(i) * 60, bytes: 2e9) }
    #expect(MemoryTrend.fit(flat).map { MemoryTrend.isSteadyGrowth($0) } != true)
    // Too short.
    #expect(MemoryTrend.fit(Array(leak.prefix(60))).map { MemoryTrend.isSteadyGrowth($0) } == false)
    #expect(MemoryTrend.fit([(0, 1)]) == nil)
}

@Test func assertionTrackerPairsStartAndEnd() {
    var a = AssertionTracker()
    let t0 = Date(timeIntervalSince1970: 1_000)
    let start = a.update([42: ("Docker Desktop", "com.docker.vmm")], now: t0)
    #expect(start.map(\.kind) == [.keptAwakeStarted] && start[0].app == "Docker Desktop")
    #expect(a.update([42: ("Docker Desktop", "com.docker.vmm")], now: t0.addingTimeInterval(60)).isEmpty)
    let end = a.update([:], now: t0.addingTimeInterval(7_800))
    #expect(end.map(\.kind) == [.keptAwakeEnded] && end[0].value == 7_800)
}

@Test func eventsStoredAndPrunedAndSchema2Columns() async throws {
    let store = try HistoryStore(url: nil)
    let t = 1_800_000_000.0
    try await store.append(events: [HistoryEvent(timestamp: Date(timeIntervalSince1970: t), kind: .appLaunched, app: "Xcode", detail: "com.apple.dt.Xcode"),
                                    HistoryEvent(timestamp: Date(timeIntervalSince1970: t + 100), kind: .keptAwakeEnded, app: "Docker", value: 60)])
    let all = try await store.events(from: Date(timeIntervalSince1970: t - 1), to: Date(timeIntervalSince1970: t + 1_000))
    #expect(all.count == 2 && all[1].value == 60 && all[0].app == "Xcode")
    try await store.prune(retention: 50, now: Date(timeIntervalSince1970: t + 120))
    #expect(try await store.events(from: .distantPast, to: .distantFuture).map(\.kind) == [.keptAwakeEnded])

    // Pressure and compressed are recorded; per-app disk writes come back.
    var s = snapshot(at: t, cpu: 0.4)
    s.memory.pressure = .warning
    s.memory.compressed = 3_000
    s.apps[5].diskWriteBytesPerSecond = 9e6
    try await store.append(s)
    let m = try await store.moment(at: Date(timeIntervalSince1970: t + 0.5))
    #expect(m[.pressure] == 0.5 && m[.compressed] == 3_000 && m[.cpu] == 0.4)
    let rows = try await store.appSeries(from: Date(timeIntervalSince1970: t), to: Date(timeIntervalSince1970: t))
    #expect(rows.first { $0.appID == "app.5" }?.diskWrite == 9e6)
    let byMem = try await store.topApps(at: Date(timeIntervalSince1970: t), limit: 1, by: .memory)
    #expect(byMem.first?.appID == "app.0")
    #expect(try await store.earliest() == Date(timeIntervalSince1970: t))
}

@Test func schema1DatabaseUpgrades() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-up-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("history.sqlite")
    do {
        // A version 1 file, as the first build wrote it.
        let db = try Database(url: url)
        let cols = Metric.schema1.map { "\($0.column)_avg REAL, \($0.column)_max REAL" }.joined(separator: ", ")
        try db.execute("""
        CREATE TABLE schema_version(component TEXT PRIMARY KEY, version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES('history', 1);
        CREATE TABLE history_points(tier INTEGER NOT NULL, ts INTEGER NOT NULL, n INTEGER NOT NULL, \(cols), PRIMARY KEY(tier, ts)) WITHOUT ROWID;
        CREATE TABLE history_apps(tier INTEGER NOT NULL, ts INTEGER NOT NULL, app_id TEXT NOT NULL, name TEXT NOT NULL,
            cpu REAL NOT NULL, memory REAL NOT NULL, energy REAL NOT NULL, PRIMARY KEY(tier, ts, app_id)) WITHOUT ROWID;
        INSERT INTO history_points(tier, ts, n, cpu_avg, cpu_max) VALUES(0, 1800000000, 1, 0.2, 0.2);
        """)
    }
    let store = try HistoryStore(url: url)
    try await store.append(snapshot(at: base + 5, cpu: 0.6))
    let pts = try await store.series(.cpu, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base + 10))
    #expect(pts.map(\.avg) == [0.2, 0.6])
}

@Test func cleanupCacheRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-cc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("cleanup.sqlite")
    let item = CachedCleanupItem(id: "/a", path: "/a", sizeBytes: 42, lastUsed: Date(timeIntervalSince1970: 5), scannedAt: Date(timeIntervalSince1970: 9),
                                 payload: Data("{\"x\":1}".utf8))
    do {
        let c = try CleanupCacheStore(url: url)
        try await c.save(items: [item, CachedCleanupItem(id: "/b", path: "/b", sizeBytes: 1, lastUsed: nil, scannedAt: .now, payload: Data("{}".utf8))],
                         units: ["/a": [CachedSizeUnit(path: "/a/x", isFileSet: false, bytes: 40), CachedSizeUnit(path: "/a", isFileSet: true, bytes: 2)]],
                         replaceAll: true, fullScanAt: Date(timeIntervalSince1970: 9))
        try await c.save(items: [], units: [:], removed: ["/b"])
    }
    let c2 = try CleanupCacheStore(url: url)
    let snap = try await c2.load()
    #expect(snap.items == [item])
    #expect(snap.units["/a"]?.count == 2)
    #expect(snap.fullScanAt == Date(timeIntervalSince1970: 9))
}

@Test func seededDetectorsStayQuietOnRelaunch() {
    var d = SnapshotDetector()
    d.seed(pressure: .warning)
    #expect(d.ingest(snap(0, pressure: .warning)).isEmpty)
    var a = AssertionTracker()
    a.adopt(pid: 7, name: "Docker", reason: "vm", since: Date(timeIntervalSince1970: 0))
    #expect(a.update([7: ("Docker", "vm")], now: Date(timeIntervalSince1970: 60)).isEmpty)
    #expect(a.update([:], now: Date(timeIntervalSince1970: 120)).first?.value == 120)
}
