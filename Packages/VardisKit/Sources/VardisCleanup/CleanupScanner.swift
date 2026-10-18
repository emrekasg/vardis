import Foundation

/// Finds developer junk under `config.home` and moves chosen items to the Trash.
/// It never deletes: removal is always `FileManager.trashItem`.
public actor CleanupScanner {
    public typealias Trasher = @Sendable (URL) throws -> Void

    public let config: CleanupConfig
    private let simctl: any SimctlRunner
    private let docker: any DockerRunner
    private let trasher: Trasher

    public init(
        config: CleanupConfig,
        simctl: any SimctlRunner = SystemSimctlRunner(),
        docker: any DockerRunner = SystemDockerRunner(),
        trasher: Trasher? = nil
    ) {
        self.config = config
        self.simctl = simctl
        self.docker = docker
        self.trasher = trasher ?? { url in try FileManager().trashItem(at: url, resultingItemURL: nil) }
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
        case .simulators: return [home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")]
        case .nodeModules: return config.projectRoots
        case .packageCaches: return packageCacheRules.map { home.appendingPathComponent($0.path) }
        case .largeOldFiles: return ["Desktop", "Downloads", "Movies"].map { home.appendingPathComponent($0) }
        case .docker: return []
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

    public func trash(_ items: [CleanupItem]) async -> TrashResult {
        let home = Self.canonicalPath(config.home)
        var result = TrashResult()
        for item in items {
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
                do { try trasher(u) } catch {
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
        async let dockerList = enabled.contains(.docker) && fresh && config.allowedRoots == nil ? dockerItems(home: config.home, runner: docker) : []

        for c in [CleanupCategory.xcode, .nodeModules, .packageCaches, .largeOldFiles] where enabled.contains(c) {
            if revisit(c) {
                switch c {
                case .xcode: candidates += xcode(home: config.home, now: now)
                case .nodeModules: candidates += nodeModules(config: config, now: now)
                case .packageCaches: candidates += packageCaches(home: config.home)
                case .largeOldFiles: candidates += largeOldFiles(config: config, now: now)
                default: break
                }
            } else {
                candidates += kept(c)
            }
        }
        if fresh {
            candidates += await simItems
            candidates += await dockerList
        } else {
            if enabled.contains(.simulators) { candidates += kept(.simulators) }
            if enabled.contains(.docker) { candidates += kept(.docker) }
        }
        candidates = candidates.filter { c in c.item.urls.allSatisfy { isAllowed(canonicalPath($0), config) } && (config.allowedRoots == nil || !c.item.urls.isEmpty) }

        // Dedup by id (overlapping project roots).
        var seenIDs = Set<String>()
        candidates = candidates.filter { seenIDs.insert($0.item.id).inserted }

        let (sized, units, measured) = size(candidates, previous: previous, changes: changes, now: now)
        let items = sized.filter { $0.sizeBytes > 0 }
        let groups = CleanupCategory.allCases.compactMap { cat in
            let list = items.filter { $0.category == cat }.sorted { $0.sizeBytes > $1.sizeBytes }
            return list.isEmpty ? nil : CleanupGroup(category: cat, items: list)
        }
        let liveIDs = Set(items.map(\.id))
        return ScanResult(groups: groups, units: units.filter { liveIDs.contains($0.key) }, scannedAt: now, measuredUnits: measured)
    }

    /// Sizes every candidate. Each folder is split into units (see `SizeUnits.partition`) and all
    /// units of all items are measured together in parallel, so one huge cache spreads over every
    /// core. On a refresh, units nothing changed under keep their previous size.
    private static func size(_ candidates: [Candidate], previous: ScanResult?, changes: [ChangedPath], now: Date)
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
        let measured = SizeUnits.measure(todo.map { plans[$0.0][$0.1] })
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
            out.append(Candidate(item: CleanupItem(
                id: dir.path, category: .xcode, title: derivedDataTitle(dir.lastPathComponent), detail: "DerivedData",
                urls: [dir], sizeBytes: 0, lastUsed: used, safety: .rebuildable, selectedByDefault: stale
            ), sizeURL: dir))
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

    private static func nodeModules(config: CleanupConfig, now: Date) -> [Candidate] {
        let protect = Double(config.protectRecentDays) * 86_400
        var out: [Candidate] = []
        for root in config.projectRoots {
            for nm in DiskUsage.findNodeModules(under: root) {
                let project = nm.deletingLastPathComponent()
                let used = DiskUsage.newestModification(in: project, excluding: ["node_modules"])
                let active = used.map { now.timeIntervalSince($0) < protect } ?? false
                out.append(Candidate(item: CleanupItem(
                    id: nm.path, category: .nodeModules, title: project.lastPathComponent,
                    detail: active ? "Used in the last \(config.protectRecentDays) days" : "npm install restores it",
                    urls: [nm], sizeBytes: 0, lastUsed: used,
                    safety: active ? .activeProject : .rebuildable, selectedByDefault: !active
                ), sizeURL: nm))
            }
        }
        return out
    }

    // MARK: Docker

    private static func dockerItems(home: URL, runner: any DockerRunner) async -> [Candidate] {
        let fm = FileManager()
        guard fm.fileExists(atPath: home.appendingPathComponent(".docker").path)
            || fm.fileExists(atPath: "/Applications/Docker.app")
            || fm.fileExists(atPath: home.appendingPathComponent("Applications/Docker.app").path)
        else { return [] }
        guard let data = await runner.systemDFJSON() else { return [] }
        return DockerParser.usage(data).map { u in
            Candidate(item: CleanupItem(
                id: "docker:" + u.type, category: .docker, title: u.type,
                detail: u.totalCount.isEmpty ? "Reclaimable" : "\(u.totalCount) total · reclaimable",
                urls: [], sizeBytes: u.reclaimableBytes, lastUsed: nil, safety: .reviewFirst,
                selectedByDefault: false, advisoryCommand: "docker system prune"
            ), sizeURL: nil)
        }
    }

    // MARK: Package caches

    static let packageCacheRules: [(name: String, path: String, selected: Bool)] = [
        ("Homebrew", "Library/Caches/Homebrew", true),
        ("npm", ".npm/_cacache", true),
        ("pnpm", "Library/pnpm/store", false),
        ("Yarn", "Library/Caches/Yarn", false),
        ("pip", "Library/Caches/pip", false),
        ("Cargo", ".cargo/registry/cache", false),
        ("Go", "Library/Caches/go-build", false),
        ("Gradle", ".gradle/caches", false),
    ]

    private static func packageCaches(home: URL) -> [Candidate] {
        packageCacheRules.compactMap { rule in
            let dir = home.appendingPathComponent(rule.path)
            guard DiskUsage.isRealDirectory(dir) else { return nil }
            return Candidate(item: CleanupItem(
                id: dir.path, category: .packageCaches, title: rule.name, detail: "Downloads again when needed",
                urls: [dir], sizeBytes: 0, lastUsed: DiskUsage.modification(of: dir),
                safety: .redownloads, selectedByDefault: rule.selected
            ), sizeURL: dir)
        }
    }
}
