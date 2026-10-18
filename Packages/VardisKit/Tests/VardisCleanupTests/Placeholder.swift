import Foundation
import Testing
@testable import VardisCleanup

// MARK: - Fixtures

struct StubSimctl: SimctlRunner {
    var json: Data?
    func unavailableDevicesJSON() async -> Data? { json }
}

struct StubDocker: DockerRunner {
    var json: Data?
    func systemDFJSON() async -> Data? { json }
}

final class FakeHome {
    let root: URL
    let home: URL
    let outside: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vardis-cleanup-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 10_000, age days: Double = 0, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        try setAge(url, days: days)
        return url
    }

    func setAge(_ url: URL, days: Double) throws {
        let d = Date().addingTimeInterval(-days * 86_400)
        try fm.setAttributes([.modificationDate: d], ofItemAtPath: url.path)
    }

    /// Ages a directory and everything directly inside it.
    func age(dir rel: String, days: Double) throws {
        let url = home.appendingPathComponent(rel)
        for c in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try setAge(c, days: days) }
        try setAge(url, days: days)
    }
}

let simJSON = """
{"devices":{
 "com.apple.CoreSimulator.SimRuntime.iOS-16-0":[
   {"udid":"AAAA-1111","name":"iPhone 14","isAvailable":false,"availabilityError":"runtime profile not found"},
   {"udid":"MISSING-DIR","name":"iPhone 13","isAvailable":false}
 ]}}
""".data(using: .utf8)!

let dockerJSON = """
{"Active":"1","Reclaimable":"1.5GB (75%)","Size":"2GB","TotalCount":"5","Type":"Images"}
{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
{"Active":"0","Reclaimable":"512.5kB","Size":"512.5kB","TotalCount":"3","Type":"Build Cache"}
""".data(using: .utf8)!

func buildHome() throws -> FakeHome {
    let h = try FakeHome()
    let dd = "Library/Developer/Xcode/DerivedData"
    try h.file("\(dd)/OldApp-abcdefghijklmnopqrstuvwxyz/Build/a.o", bytes: 50_000)
    try h.age(dir: "\(dd)/OldApp-abcdefghijklmnopqrstuvwxyz/Build", days: 60)
    try h.age(dir: "\(dd)/OldApp-abcdefghijklmnopqrstuvwxyz", days: 60)
    try h.file("\(dd)/NewApp-zyxwvutsrqponmlkjihgfedcba/Build/b.o", bytes: 20_000)
    try h.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 5_000)
    try h.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A1)/Symbols/dyld", bytes: 30_000)
    try h.age(dir: "Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A1)", days: 200)
    try h.file("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A1)/Symbols/dyld", bytes: 30_000)
    try h.file("Library/Developer/CoreSimulator/Devices/AAAA-1111/data/blob", bytes: 40_000)

    // node_modules: old project, recent project, nested node_modules that must not be listed,
    // and one deeper than 4 levels.
    try h.file("Projects/old-web/node_modules/left-pad/index.js", bytes: 8_000)
    try h.file("Projects/old-web/node_modules/left-pad/node_modules/inner/index.js", bytes: 8_000)
    try h.file("Projects/old-web/package.json", bytes: 100, age: 40)
    try h.setAge(h.home.appendingPathComponent("Projects/old-web/node_modules"), days: 40)
    try h.setAge(h.home.appendingPathComponent("Projects/old-web"), days: 40)
    try h.file("Projects/new-web/node_modules/react/index.js", bytes: 9_000)
    try h.file("Projects/new-web/package.json", bytes: 100, age: 0)
    try h.file("Projects/a/b/c/d/too-deep/node_modules/x/index.js", bytes: 9_000)
    try h.file("Projects/.git/node_modules/x/index.js", bytes: 9_000)

    try h.file("Library/Caches/Homebrew/downloads/pkg.tar.gz", bytes: 70_000)
    try h.file(".npm/_cacache/content/x", bytes: 60_000)
    try h.file("Library/Caches/pip/http/x", bytes: 10_000)
    try h.fm.createDirectory(at: h.home.appendingPathComponent(".docker"), withIntermediateDirectories: true)
    return h
}

func scanner(_ h: FakeHome, enabled: Set<CleanupCategory> = CleanupConfig.defaultEnabled, trasher: CleanupScanner.Trasher? = nil) -> CleanupScanner {
    let config = CleanupConfig(home: h.home, projectRoots: [h.home.appendingPathComponent("Projects")], enabled: enabled)
    return CleanupScanner(config: config, simctl: StubSimctl(json: simJSON), docker: StubDocker(json: dockerJSON), trasher: trasher)
}

func group(_ groups: [CleanupGroup], _ c: CleanupCategory) -> CleanupGroup? { groups.first { $0.category == c } }

// MARK: - Scan

@Test func groupsAndDefaults() async throws {
    let h = try buildHome()
    let groups = await scanner(h).scan()
    #expect(groups.map(\.category) == [.xcode, .simulators, .nodeModules, .docker, .packageCaches])

    let xcode = try #require(group(groups, .xcode))
    let byTitle = Dictionary(uniqueKeysWithValues: xcode.items.map { ($0.title, $0) })
    let old = try #require(byTitle["OldApp"])
    #expect(old.safety == .rebuildable && old.selectedByDefault)
    let new = try #require(byTitle["NewApp"])
    #expect(new.safety == .rebuildable && !new.selectedByDefault)
    let archives = try #require(byTitle["Archives"])
    #expect(archives.safety == .notRebuildable && !archives.selectedByDefault)
    #expect(byTitle["17.0 (21A1)"]?.safety == .redownloads && byTitle["17.0 (21A1)"]?.selectedByDefault == true)
    #expect(byTitle["18.0 (22A1)"]?.selectedByDefault == false)
    #expect(xcode.items.allSatisfy { $0.sizeBytes > 0 })
    #expect(old.sizeBytes >= 50_000)
    #expect(xcode.totalBytes >= xcode.selectedBytes && xcode.selectedBytes > 0)
    // Largest first.
    #expect(xcode.items.map(\.sizeBytes) == xcode.items.map(\.sizeBytes).sorted(by: >))

    let sims = try #require(group(groups, .simulators))
    #expect(sims.items.count == 1) // device without a folder is skipped
    #expect(sims.items[0].title == "iPhone 14" && sims.items[0].detail.hasPrefix("iOS 16.0") && sims.items[0].sizeBytes > 0)

    let caches = try #require(group(groups, .packageCaches))
    let cacheSel = Dictionary(uniqueKeysWithValues: caches.items.map { ($0.title, $0.selectedByDefault) })
    #expect(cacheSel == ["Homebrew": true, "npm": true, "pip": false])
    #expect(caches.items.allSatisfy { $0.safety == .redownloads })
}

@Test func nodeModulesRules() async throws {
    let h = try buildHome()
    let groups = await scanner(h, enabled: [.nodeModules]).scan()
    let nm = try #require(group(groups, .nodeModules))
    // Only the two top-level node_modules: the nested one, the >4-deep one and the one in .git are not listed.
    #expect(nm.items.count == 2)
    #expect(nm.items.allSatisfy { $0.urls.count == 1 && $0.urls[0].lastPathComponent == "node_modules" })
    #expect(!nm.items.contains { $0.urls[0].path.contains("node_modules/left-pad") })
    let old = try #require(nm.items.first { $0.title == "old-web" })
    #expect(old.safety == .rebuildable && old.selectedByDefault)
    #expect(old.sizeBytes >= 16_000) // nested package is still counted in the size
    let new = try #require(nm.items.first { $0.title == "new-web" })
    #expect(new.safety == .activeProject && !new.selectedByDefault)
}

@Test func nodeModulesWalkNeverDescends() throws {
    let h = try buildHome()
    let found = DiskUsage.findNodeModules(under: h.home.appendingPathComponent("Projects"))
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.pathComponents.filter { $0 == "node_modules" }.count == 1 })
}

@Test func dockerIsAdvisory() async throws {
    let h = try buildHome()
    let groups = await scanner(h, enabled: [.docker]).scan()
    let docker = try #require(group(groups, .docker))
    #expect(docker.items.map(\.title) == ["Images", "Build Cache"]) // 0 B Containers dropped
    #expect(docker.items[0].sizeBytes == 1_500_000_000)
    #expect(docker.items[1].sizeBytes == 512_500)
    #expect(docker.items.allSatisfy { $0.urls.isEmpty && $0.isAdvisory && $0.advisoryCommand == "docker system prune" && !$0.selectedByDefault })
}

@Test func runnersAbsentSkipSilently() async throws {
    let h = try buildHome()
    let config = CleanupConfig(home: h.home, projectRoots: [], enabled: [.simulators, .docker])
    let groups = await CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: Data("garbage".utf8))).scan()
    #expect(groups.isEmpty)
}

@Test func largeOldFilesOptIn() async throws {
    let h = try buildHome()
    try h.file("Downloads/old.dmg", bytes: 3_000_000, age: 400)
    try h.file("Downloads/new.dmg", bytes: 3_000_000, age: 1)
    try h.file("Movies/small.mov", bytes: 1_000, age: 400)
    let off = await scanner(h).scan()
    #expect(group(off, .largeOldFiles) == nil)

    let config = CleanupConfig(home: h.home, projectRoots: [], largeFileMinBytes: 2_000_000, enabled: [.largeOldFiles])
    let groups = await CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: nil)).scan()
    let large = try #require(group(groups, .largeOldFiles))
    #expect(large.items.map(\.title) == ["old.dmg"])
    #expect(large.items[0].safety == .reviewFirst && !large.items[0].selectedByDefault)
}

@Test func symlinksAreNotFollowed() throws {
    let h = try buildHome()
    let big = try h.file("blob", bytes: 500_000, in: h.outside)
    let dir = h.home.appendingPathComponent("Library/Caches/Homebrew")
    try h.fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: big)
    try h.fm.createSymbolicLink(at: dir.appendingPathComponent("linkdir"), withDestinationURL: h.outside)
    #expect(DiskUsage.allocatedSize(of: dir) < 200_000)
    #expect(DiskUsage.allocatedSize(of: dir.appendingPathComponent("linkdir")) == 0)
}

@Test func helpers() {
    #expect(CleanupScanner.derivedDataTitle("My-App-abcdefghijklmnopqrstuvwxyz") == "My-App")
    #expect(CleanupScanner.derivedDataTitle("ModuleCache.noindex") == "ModuleCache.noindex")
    #expect(DockerParser.parseSize("1.2GB (40%)") == 1_200_000_000)
    #expect(DockerParser.parseSize("0B") == 0)
    #expect(SimctlParser.runtimeLabel("com.apple.CoreSimulator.SimRuntime.watchOS-10-2") == "watchOS 10.2")
}

// MARK: - Trash

final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

@Test func trashMovesOnlyGivenItemsAndRefusesOutsideHome() async throws {
    let h = try buildHome()
    let log = TrashLog()
    let bin = h.root.appendingPathComponent("FakeTrash")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let s = scanner(h) { url in
        log.add(url)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
    }
    let groups = await s.scan()
    let all = groups.flatMap(\.items)
    let selected = all.filter { $0.selectedByDefault }
    #expect(!selected.isEmpty)

    let outsideFile = try h.file("keep.txt", in: h.outside)
    let escape = h.home.appendingPathComponent("Projects/../../outside/keep.txt")
    let evil = [
        CleanupItem(id: "x", category: .largeOldFiles, title: "x", detail: "", urls: [outsideFile], sizeBytes: 1, lastUsed: nil, safety: .reviewFirst, selectedByDefault: true),
        CleanupItem(id: "y", category: .largeOldFiles, title: "y", detail: "", urls: [escape], sizeBytes: 1, lastUsed: nil, safety: .reviewFirst, selectedByDefault: true),
        CleanupItem(id: "z", category: .largeOldFiles, title: "z", detail: "", urls: [h.home], sizeBytes: 1, lastUsed: nil, safety: .reviewFirst, selectedByDefault: true),
    ]
    let docker = all.filter(\.isAdvisory)
    let result = await s.trash(selected + evil + docker)

    let expectedMoved = selected.filter { !$0.isAdvisory }
    #expect(result.moved == expectedMoved.count)
    #expect(result.bytes == expectedMoved.reduce(0) { $0 + $1.sizeBytes })
    #expect(Set(log.all.map(\.path)) == Set(expectedMoved.flatMap(\.urls).map(\.path)))
    #expect(Set(result.failures.map(\.itemID)) == Set(["x", "y", "z"] + docker.map(\.id)))
    #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    // Unselected items stay.
    for item in all where !item.selectedByDefault && !item.isAdvisory {
        #expect(FileManager.default.fileExists(atPath: item.urls[0].path))
    }
}

@Test func realTrashItemOnTempFile() async throws {
    let h = try FakeHome()
    let f = try h.file("Library/Caches/Homebrew/vardis-trash-test.bin", bytes: 4_096)
    let s = CleanupScanner(config: CleanupConfig(home: h.home, projectRoots: [], enabled: [.packageCaches]),
                           simctl: StubSimctl(json: nil), docker: StubDocker(json: nil))
    let item = try #require(await s.scan().first?.items.first)
    let result = await s.trash([item])
    #expect(result.moved == 1 && result.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.path))
    // Remove our own test folder from the user's Trash.
    let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    if let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
        for n in names where n.hasPrefix("Homebrew") {
            let u = trash.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("vardis-trash-test.bin").path) { try? FileManager.default.removeItem(at: u) }
        }
    }
}

// MARK: - Real home (read-only)

@Test(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_REAL_HOME_SCAN"] == "1"))
func realHomeScanTiming() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let config = CleanupConfig(home: home, projectRoots: [home], enabled: Set(CleanupCategory.allCases))
    let s = CleanupScanner(config: config) { _ in throw CocoaError(.featureUnsupported) } // never trashes
    let clock = ContinuousClock()
    let start = clock.now
    let groups = await s.scan()
    let elapsed = clock.now - start
    print("REAL-HOME scan: \(elapsed)")
    for g in groups {
        print("REAL-HOME \(g.category.rawValue): items=\(g.items.count) total=\(g.totalBytes / 1_000_000) MB selected=\(g.selectedBytes / 1_000_000) MB")
    }
}
