import Foundation
import Testing
@testable import VardisStore

/// `VARDIS_BENCH_CACHE=<copy of cleanup.sqlite>` times opening and reading the Disk Cleanup cache.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_BENCH_CACHE"] != nil))
func cacheOpenBenchmark() async throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VARDIS_BENCH_CACHE"]!)
    let clock = ContinuousClock()
    let t = clock.now
    let store = try CleanupCacheStore(url: url)
    let snap = try await store.load()
    print("BENCH cache open+load \(clock.now - t): \(snap.items.count) items, \(snap.units.values.map(\.count).reduce(0, +)) units")
}
