import Foundation
import Testing
@testable import VardisCleanup

/// `VARDIS_BENCH=1 swift test -c release --filter sizerBenchmark` measures the walkers on this Mac's real caches.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_BENCH"] == "1"))
func sizerBenchmark() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dirs = ["Library/Caches/go-build", "Library/pnpm/store"].map { home.appendingPathComponent($0) }
    func time(_ label: String, _ body: () -> UInt64) {
        let t = Date()
        let v = body()
        print(String(format: "BENCH %@ %.2f s %.2f GB", label, Date().timeIntervalSince(t), Double(v) / 1e9))
    }
    func pool(_ units: [SizeUnit], threads: Int, _ f: @escaping @Sendable (String) -> UInt64) -> UInt64 {
        let lock = NSLock()
        nonisolated(unsafe) var next = 0
        nonisolated(unsafe) var total: UInt64 = 0
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            Thread {
                while true {
                    lock.lock(); let i = next; next += 1; lock.unlock()
                    guard i < units.count else { break }
                    let u = units[i]
                    let v = u.isFileSet ? (u.bytes ?? 0) : f(u.path)
                    lock.lock(); total += v; lock.unlock()
                }
                group.leave()
            }.start()
        }
        group.wait()
        return total
    }
    for d in dirs {
        let name = d.lastPathComponent
        let units = SizeUnits.partition(root: d.path)
        if ProcessInfo.processInfo.environment["VARDIS_BENCH_SERIAL"] == "1" {
            time("\(name) filemanager serial") { DiskUsage.allocatedSize(of: d) }
            time("\(name) fts serial") { FastSizer.ftsAllocatedSize(d.path) }
            time("\(name) bulk serial") { FastSizer.bulkAllocatedSize(d.path) }
        }
        time("\(name) bulk concurrentPerform (\(units.count) units)") { SizeUnits.measure(units).reduce(0, +) }
        for n in [10, 16, 32, 64] {
            time("\(name) bulk \(n) threads") { pool(units, threads: n) { FastSizer.bulkAllocatedSize($0) } }
            time("\(name) fts \(n) threads") { pool(units, threads: n) { FastSizer.ftsAllocatedSize($0) } }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_BENCH"] == "1"))
func scanPhasesBenchmark() async {
    let clock = ContinuousClock()
    var t = clock.now
    _ = await SystemDockerRunner().systemDFJSON()
    print("BENCH docker df \(clock.now - t)")
    t = clock.now
    _ = await SystemSimctlRunner().unavailableDevicesJSON()
    print("BENCH simctl \(clock.now - t)")
    let fsOnly = CleanupConfig(enabled: [.xcode, .nodeModules, .packageCaches])
    let s = CleanupScanner(config: fsOnly, simctl: StubSimctl(json: nil), docker: StubDocker(json: nil))
    t = clock.now
    let r = await s.fullScan()
    print("BENCH files-only full scan \(clock.now - t), \(r.items.count) items, \(r.units.values.map(\.count).reduce(0, +)) units")
    t = clock.now
    let again = await s.refresh(r, changes: [ChangedPath(path: NSHomeDirectory() + "/Library/Caches/go-build/3a", recursive: false)])
    print("BENCH refresh one go shard \(clock.now - t), measured \(again.measuredUnits)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_BENCH"] == "1"))
func perCategoryBenchmark() async {
    let clock = ContinuousClock()
    for c in [CleanupCategory.xcode, .nodeModules, .packageCaches] {
        let s = CleanupScanner(config: CleanupConfig(enabled: [c]), simctl: StubSimctl(json: nil), docker: StubDocker(json: nil))
        let t = clock.now
        let r = await s.fullScan()
        print("BENCH category \(c) \(clock.now - t) \(r.items.count) items \(r.units.values.map(\.count).reduce(0, +)) units")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_BENCH"] == "1"))
func perCacheBenchmark() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    for rule in CleanupScanner.packageCacheRules {
        let d = home.appendingPathComponent(rule.path).path
        guard FileManager.default.fileExists(atPath: d) else { continue }
        let t = Date()
        let units = SizeUnits.partition(root: d)
        let p = Date().timeIntervalSince(t)
        let total = SizeUnits.measure(units).reduce(0, +)
        print(String(format: "BENCH cache %@ partition %.2f s, total %.2f s, %d units, %.2f GB", rule.name, p, Date().timeIntervalSince(t), units.count, Double(total) / 1e9))
    }
}

