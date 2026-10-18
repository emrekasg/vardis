import Foundation
import Testing
@testable import VardisCleanup

// MARK: - Fixtures

struct StubSimctl: SimctlRunner {
    var json: Data?
    func unavailableDevicesJSON() async -> Data? { json }
}

/// Answers `system df -v` with `json` and every other command with status 0. Records what ran;
/// nothing ever reaches a real Docker engine.
final class StubDocker: DockerRunner, @unchecked Sendable {
    let json: Data?
    var failing: Set<String> = []
    private let lock = NSLock()
    private var calls: [[String]] = []

    init(json: Data?) { self.json = json }

    var ran: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }

    func docker(_ arguments: [String], timeout: TimeInterval) async -> CommandOutput? {
        guard let json else { return nil }
        lock.withLock { calls.append(arguments) }
        if arguments.starts(with: ["system", "df"]) { return CommandOutput(status: 0, stdout: json) }
        if arguments.first == "inspect" {
            return CommandOutput(status: 0, stdout: Data("c0ffee000001 2026-08-01T10:00:00.5Z\n".utf8))
        }
        if arguments.starts(with: ["image", "inspect"]) {
            return CommandOutput(status: 0, stdout: Data("sha256:bbbb 0001-01-01 00:00:00 +0000 UTC\n".utf8))
        }
        if arguments.starts(with: ["volume", "inspect"]) {
            return CommandOutput(status: 0, stdout: Data("pgdata 2026-07-01T00:00:00Z\n".utf8))
        }
        if arguments.contains(where: failing.contains) { return CommandOutput(status: 1, stdout: Data(), stderr: "Error response from daemon: conflict") }
        return CommandOutput(status: 0, stdout: Data())
    }
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
{"Images":[
 {"Containers":"0","CreatedAt":"2026-01-02 10:00:00 +0300 +03","Digest":"","ID":"sha256:aaaa","Repository":"<none>","Tag":"<none>","Size":"2.08GB","UniqueSize":"2GB","SharedSize":"80MB"},
 {"Containers":"0","CreatedAt":"2026-03-01 10:00:00 +0000 UTC","Digest":"sha256:dd","ID":"sha256:bbbb","Repository":"postgres","Tag":"15","Size":"400MB","UniqueSize":"N/A"},
 {"Containers":"0","CreatedAt":"2026-03-01 10:00:00 +0000 UTC","Digest":"sha256:dd","ID":"sha256:bbbb","Repository":"postgres","Tag":"latest","Size":"400MB","UniqueSize":"N/A"},
 {"Containers":"2","CreatedAt":"2026-03-01 10:00:00 +0000 UTC","Digest":"","ID":"sha256:cccc","Repository":"used","Tag":"1","Size":"1GB","UniqueSize":"1GB"}
],
"Containers":[
 {"ID":"c0ffee000001","Names":"old-api","Image":"api:dev","State":"exited","Status":"Exited (0) 2 months ago","Size":"12MB","CreatedAt":"2026-07-01 10:00:00 +0000 UTC"},
 {"ID":"c0ffee000002","Names":"web","Image":"web:dev","State":"running","Status":"Up","Size":"1MB","CreatedAt":"2026-07-01 10:00:00 +0000 UTC"}
],
"Volumes":[
 {"Name":"pgdata","Links":"0","Size":"3GB"},
 {"Name":"inuse","Links":"1","Size":"9GB"}
],
"BuildCache":[
 {"ID":"x1","InUse":"false","Shared":"false","Size":"500MB","LastUsedAt":"2026-01-01 09:00:00.12 +0000 UTC","CreatedAt":"2026-01-01 09:00:00 +0000 UTC"},
 {"ID":"x2","InUse":"false","Shared":"true","Size":"100MB","LastUsedAt":"2099-01-01 09:00:00 +0000 UTC","CreatedAt":"2026-01-01 09:00:00 +0000 UTC"}
]}
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
    #expect(groups.map(\.category) == [.xcode, .simulators, .nodeModules, .packageCaches, .dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes])

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

@Test func dockerUnusedObjects() async throws {
    let h = try buildHome()
    let all: Set<CleanupCategory> = [.dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes]
    let groups = await scanner(h, enabled: all).scan()
    let images = try #require(group(groups, .dockerImages)).items
    #expect(images.count == 2) // the image a container uses is not offered
    let dangling = try #require(images.first { $0.title.hasPrefix("Untagged") })
    #expect(dangling.selectedByDefault && dangling.sizeBytes == 2_000_000_000 && dangling.docker?.refs == ["sha256:aaaa"])
    let pg = try #require(images.first { $0.title.contains("postgres") })
    #expect(!pg.selectedByDefault && pg.safety == .redownloads && pg.isUpperBound)
    #expect(Set(pg.docker?.refs ?? []) == ["postgres:15", "postgres:latest"])
    #expect(pg.docker?.arguments.first == "rmi")

    let containers = try #require(group(groups, .dockerContainers)).items
    #expect(containers.map(\.title) == ["old-api"]) // running one is skipped
    #expect(containers[0].safety == .reviewFirst && !containers[0].selectedByDefault)
    #expect(containers[0].lastUsed == DockerScan.parseISO("2026-08-01T10:00:00.5Z"))
    #expect(containers[0].detail.contains("not run for"))

    let volumes = try #require(group(groups, .dockerVolumes)).items
    #expect(volumes.map(\.title) == ["pgdata"])
    #expect(volumes[0].safety == .notRebuildable && !volumes[0].selectedByDefault && volumes[0].detail.hasPrefix("Created"))

    let cache = try #require(group(groups, .dockerBuildCache)).items
    let old = try #require(cache.first { $0.id == "docker-buildcache:old" })
    #expect(old.selectedByDefault && old.sizeBytes == 500_000_000 && old.docker?.arguments == ["builder", "prune", "-f", "--filter", "until=720h"])
    #expect(cache.first { $0.id == "docker-buildcache:recent" }?.selectedByDefault == false)
    #expect(groups.flatMap(\.items).allSatisfy { $0.urls.isEmpty && $0.isPermanent && !$0.isAdvisory })
}

@Test func dockerRemovalUsesTheCLIAndNeverTheTrash() async throws {
    let h = try buildHome()
    let stub = StubDocker(json: dockerJSON)
    stub.failing = ["postgres:15"]
    let log = TrashLog()
    let config = CleanupConfig(home: h.home, projectRoots: [], enabled: [.dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes])
    let s = CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: stub, trasher: { log.add($0) })
    let items = await s.scan().flatMap(\.items)
    let r = await s.remove(items)
    #expect(log.all.isEmpty)
    let removals = stub.ran.filter { !$0.contains("df") && !$0.contains("inspect") }
    // Containers before images; one full prune covers both build cache items.
    #expect(removals.first == ["rm", "c0ffee000001"])
    #expect(removals.filter { $0.first == "builder" } == [["builder", "prune", "-f"]])
    #expect(removals.contains(["volume", "rm", "pgdata"]))
    #expect(r.failures.map(\.itemID) == ["docker-image:sha256:bbbb"])
    #expect(r.permanentlyRemoved == items.count - 1 && r.trashed.isEmpty)
    // The Trash path refuses Docker items outright.
    let t = await s.trash(items)
    #expect(t.moved == 0 && t.failures.count == items.count)
}

@Test func goDateParsing() {
    let d = DockerScan.parseGoDate("2026-10-16 21:23:30 +0300 +03")
    #expect(d == DockerScan.parseISO("2026-10-16T18:23:30Z"))
    #expect(DockerScan.parseGoDate("2026-04-10 09:49:56.347963988 +0000 UTC") != nil)
    #expect(DockerScan.parseGoDate("0001-01-01 00:00:00 +0000 UTC") == nil)
}

@Test func newPathRulesAndBuildFolders() async throws {
    let h = try FakeHome()
    try h.file("Library/Caches/org.swift.swiftpm/repositories/x", bytes: 9_000)
    try h.file("go/pkg/mod/cache/x", bytes: 9_000)
    try h.file("Library/Caches/JetBrains/IntelliJIdea2026.1/index/x", bytes: 9_000)
    try h.file("Library/Application Support/Code/CachedData/x", bytes: 9_000)
    try h.file(".android/avd/Pixel_8.avd/userdata.img", bytes: 9_000)
    try h.file("Library/Developer/Xcode/UserData/Previews/x", bytes: 9_000)
    // Projects: a Rust crate, a JS app with ignored dist and a non-ignored build folder.
    try h.file("code/crate/Cargo.toml", bytes: 10, age: 60)
    try h.file("code/crate/target/debug/x", bytes: 20_000, age: 60)
    try h.file("code/crate/.git/logs/HEAD", bytes: 10, age: 60)
    try h.file("code/web/package.json", bytes: 10, age: 60)
    try h.file("code/web/.gitignore", bytes: 0, age: 60)
    try "/dist\nnode_modules/\n".write(to: h.home.appendingPathComponent("code/web/.gitignore"), atomically: true, encoding: .utf8)
    try h.file("code/web/dist/app.js", bytes: 20_000, age: 60)
    try h.file("code/web/build/script.sh", bytes: 20_000, age: 60)
    for d in ["code/crate/.git/logs", "code/crate/.git", "code/crate", "code/web", "code/crate/target", "code/web/dist", "code/web/build"] { try h.setAge(h.home.appendingPathComponent(d), days: 60) }
    try h.setAge(h.home.appendingPathComponent("code/web/.gitignore"), days: 60)

    let config = CleanupConfig(home: h.home, projectRoots: [h.home.appendingPathComponent("code")], enabled: CleanupConfig.defaultEnabled)
    let groups = await CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: nil)).scan()
    let caches = try #require(group(groups, .packageCaches)).items
    #expect(caches.first { $0.title == "SwiftPM" }?.safety == .redownloads)
    let go = try #require(caches.first { $0.title == "Go modules" })
    #expect(go.isAdvisory && go.urls.isEmpty && go.sizeBytes > 0)
    let ide = try #require(group(groups, .ideCaches)).items
    #expect(Set(ide.map(\.title)) == ["IntelliJIdea2026.1", "VS Code · CachedData", "Pixel 8"])
    #expect(ide.first { $0.title == "Pixel 8" }?.safety == .reviewFirst)
    #expect(group(groups, .xcode)?.items.first?.title == "Xcode Previews")

    let builds = try #require(group(groups, .buildFolders)).items
    #expect(Set(builds.map(\.title)) == ["crate/target", "web/dist"]) // build/ is not git-ignored
    let target = try #require(builds.first { $0.title == "crate/target" })
    #expect(target.selectedByDefault && target.projectRoot?.hasSuffix("code/crate") == true && target.projectActive != nil)
    #expect(builds.first { $0.title == "web/dist" }?.selectedByDefault == false)
}

@Test func putBackRestoresTrashedItems() async throws {
    let h = try buildHome()
    let bin = h.root.appendingPathComponent("FakeTrash")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let config = CleanupConfig(home: h.home, projectRoots: [], enabled: [.packageCaches])
    let s = CleanupScanner(config: config, simctl: StubSimctl(json: nil), docker: StubDocker(json: nil), trashTo: { url in
        let dest = bin.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    })
    let items = await s.scan().flatMap(\.items).filter(\.selectedByDefault)
    let r = await s.trash(items)
    #expect(r.trashed.count == items.count && !items.isEmpty)
    for i in items { #expect(!FileManager.default.fileExists(atPath: i.urls[0].path)) }
    // Something new took one place: that one stays in the Trash.
    let blocked = r.trashed[0]
    try FileManager.default.createDirectory(at: blocked.original, withIntermediateDirectories: true)
    let back = await s.putBack(r.trashed)
    #expect(back.restored.count == r.trashed.count - 1 && back.failures.count == 1)
    for e in back.restored { #expect(FileManager.default.fileExists(atPath: e.original.path)) }
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
    let docker = all.filter { $0.isAdvisory || $0.isPermanent }
    let result = await s.trash(selected + evil + docker)

    let expectedMoved = selected.filter { !$0.isAdvisory && !$0.isPermanent }
    #expect(result.moved == expectedMoved.count)
    #expect(result.bytes == expectedMoved.reduce(0) { $0 + $1.sizeBytes })
    #expect(Set(log.all.map(\.path)) == Set(expectedMoved.flatMap(\.urls).map(\.path)))
    #expect(Set(result.failures.map(\.itemID)) == Set(["x", "y", "z"] + docker.map(\.id)))
    #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    // Unselected items stay.
    for item in all where !item.selectedByDefault && !item.isAdvisory && !item.isPermanent {
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
    let config = CleanupConfig(home: home, projectRoots: [home], enabled: Set(CleanupCategory.current))
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
