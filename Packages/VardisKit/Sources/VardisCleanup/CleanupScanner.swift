import Foundation

/// Finds developer junk under `config.home` and moves chosen items to the Trash.
/// Files are never deleted: removal is always `FileManager.trashItem`. The one exception is
/// Docker objects, which only Docker can remove (`remove(_:)`), permanently.
public actor CleanupScanner {
    public typealias Trasher = @Sendable (URL) throws -> Void
    /// Moves a URL to the Trash and returns where it landed.
    public typealias TrashTo = @Sendable (URL) throws -> URL?
    public typealias Mover = @Sendable (URL, URL) throws -> Void

    public let config: CleanupConfig
    private let simctl: any SimctlRunner
    private let docker: any DockerRunner
    private let trashTo: TrashTo
    private let mover: Mover

    public init(
        config: CleanupConfig,
        simctl: any SimctlRunner = SystemSimctlRunner(),
        docker: any DockerRunner = SystemDockerRunner(),
        trasher: Trasher? = nil,
        trashTo: TrashTo? = nil,
        mover: Mover? = nil
    ) {
        self.config = config
        self.simctl = simctl
        self.docker = docker
        if let trashTo {
            self.trashTo = trashTo
        } else if let trasher {
            self.trashTo = { url in try trasher(url); return nil }
        } else {
            self.trashTo = { url in
                var out: NSURL?
                try FileManager().trashItem(at: url, resultingItemURL: &out)
                return out as URL?
            }
        }
        self.mover = mover ?? { from, to in try FileManager().moveItem(at: from, to: to) }
    }

    public func scan() async -> [CleanupGroup] {
        await fullScan().groups
    }

    /// Finds and measures everything. Runs at utility priority.
    public func fullScan() async -> ScanResult {
        let config = config, simctl = simctl, docker = docker
        return await Task.detached(priority: .utility) {
            await Self.runScan(config: config, simctl: simctl, docker: docker, now: Date(), previous: nil, changes: [])
        }.value
    }

    /// Updates `previous` after file system changes: only categories whose folders changed are
    /// looked at again, and inside an item only the pieces under a changed path are re-measured.
    /// Docker and simulator lists are not re-queried (they need external tools); their items are
    /// re-measured or dropped when their folders change.
    public func refresh(_ previous: ScanResult, changes: [ChangedPath]) async -> ScanResult {
        let config = config, simctl = simctl, docker = docker
        return await Task.detached(priority: .utility) {
            await Self.runScan(config: config, simctl: simctl, docker: docker, now: Date(), previous: previous, changes: changes)
        }.value
    }

    /// Folders to watch with FSEvents. Only existing folders are returned.
    public static func watchedRoots(_ config: CleanupConfig) -> [String] {
        var roots: [String] = []
        for c in config.enabled { roots += categoryRoots(c, config: config).map(\.path) }
        let fm = FileManager()
        var seen = Set<String>()
        return roots.filter { fm.fileExists(atPath: $0) && seen.insert($0).inserted && isAllowed($0, config) }
    }

    static func categoryRoots(_ c: CleanupCategory, config: CleanupConfig) -> [URL] {
        let home = config.home
        switch c {
        case .xcode: return [home.appendingPathComponent("Library/Developer/Xcode")]
        case .simulators: return ["Library/Developer/CoreSimulator/Devices", "Library/Developer/CoreSimulator/Caches"].map { home.appendingPathComponent($0) }
        case .nodeModules, .buildFolders: return config.projectRoots
        case .packageCaches, .ideCaches, .backups:
            return pathRules.filter { $0.category == c }.map { home.appendingPathComponent($0.path) }
        case .largeOldFiles: return ["Desktop", "Downloads", "Movies"].map { home.appendingPathComponent($0) }
        case .docker, .dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes: return []
        }
    }

    static func isAllowed(_ path: String, _ config: CleanupConfig) -> Bool {
        guard let allowed = config.allowedRoots else { return true }
        return allowed.contains { a in
            let ap = canonicalPath(a)
            return path == ap || path.hasPrefix(ap + "/")
        }
    }

    static func touches(_ root: String, _ changes: [ChangedPath]) -> Bool {
        changes.contains { $0.path == root || $0.path.hasPrefix(root + "/") || root.hasPrefix($0.path + "/") }
    }

    /// Moves files to the Trash and has Docker remove Docker objects (permanently).
    public func remove(_ items: [CleanupItem]) async -> TrashResult {
        var result = await trash(items.filter { !$0.isPermanent })
        await DockerScan.remove(items.filter(\.isPermanent), runner: docker, into: &result)
        return result
    }

    /// Moves files to the Trash. Docker items are refused here; see `remove(_:)`.
    public func trash(_ items: [CleanupItem]) async -> TrashResult {
        let home = Self.canonicalPath(config.home)
        var result = TrashResult()
        for item in items {
            guard !item.isPermanent else {
                result.failures.append(.init(itemID: item.id, url: nil, reason: "Removed with Docker, never through the Trash"))
                continue
            }
            guard !item.isAdvisory, !item.urls.isEmpty else {
                result.failures.append(.init(itemID: item.id, url: nil, reason: "Nothing to move; run \(item.advisoryCommand ?? "the tool") instead"))
                continue
            }
            let outside = item.urls.filter { !Self.isInside($0, home: home) }
            guard outside.isEmpty else {
                for u in outside { result.failures.append(.init(itemID: item.id, url: u, reason: "Outside the home folder; refused")) }
                continue
            }
            var ok = true
            for u in item.urls {
                do {
                    if let landed = try trashTo(u) {
                        result.trashed.append(TrashedEntry(itemID: item.id, title: item.title, original: u, inTrash: landed,
                                                           bytes: item.urls.count == 1 ? item.sizeBytes : 0))
                    }
                } catch {
                    ok = false
                    result.failures.append(.init(itemID: item.id, url: u, reason: error.localizedDescription))
                }
            }
            if ok {
                result.moved += 1
                result.movedIDs.append(item.id)
                result.bytes += item.sizeBytes
            }
        }
        return result
    }

    /// Moves trashed entries back where they came from, when that place is still free.
    public func putBack(_ entries: [TrashedEntry]) async -> PutBackResult {
        let home = Self.canonicalPath(config.home)
        let fm = FileManager()
        var r = PutBackResult()
        for e in entries {
            guard Self.isInside(e.original, home: home) else { r.failures.append((e, "Outside the home folder; refused")); continue }
            guard fm.fileExists(atPath: e.inTrash.path) else { r.failures.append((e, "No longer in the Trash")); continue }
            guard !fm.fileExists(atPath: e.original.path) else { r.failures.append((e, "Something new is already at its place")); continue }
            guard fm.fileExists(atPath: e.original.deletingLastPathComponent().path) else { r.failures.append((e, "Its folder no longer exists")); continue }
            do {
                try mover(e.inTrash, e.original)
                r.restored.append(e)
            } catch {
                r.failures.append((e, error.localizedDescription))
            }
        }
        return r
    }

    // MARK: - Path safety

    static func canonicalPath(_ url: URL) -> String {
        var p = url.standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Strictly inside home (home itself is refused). The URL's parent chain is resolved so `..`
    /// and symlinked parents cannot escape; the last component itself is not followed.
    static func isInside(_ url: URL, home: String) -> Bool {
        guard url.isFileURL else { return false }
        let std = url.standardizedFileURL
        let name = std.lastPathComponent
        guard !name.isEmpty, name != "/", name != "..", name != "." else { return false }
        let parent = canonicalPath(std.deletingLastPathComponent())
        let full = parent == "/" ? "/" + name : parent + "/" + name
        return home != "/" && full.hasPrefix(home + "/")
    }

    // MARK: - Scan

    private struct Candidate: Sendable {
        var item: CleanupItem
        /// Directory or file to size; nil keeps `item.sizeBytes` as is.
        var sizeURL: URL?
    }

    static func runScan(config: CleanupConfig, simctl: any SimctlRunner, docker: any DockerRunner, now: Date,
                        previous: ScanResult?, changes: [ChangedPath]) async -> ScanResult {
        let enabled = config.enabled
        var candidates: [Candidate] = []

        // On a refresh, a category is looked at again only when one of its folders changed.
        let previousItems = previous?.items ?? []
        func revisit(_ c: CleanupCategory) -> Bool {
            guard enabled.contains(c) else { return false }
            guard previous != nil else { return true }
            return categoryRoots(c, config: config).contains { touches(canonicalPath($0), changes) }
        }
        func kept(_ c: CleanupCategory) -> [Candidate] {
            previousItems.filter { $0.category == c }.compactMap { item in
                guard let u = item.urls.first else { return Candidate(item: item, sizeURL: nil) }
                guard FileManager().fileExists(atPath: u.path) else { return nil }
                return Candidate(item: item, sizeURL: c == .largeOldFiles ? nil : u)
            }
        }

        // The external tools (docker df takes seconds) run while the file system is walked.
        let fresh = previous == nil
        async let simItems = enabled.contains(.simulators) && fresh ? simulators(home: config.home, runner: simctl) : []
        let dockerKinds = enabled.filter(\.isDocker)
        async let dockerList = !dockerKinds.isEmpty && fresh && config.allowedRoots == nil
            ? DockerScan.items(runner: docker, now: now, cacheAgeDays: config.dockerCacheAgeDays, enabled: dockerKinds) : []

        // node_modules and build folders come from one walk of the project roots.
        let walkProjects = revisit(.nodeModules) || revisit(.buildFolders)
        let projects = walkProjects ? config.projectRoots.map { DiskUsage.scanProjects(under: $0) } : []

        for c in [CleanupCategory.xcode, .nodeModules, .buildFolders, .packageCaches, .ideCaches, .backups, .largeOldFiles] where enabled.contains(c) {
            if revisit(c) {
                switch c {
                case .xcode: candidates += xcode(home: config.home, now: now)
                case .nodeModules: candidates += nodeModules(config: config, found: projects.flatMap(\.nodeModules), now: now)
                case .buildFolders: candidates += buildFolders(config: config, projects: projects.flatMap(\.projects), now: now)
                case .packageCaches: candidates += pathRuleItems(.packageCaches, home: config.home) + homebrewOldVersions(config)
                case .ideCaches, .backups: candidates += pathRuleItems(c, home: config.home)
                case .largeOldFiles: candidates += largeOldFiles(config: config, now: now)
                default: break
                }
            } else {
                candidates += kept(c)
            }
        }
        if fresh {
            candidates += await simItems
            candidates += await dockerList.map { Candidate(item: $0, sizeURL: nil) }
        } else {
            if enabled.contains(.simulators) { candidates += kept(.simulators) }
            for c in dockerKinds { candidates += kept(c) }
        }
        candidates = candidates.filter { c in c.item.urls.allSatisfy { isAllowed(canonicalPath($0), config) } && (config.allowedRoots == nil || !c.item.urls.isEmpty) }

        // Dedup by id (overlapping project roots).
        var seenIDs = Set<String>()
        candidates = candidates.filter { seenIDs.insert($0.item.id).inserted }

        let (sized, units, measured) = size(candidates, previous: previous, changes: changes, now: now, workers: config.sizingWorkers)
        let items = sized.filter { $0.sizeBytes > 0 }
        let groups = CleanupCategory.current.compactMap { cat in
            let list = items.filter { $0.category == cat }.sorted { $0.sizeBytes > $1.sizeBytes }
            return list.isEmpty ? nil : CleanupGroup(category: cat, items: list)
        }
        let liveIDs = Set(items.map(\.id))
        return ScanResult(groups: groups, units: units.filter { liveIDs.contains($0.key) }, scannedAt: now, measuredUnits: measured)
    }

    /// Sizes every candidate. Each folder is split into units (see `SizeUnits.partition`) and all
    /// units of all items are measured together in parallel, so one huge cache spreads over every
    /// core. On a refresh, units nothing changed under keep their previous size.
    private static func size(_ candidates: [Candidate], previous: ScanResult?, changes: [ChangedPath], now: Date, workers: Int)
        -> (items: [CleanupItem], units: [String: [SizeUnit]], measured: Int) {
        let previousByID = Dictionary((previous?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var plans: [[SizeUnit]] = Array(repeating: [], count: candidates.count)
        var todo: [(Int, Int)] = []
        var items = candidates.map(\.item)
        for (i, c) in candidates.enumerated() {
            guard let url = c.sizeURL else { continue }
            let root = canonicalPath(url)
            let prevUnits = previous?.units[c.item.id]
            if let prevUnits, let prevItem = previousByID[c.item.id], !touches(root, changes) {
                plans[i] = prevUnits
                items[i].sizeBytes = prevItem.sizeBytes
                items[i].scannedAt = prevItem.scannedAt
                continue
            }
            let known = Dictionary((prevUnits ?? []).map { ($0.key, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            var units = SizeUnits.partition(root: root)
            for (j, u) in units.enumerated() where u.bytes == nil {
                if let k = known[u.key] ?? nil, !SizeUnits.isDirty(u, changes) { units[j].bytes = k } else {
                    units[j].bytes = k(u.key, known)
                    todo.append((i, j))
                }
            }
            plans[i] = units
            items[i].scannedAt = now
        }
        let measured = SizeUnits.measure(todo.map { plans[$0.0][$0.1] }, workers: workers)
        for (k, (i, j)) in todo.enumerated() { plans[i][j].bytes = measured[k] }
        var unitsByID: [String: [SizeUnit]] = [:]
        for (i, c) in candidates.enumerated() where c.sizeURL != nil {
            items[i].sizeBytes = plans[i].reduce(0) { $0 + ($1.bytes ?? 0) }
            unitsByID[c.item.id] = plans[i]
        }
        for i in items.indices where items[i].scannedAt == nil { items[i].scannedAt = now }
        return (items, unitsByID, todo.count)
    }

    /// Previous size as an ordering hint for `measure` (largest first).
    private static func k(_ key: String, _ known: [String: UInt64?]) -> UInt64? { known[key] ?? nil }

    private static func largeOldFiles(config: CleanupConfig, now: Date) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-Double(config.largeFileMinAgeDays) * 86_400)
        var out: [Candidate] = []
        for name in ["Desktop", "Downloads", "Movies"] {
            for f in DiskUsage.largeOldFiles(in: config.home.appendingPathComponent(name), minBytes: config.largeFileMinBytes, olderThan: cutoff) {
                out.append(Candidate(item: CleanupItem(
                    id: f.url.path, category: .largeOldFiles, title: f.url.lastPathComponent, detail: name,
                    urls: [f.url], sizeBytes: f.size, lastUsed: f.modified, safety: .reviewFirst, selectedByDefault: false
                ), sizeURL: nil))
            }
        }
        return out
    }

    // MARK: Xcode

    /// "MyApp-abcdefghijklmnopqrstuvwxyz" -> "MyApp"
    static func derivedDataTitle(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let suffix = folder[folder.index(after: dash)...]
        guard suffix.count >= 20, suffix.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return folder }
        return String(folder[..<dash])
    }

    private static func xcode(home: URL, now: Date) -> [Candidate] {
        let base = home.appendingPathComponent("Library/Developer/Xcode")
        let day: TimeInterval = 86_400
        var out: [Candidate] = []

        for dir in DiskUsage.subdirectories(of: base.appendingPathComponent("DerivedData")) {
            let used = DiskUsage.newestModification(in: dir)
            let stale = used.map { now.timeIntervalSince($0) > 30 * day } ?? true
            var item = CleanupItem(
                id: dir.path, category: .xcode, title: derivedDataTitle(dir.lastPathComponent), detail: "DerivedData",
                urls: [dir], sizeBytes: 0, lastUsed: used, safety: .rebuildable, selectedByDefault: stale)
            if let ws = derivedDataWorkspace(dir) {
                let root = ws.deletingLastPathComponent()
                item.projectRoot = root.path
                item.projectActive = DiskUsage.gitActivity(root)
            }
            out.append(Candidate(item: item, sizeURL: dir))
        }

        let previews = base.appendingPathComponent("UserData/Previews")
        if DiskUsage.isRealDirectory(previews) {
            out.append(Candidate(item: CleanupItem(
                id: previews.path, category: .xcode, title: "Xcode Previews", detail: "SwiftUI preview builds · rebuilt when a preview opens",
                urls: [previews], sizeBytes: 0, lastUsed: DiskUsage.newestModification(in: previews), safety: .rebuildable, selectedByDefault: false
            ), sizeURL: previews))
        }

        let archives = base.appendingPathComponent("Archives")
        if DiskUsage.isRealDirectory(archives) {
            out.append(Candidate(item: CleanupItem(
                id: archives.path, category: .xcode, title: "Archives", detail: "Shipped builds and their debug symbols",
                urls: [archives], sizeBytes: 0, lastUsed: DiskUsage.newestModification(in: archives),
                safety: .notRebuildable, selectedByDefault: false
            ), sizeURL: archives))
        }

        for platform in ["iOS", "watchOS", "macOS", "tvOS", "visionOS"] {
            let support = base.appendingPathComponent("\(platform) DeviceSupport")
            for dir in DiskUsage.subdirectories(of: support) {
                let used = DiskUsage.modification(of: dir)
                let old = used.map { now.timeIntervalSince($0) > 90 * day } ?? true
                out.append(Candidate(item: CleanupItem(
                    id: dir.path, category: .xcode, title: dir.lastPathComponent, detail: "\(platform) DeviceSupport",
                    urls: [dir], sizeBytes: 0, lastUsed: used, safety: .redownloads, selectedByDefault: old
                ), sizeURL: dir))
            }
        }
        return out
    }

    // MARK: Simulators

    private static func simulators(home: URL, runner: any SimctlRunner) async -> [Candidate] {
        var out: [Candidate] = []
        let caches = home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        if DiskUsage.isRealDirectory(caches) {
            out.append(Candidate(item: CleanupItem(
                id: caches.path, category: .simulators, title: "Simulator caches", detail: "dyld and runtime caches · rebuilt on next boot",
                urls: [caches], sizeBytes: 0, lastUsed: DiskUsage.modification(of: caches), safety: .rebuildable, selectedByDefault: false
            ), sizeURL: caches))
        }
        return out + (await unavailableSimulators(home: home, runner: runner))
    }

    private static func unavailableSimulators(home: URL, runner: any SimctlRunner) async -> [Candidate] {
        guard let data = await runner.unavailableDevicesJSON() else { return [] }
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        return SimctlParser.devices(data).compactMap { runtime, d in
            let dir = devices.appendingPathComponent(d.udid)
            guard !d.udid.isEmpty, !d.udid.contains("/"), DiskUsage.isRealDirectory(dir) else { return nil }
            return Candidate(item: CleanupItem(
                id: "simulator:" + d.udid, category: .simulators, title: d.name,
                detail: "\(runtime) · unavailable", urls: [dir], sizeBytes: 0,
                lastUsed: DiskUsage.modification(of: dir), safety: .rebuildable, selectedByDefault: true
            ), sizeURL: dir)
        }
    }

    // MARK: node_modules

    private static func nodeModules(config: CleanupConfig, found: [URL], now: Date) -> [Candidate] {
        let protect = Double(config.protectRecentDays) * 86_400
        var out: [Candidate] = []
        for nm in found {
            let project = nm.deletingLastPathComponent()
            let used = DiskUsage.newestModification(in: project, excluding: ["node_modules"])
            let active = used.map { now.timeIntervalSince($0) < protect } ?? false
            // pnpm links packages from its store: the folder's size counts files the store also holds.
            let pnpm = FileManager().fileExists(atPath: nm.appendingPathComponent(".pnpm").path)
            var item = CleanupItem(
                id: nm.path, category: .nodeModules, title: project.lastPathComponent,
                detail: active ? "Used in the last \(config.protectRecentDays) days" : (pnpm ? "pnpm install restores it" : "npm install restores it"),
                urls: [nm], sizeBytes: 0, lastUsed: used,
                safety: active ? .activeProject : .rebuildable, selectedByDefault: !active,
                sizeIsUpperBound: pnpm ? true : nil)
            item.projectRoot = project.path
            item.projectActive = [DiskUsage.gitActivity(project), used].compactMap { $0 }.max()
            out.append(Candidate(item: item, sizeURL: nm))
        }
        return out
    }

    // MARK: Build folders

    /// Output folders that a build makes again. `dist` and `build` count only when the project's
    /// .gitignore lists them, so a source folder that happens to be called `build` is never offered.
    static func buildFolderRules(children: Set<String>, gitignore: Set<String>) -> [(name: String, detail: String, selected: Bool)] {
        let js = children.contains("package.json")
        let rust = children.contains("Cargo.toml")
        let python = children.contains("pyproject.toml") || children.contains("requirements.txt") || children.contains("setup.py")
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"].contains { children.contains($0) }
        let swift = children.contains("Package.swift")
        var out: [(String, String, Bool)] = []
        if js && children.contains(".next") { out.append((".next", "Next.js build · next build restores it", true)) }
        for n in ["dist", "build"] where children.contains(n) && (js || gradle) && gitignore.contains(n) {
            out.append((n, "Build output, ignored by git", false))
        }
        if rust && children.contains("target") { out.append(("target", "Cargo build output · cargo build restores it", true)) }
        for n in [".venv", "venv"] where python && children.contains(n) { out.append((n, "Python environment · reinstall with pip or uv", false)) }
        if gradle && children.contains(".gradle") { out.append((".gradle", "Gradle project cache", true)) }
        if swift && children.contains(".build") { out.append((".build", "SwiftPM build output · swift build restores it", true)) }
        return out
    }

    private static func buildFolders(config: CleanupConfig, projects: [URL], now: Date) -> [Candidate] {
        let protect = Double(config.protectRecentDays) * 86_400
        let fm = FileManager()
        var out: [Candidate] = []
        for project in projects {
            guard let names = try? fm.contentsOfDirectory(atPath: project.path) else { continue }
            let children = Set(names)
            let ignore = DiskUsage.gitignoreNames(project)
            let rules = buildFolderRules(children: children, gitignore: ignore)
            guard !rules.isEmpty else { continue }
            let skip = Set(rules.map(\.name) + ["node_modules"])
            let used = DiskUsage.newestModification(in: project, excluding: skip)
            let activity = [DiskUsage.gitActivity(project), used].compactMap { $0 }.max()
            let active = activity.map { now.timeIntervalSince($0) < protect } ?? false
            for r in rules {
                let dir = project.appendingPathComponent(r.name)
                guard DiskUsage.isRealDirectory(dir) else { continue }
                var item = CleanupItem(
                    id: dir.path, category: .buildFolders, title: "\(project.lastPathComponent)/\(r.name)",
                    detail: active ? "Used in the last \(config.protectRecentDays) days" : r.detail,
                    urls: [dir], sizeBytes: 0, lastUsed: activity,
                    safety: active ? .activeProject : .rebuildable, selectedByDefault: r.selected && !active)
                item.projectRoot = project.path
                item.projectActive = activity
                out.append(Candidate(item: item, sizeURL: dir))
            }
        }
        return out
    }

    // MARK: Package caches

    struct PathRule: Sendable {
        var category: CleanupCategory
        var title: String
        var path: String
        var detail: String
        var safety: Safety = .redownloads
        var selected = false
        var advisory: String? = nil
        var upTo = false
        /// One item per subdirectory (JetBrains products, Android emulators, iPhone backups).
        var perChild = false
    }

    static let pathRules: [PathRule] = [
        PathRule(category: .packageCaches, title: "Homebrew", path: "Library/Caches/Homebrew", detail: "Downloads again when needed", selected: true),
        PathRule(category: .packageCaches, title: "npm", path: ".npm/_cacache", detail: "Downloads again when needed", selected: true),
        PathRule(category: .packageCaches, title: "pnpm", path: "Library/pnpm/store", detail: "Shared with node_modules through hard links", upTo: true),
        PathRule(category: .packageCaches, title: "Yarn", path: "Library/Caches/Yarn", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "pip", path: "Library/Caches/pip", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "Cargo", path: ".cargo/registry/cache", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "Go", path: "Library/Caches/go-build", detail: "Go build cache · rebuilt when needed", safety: .rebuildable),
        PathRule(category: .packageCaches, title: "Go modules", path: "go/pkg/mod", detail: "Read-only files · Go's own command removes them", advisory: "go clean -modcache"),
        PathRule(category: .packageCaches, title: "Gradle", path: ".gradle/caches", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "SwiftPM", path: "Library/Caches/org.swift.swiftpm", detail: "Package checkouts · fetched again on resolve"),
        PathRule(category: .packageCaches, title: "SwiftPM data", path: "Library/org.swift.swiftpm", detail: "Collections, mirrors and fingerprints", safety: .reviewFirst),
        PathRule(category: .packageCaches, title: "CocoaPods", path: "Library/Caches/CocoaPods", detail: "Downloads again on pod install"),
        PathRule(category: .packageCaches, title: "Bun", path: ".bun/install/cache", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "uv", path: ".cache/uv", detail: "Downloads again when needed"),
        PathRule(category: .packageCaches, title: "Poetry", path: "Library/Caches/pypoetry", detail: "Downloads again when needed"),
        PathRule(category: .ideCaches, title: "JetBrains", path: "Library/Caches/JetBrains", detail: "IDE caches and indexes · rebuilt on next launch", safety: .rebuildable, perChild: true),
        PathRule(category: .ideCaches, title: "VS Code · Cache", path: "Library/Application Support/Code/Cache", detail: "Rebuilt on next launch", safety: .rebuildable),
        PathRule(category: .ideCaches, title: "VS Code · CachedData", path: "Library/Application Support/Code/CachedData", detail: "Rebuilt on next launch", safety: .rebuildable),
        PathRule(category: .ideCaches, title: "VS Code · Extension downloads", path: "Library/Application Support/Code/CachedExtensionVSIXs", detail: "Downloads again when needed"),
        PathRule(category: .ideCaches, title: "Cursor · Cache", path: "Library/Application Support/Cursor/Cache", detail: "Rebuilt on next launch", safety: .rebuildable),
        PathRule(category: .ideCaches, title: "Cursor · CachedData", path: "Library/Application Support/Cursor/CachedData", detail: "Rebuilt on next launch", safety: .rebuildable),
        PathRule(category: .ideCaches, title: "Cursor · Extension downloads", path: "Library/Application Support/Cursor/CachedExtensionVSIXs", detail: "Downloads again when needed"),
        PathRule(category: .ideCaches, title: "Android emulator", path: ".android/avd", detail: "Android emulator · its installed apps and data go with it", safety: .reviewFirst, perChild: true),
        PathRule(category: .backups, title: "Trash", path: ".Trash", detail: "Vardis never empties it; Finder does", safety: .notRebuildable, advisory: "Finder › Empty Trash"),
        PathRule(category: .backups, title: "iPhone backup", path: "Library/Application Support/MobileSync/Backup", detail: "Device backup · gone for good once the Trash is emptied", safety: .reviewFirst, perChild: true),
    ]

    /// The package-cache rules (kept for the benchmark and older callers).
    static var packageCacheRules: [(name: String, path: String, selected: Bool)] {
        pathRules.filter { $0.category == .packageCaches && $0.advisory == nil }.map { ($0.title, $0.path, $0.selected) }
    }

    private static func pathRuleItems(_ category: CleanupCategory, home: URL) -> [Candidate] {
        var out: [Candidate] = []
        for rule in pathRules where rule.category == category {
            let dir = home.appendingPathComponent(rule.path)
            guard DiskUsage.isRealDirectory(dir) else { continue }
            let targets: [(URL, String)] = rule.perChild
                ? DiskUsage.subdirectories(of: dir).map { ($0, childTitle(rule, $0)) }
                : [(dir, rule.title)]
            for (url, title) in targets {
                let advisory = rule.advisory != nil
                out.append(Candidate(item: CleanupItem(
                    id: url.path, category: category, title: title, detail: rule.detail,
                    urls: advisory ? [] : [url], sizeBytes: 0,
                    lastUsed: rule.perChild ? DiskUsage.newestModification(in: url) : DiskUsage.modification(of: url),
                    safety: rule.safety, selectedByDefault: rule.selected && !advisory, advisoryCommand: rule.advisory,
                    sizeIsUpperBound: rule.upTo ? true : nil
                ), sizeURL: url))
            }
        }
        return out
    }

    private static func childTitle(_ rule: PathRule, _ url: URL) -> String {
        let name = url.lastPathComponent
        switch rule.title {
        case "Android emulator": return name.hasSuffix(".avd") ? String(name.dropLast(4)).replacingOccurrences(of: "_", with: " ") : name
        case "iPhone backup":
            let info = url.appendingPathComponent("Info.plist")
            if let d = try? Data(contentsOf: info),
               let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
               let device = p["Device Name"] as? String { return device }
            return "Backup \(name.prefix(8))"
        default: return name
        }
    }

    /// Older Homebrew formula versions still in the Cellar. Advisory: `brew cleanup` removes them.
    private static func homebrewOldVersions(_ config: CleanupConfig) -> [Candidate] {
        guard config.allowedRoots == nil else { return [] }
        var bytes: UInt64 = 0, count = 0
        var newest: Date?
        let fm = FileManager()
        for prefix in config.homebrewPrefixes {
            let cellar = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar")
            for formula in DiskUsage.subdirectories(of: cellar) {
                let versions = DiskUsage.subdirectories(of: formula)
                guard versions.count > 1 else { continue }
                let opt = URL(fileURLWithPath: prefix).appendingPathComponent("opt").appendingPathComponent(formula.lastPathComponent)
                let current = (try? fm.destinationOfSymbolicLink(atPath: opt.path)).map { ($0 as NSString).lastPathComponent }
                let keep = current ?? versions.max { (DiskUsage.modification(of: $0) ?? .distantPast) < (DiskUsage.modification(of: $1) ?? .distantPast) }?.lastPathComponent
                for v in versions where v.lastPathComponent != keep {
                    bytes += FastSizer.bulkAllocatedSize(v.path)
                    count += 1
                    if let m = DiskUsage.modification(of: v) { newest = max(newest ?? m, m) }
                }
            }
        }
        guard bytes > 0 else { return [] }
        return [Candidate(item: CleanupItem(
            id: "homebrew:old-versions", category: .packageCaches, title: "Homebrew old versions",
            detail: "\(count) older formula \(count == 1 ? "version" : "versions") in the Cellar", urls: [], sizeBytes: bytes,
            lastUsed: newest, safety: .redownloads, selectedByDefault: false, advisoryCommand: "brew cleanup"
        ), sizeURL: nil)]
    }

    /// Xcode notes which workspace a DerivedData folder belongs to in its info.plist.
    static func derivedDataWorkspace(_ dir: URL) -> URL? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("info.plist")),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ws = p["WorkspacePath"] as? String, !ws.isEmpty else { return nil }
        return URL(fileURLWithPath: ws)
    }
}
