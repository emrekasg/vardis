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
        let config = config, simctl = simctl, docker = docker
        return await Task.detached(priority: .utility) {
            await Self.runScan(config: config, simctl: simctl, docker: docker, now: Date())
        }.value
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

    static func runScan(config: CleanupConfig, simctl: any SimctlRunner, docker: any DockerRunner, now: Date) async -> [CleanupGroup] {
        let home = config.home
        let day: TimeInterval = 86_400
        var candidates: [Candidate] = []
        let enabled = config.enabled

        // The external tools (docker df takes seconds) run while the file system is walked.
        async let simItems = enabled.contains(.simulators) ? simulators(home: home, runner: simctl) : []
        async let dockerList = enabled.contains(.docker) ? dockerItems(home: home, runner: docker) : []

        if enabled.contains(.xcode) { candidates += xcode(home: home, now: now) }
        if enabled.contains(.nodeModules) { candidates += nodeModules(config: config, now: now) }
        if enabled.contains(.packageCaches) { candidates += packageCaches(home: home) }
        if enabled.contains(.largeOldFiles) {
            let cutoff = now.addingTimeInterval(-Double(config.largeFileMinAgeDays) * day)
            for name in ["Desktop", "Downloads", "Movies"] {
                for f in DiskUsage.largeOldFiles(in: home.appendingPathComponent(name), minBytes: config.largeFileMinBytes, olderThan: cutoff) {
                    candidates.append(Candidate(item: CleanupItem(
                        id: f.url.path, category: .largeOldFiles, title: f.url.lastPathComponent, detail: name,
                        urls: [f.url], sizeBytes: f.size, lastUsed: f.modified, safety: .reviewFirst, selectedByDefault: false
                    ), sizeURL: nil))
                }
            }
        }

        candidates += await simItems
        candidates += await dockerList

        // Size in parallel, at most 4 directories in flight.
        let sizes = await sizeAll(candidates.map(\.sizeURL))
        var items: [CleanupItem] = []
        for (i, c) in candidates.enumerated() {
            var item = c.item
            if let s = sizes[i] { item.sizeBytes = s }
            if item.sizeBytes > 0 { items.append(item) }
        }

        // Dedup by id (overlapping project roots).
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }

        return CleanupCategory.allCases.compactMap { cat in
            let list = items.filter { $0.category == cat }.sorted { $0.sizeBytes > $1.sizeBytes }
            return list.isEmpty ? nil : CleanupGroup(category: cat, items: list)
        }
    }

    /// Each directory is split into its direct children so one huge cache (go-build: ~460k files)
    /// spreads over all workers instead of pinning one; metadata reads scale with parallelism.
    private static func sizeAll(_ urls: [URL?]) async -> [UInt64?] {
        var out = [UInt64?](repeating: nil, count: urls.count)
        var work: [(Int, URL)] = []
        for (i, u) in urls.enumerated() {
            guard let u else { continue }
            out[i] = 0
            if DiskUsage.isRealDirectory(u) {
                let children = (try? FileManager().contentsOfDirectory(at: u, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])) ?? []
                work += children.map { (i, $0) }
            } else {
                work.append((i, u))
            }
        }
        await withTaskGroup(of: (Int, UInt64).self) { group in
            var next = 0
            func add() {
                let (i, u) = work[next]
                next += 1
                group.addTask(priority: .utility) { (i, DiskUsage.allocatedSize(of: u)) }
            }
            while next < min(4, work.count) { add() }
            while let (i, s) = await group.next() {
                out[i] = (out[i] ?? 0) + s
                if next < work.count { add() }
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
