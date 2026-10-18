import Foundation
import Testing
@testable import VardisCleanup

@Test func bulkSizerMatchesFileManagerAndFTS() throws {
    let h = try FakeHome()
    for i in 0..<40 { try h.file("cache/a/\(i % 7)/f\(i).bin", bytes: 3_000 + i * 997) }
    try h.file("cache/top.bin", bytes: 50_000)
    // Symlinks count nothing and are not followed.
    try FileManager.default.createSymbolicLink(at: h.home.appendingPathComponent("cache/link"), withDestinationURL: h.outside)
    try h.file("big.bin", bytes: 5_000_000, in: h.outside)
    let dir = h.home.appendingPathComponent("cache")
    let fm = DiskUsage.allocatedSize(of: dir)
    #expect(fm > 0)
    #expect(FastSizer.bulkAllocatedSize(dir.path) == fm)
    #expect(FastSizer.ftsAllocatedSize(dir.path) == fm)
    let units = SizeUnits.partition(root: dir.path)
    #expect(SizeUnits.measure(units).reduce(0, +) == fm)
}

@Test func partitionSplitsNarrowLevels() throws {
    let h = try FakeHome()
    // store/v3/files/00..1f: narrow levels are opened until a wide one is found.
    for i in 0..<32 { try h.file(String(format: "store/v3/files/%02x/blob", i), bytes: 4_096) }
    try h.file("store/v3/index.json", bytes: 100)
    let units = SizeUnits.partition(root: h.home.appendingPathComponent("store").path)
    #expect(units.filter { !$0.isFileSet }.count == 32)
    #expect(units.contains { $0.isFileSet && $0.path.hasSuffix("store/v3") })
}

@Test func refreshRemeasuresOnlyChangedUnits() async throws {
    let h = try FakeHome()
    for i in 0..<20 { try h.file(String(format: "Library/Caches/go-build/%02x/obj", i), bytes: 10_000) }
    let config = CleanupConfig(home: h.home, projectRoots: [], enabled: [.packageCaches])
    let s = CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: nil))
    let first = await s.fullScan()
    let go = try #require(first.items.first { $0.title == "Go" })
    #expect(first.measuredUnits == 20)

    // Nothing changed under the cache: nothing re-measured.
    let same = await s.refresh(first, changes: [ChangedPath(path: h.home.appendingPathComponent("Desktop").path, recursive: false)])
    #expect(same.measuredUnits == 0)
    #expect(same.items.first { $0.title == "Go" }?.sizeBytes == go.sizeBytes)

    // One shard grows: only it is measured again.
    let shard = h.home.appendingPathComponent("Library/Caches/go-build/03")
    try h.file("Library/Caches/go-build/03/obj2", bytes: 200_000)
    let canon = CleanupScanner.canonicalPath(shard)
    let after = await s.refresh(first, changes: [ChangedPath(path: canon, recursive: false)])
    #expect(after.measuredUnits == 1)
    let grown = try #require(after.items.first { $0.title == "Go" })
    #expect(grown.sizeBytes > go.sizeBytes)
    #expect(grown.sizeBytes == DiskUsage.allocatedSize(of: h.home.appendingPathComponent("Library/Caches/go-build")))

    // A new shard appears: the root is re-listed and only the new shard is measured.
    try h.file("Library/Caches/go-build/ff/obj", bytes: 10_000)
    let root = CleanupScanner.canonicalPath(h.home.appendingPathComponent("Library/Caches/go-build"))
    let added = await s.refresh(after, changes: [ChangedPath(path: root, recursive: false)])
    #expect(added.measuredUnits == 1)

    // The cache disappears: the item is dropped.
    try FileManager.default.removeItem(at: h.home.appendingPathComponent("Library/Caches/go-build"))
    let gone = await s.refresh(added, changes: [ChangedPath(path: root, recursive: true)])
    #expect(gone.items.isEmpty)
}

@Test func allowedRootsLimitTheScan() async throws {
    let h = try FakeHome()
    try h.file("Library/Caches/go-build/00/obj", bytes: 10_000)
    try h.file(".npm/_cacache/x", bytes: 10_000)
    let allowed = [h.home.appendingPathComponent("Library/Caches")]
    let config = CleanupConfig(home: h.home, projectRoots: [], enabled: [.packageCaches, .docker], allowedRoots: allowed)
    let s = CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: dockerJSON))
    let r = await s.fullScan()
    #expect(r.items.map(\.title) == ["Go"])
    #expect(CleanupScanner.watchedRoots(config).allSatisfy { $0.contains("Library/Caches") })
}

@Test func itemsRoundTripThroughJSON() throws {
    let item = CleanupItem(id: "x", category: .docker, title: "Images", detail: "d", urls: [], sizeBytes: 5, lastUsed: nil,
                           safety: .reviewFirst, selectedByDefault: false, advisoryCommand: "docker system prune", scannedAt: Date(timeIntervalSince1970: 100))
    let back = try JSONDecoder().decode(CleanupItem.self, from: JSONEncoder().encode(item))
    #expect(back == item)
}

@Test func trashReportsMovedIDs() async throws {
    let h = try FakeHome()
    try h.file("Library/Caches/go-build/00/obj", bytes: 10_000)
    let s = CleanupScanner(config: CleanupConfig(home: h.home, projectRoots: [], enabled: [.packageCaches]),
                           simctl: StubSimctl(json: nil), docker: StubDocker(json: nil)) { _ in }
    let r = await s.fullScan()
    let t = await s.trash(r.items)
    #expect(t.movedIDs == r.items.map(\.id))
    #expect(r.removing(Set(t.movedIDs)).groups.isEmpty)
}
