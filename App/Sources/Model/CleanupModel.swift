import AppKit
import Foundation
import Observation
import VardisCleanup
import VardisCore
import VardisStore

/// Disk totals for the storage bar.
struct VolumeInfo: Sendable, Equatable {
    var total: UInt64
    var available: UInt64
    var name: String
}

/// Disk Cleanup state. The last scan is read from `cleanup.sqlite` at launch, so the screen has
/// results before it is ever opened; FSEvents keeps them fresh and only changed folders are
/// measured again. All disk and SQLite work happens in `CleanupEngine`, never on the main thread.
@MainActor
@Observable
final class CleanupModel {
    private(set) var result: ScanResult?
    private(set) var isScanning = false
    private(set) var volume: VolumeInfo?
    private(set) var lastTrash: TrashResult?
    /// App Store edition: no folders granted yet.
    private(set) var needsFolderAccess = false
    private(set) var grantedFolders: [URL] = []

    /// The person's choices; items not in here use `selectedByDefault`.
    private var selectionOverrides: [String: Bool] = [:]
    var expanded: Set<CleanupCategory> = [.xcode, .nodeModules]

    @ObservationIgnored private var engine: CleanupEngine?
    @ObservationIgnored private var started = false

    static let bookmarksKey = "cleanup.bookmarks"
    nonisolated static let fullScanMaxAge: TimeInterval = 24 * 3_600

    var groups: [CleanupGroup] { result?.groups ?? [] }
    var scannedAt: Date? { result?.scannedAt }

    func start() {
        guard !started else { return }
        started = true
        #if APPSTORE
        grantedFolders = Self.resolveBookmarks()
        needsFolderAccess = grantedFolders.isEmpty
        if needsFolderAccess { return }
        #endif
        launchEngine()
    }

    private func launchEngine() {
        let config = makeConfig()
        let url = Self.supportURL("cleanup.sqlite")
        let engine = CleanupEngine(config: config, cacheURL: url) { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        self.engine = engine
        Task.detached(priority: .utility) { await engine.start() }
    }

    private func apply(_ u: CleanupEngine.Update) {
        if let r = u.result { result = r }
        if let v = u.volume { volume = v }
        isScanning = u.scanning
    }

    /// Full rescan on request. Never blocks: results stay on screen until the new ones land.
    func rescan() {
        guard let engine else { return }
        isScanning = true
        Task.detached(priority: .utility) { await engine.fullScan() }
    }

    // MARK: Selection

    func isSelected(_ item: CleanupItem) -> Bool {
        guard !item.isAdvisory else { return false }
        return selectionOverrides[item.id] ?? item.selectedByDefault
    }

    func toggle(_ item: CleanupItem) {
        guard !item.isAdvisory else { return }
        selectionOverrides[item.id] = !isSelected(item)
    }

    enum Check { case on, off, mixed }

    func check(_ g: CleanupGroup) -> Check {
        let selectable = g.items.filter { !$0.isAdvisory }
        let n = selectable.filter(isSelected).count
        return n == 0 ? .off : (n == selectable.count ? .on : .mixed)
    }

    func toggle(_ g: CleanupGroup) {
        let on = check(g) != .on
        for i in g.items where !i.isAdvisory { selectionOverrides[i.id] = on }
    }

    var selectedItems: [CleanupItem] { groups.flatMap(\.items).filter(isSelected) }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }
    var totalBytes: UInt64 { groups.reduce(0) { $0 + $1.totalBytes } }
    func selectedBytes(in g: CleanupGroup) -> UInt64 { g.items.filter(isSelected).reduce(0) { $0 + $1.sizeBytes } }

    // MARK: Actions

    func showInFinder(_ items: [CleanupItem]) {
        let urls = items.flatMap(\.urls)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Moves the items to the Trash and drops them from the list without a rescan.
    func trash(_ items: [CleanupItem]) async {
        guard let engine else { return }
        let r = await engine.trash(items)
        lastTrash = r
        for id in r.movedIDs { selectionOverrides[id] = nil }
    }

    func dismissTrashResult() { lastTrash = nil }

    // MARK: App Store folder access

    /// Asks for folders with NSOpenPanel and keeps security-scoped bookmarks to them.
    func grantFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Allow"
        panel.message = "Choose the folders Vardis may look through, for example ~/Library/Developer, ~/Library/Caches and your projects folder."
        panel.directoryURL = URL(fileURLWithPath: Self.realHome).appendingPathComponent("Library")
        guard panel.runModal() == .OK else { return }
        var datas = (UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data]) ?? []
        for url in panel.urls {
            if let d = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { datas.append(d) }
        }
        UserDefaults.standard.set(datas, forKey: Self.bookmarksKey)
        grantedFolders = Self.resolveBookmarks()
        needsFolderAccess = grantedFolders.isEmpty
        if !needsFolderAccess {
            if let engine {
                let config = makeConfig()
                Task.detached(priority: .utility) { await engine.update(config: config) }
            } else {
                launchEngine()
            }
        }
    }

    private static func resolveBookmarks() -> [URL] {
        let datas = (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data]) ?? []
        var urls: [URL] = []
        for d in datas {
            var stale = false
            guard let u = try? URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if u.startAccessingSecurityScopedResource() { urls.append(u) }
        }
        return urls
    }

    // MARK: Config

    /// The person's home, even inside the App Store sandbox (where NSHomeDirectory is the container).
    nonisolated static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private func makeConfig() -> CleanupConfig {
        let d = UserDefaults.standard
        let home = URL(fileURLWithPath: Self.realHome, isDirectory: true)
        var enabled = CleanupConfig.defaultEnabled
        if d.bool(forKey: Pref.cleanupLargeFiles) { enabled.insert(.largeOldFiles) }
        let protect = max(0, d.integer(forKey: Pref.cleanupProtectDays))
        #if APPSTORE
        let library = home.appendingPathComponent("Library").path
        let projects = grantedFolders.filter { !$0.path.hasPrefix(library) }
        return CleanupConfig(home: home, projectRoots: projects, protectRecentDays: protect, enabled: enabled, allowedRoots: grantedFolders)
        #else
        let roots = ["code", "Developer", "Projects", "src"].map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return CleanupConfig(home: home, projectRoots: roots, protectRecentDays: protect, enabled: enabled)
        #endif
    }

    nonisolated static func supportURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.dataFolderName, isDirectory: true).appendingPathComponent(name)
    }
}

/// Owns the scanner, the SQLite cache and the FSEvents watcher. Scans and refreshes run one
/// at a time; changes that arrive meanwhile are merged into the next refresh.
actor CleanupEngine {
    struct Update: Sendable {
        var result: ScanResult?
        var volume: VolumeInfo?
        var scanning: Bool
    }

    private var scanner: CleanupScanner
    private var config: CleanupConfig
    private let cacheURL: URL
    private var cache: CleanupCacheStore?
    private var current: ScanResult?
    private var lastFullScan: Date?
    private var watcher: FileWatcher?
    private var pending: [ChangedPath] = []
    private var busy = false
    private let publish: @Sendable (Update) -> Void

    init(config: CleanupConfig, cacheURL: URL, publish: @escaping @Sendable (Update) -> Void) {
        scanner = CleanupScanner(config: config)
        self.config = config
        self.cacheURL = cacheURL
        self.publish = publish
    }

    func start() async {
        cache = try? CleanupCacheStore(url: cacheURL)
        if let snap = try? await cache?.load(), !snap.items.isEmpty {
            current = Self.decode(snap)
            lastFullScan = snap.fullScanAt
            publish(Update(result: current, volume: Self.volume(), scanning: false))
        } else {
            publish(Update(result: nil, volume: Self.volume(), scanning: true))
        }
        startWatching()
        let stale = lastFullScan.map { Date().timeIntervalSince($0) > CleanupModel.fullScanMaxAge } ?? true
        if current == nil || stale { await fullScan() }
    }

    func update(config: CleanupConfig) async {
        scanner = CleanupScanner(config: config)
        self.config = config
        watcher?.stop()
        watcher = nil
        startWatching()
        await fullScan()
    }

    private func startWatching() {
        let roots = CleanupScanner.watchedRoots(config)
        // Caches and node_modules churn during builds; two-minute coalescing keeps sizes fresh enough for a cleaner.
        let w = FileWatcher(paths: roots, latency: 120) { [weak self] changes in
            guard let self else { return }
            Task { await self.changed(changes) }
        }
        w.start()
        watcher = w
    }

    func fullScan() async {
        guard !busy else { return }
        busy = true
        publish(Update(result: nil, volume: nil, scanning: true))
        let r = await scanner.fullScan()
        current = r
        lastFullScan = r.scannedAt
        pending = []
        publish(Update(result: r, volume: Self.volume(), scanning: false))
        try? await cache?.save(items: Self.encode(r.items), units: Self.encodeUnits(r.units), replaceAll: true, fullScanAt: r.scannedAt)
        busy = false
        await drain()
    }

    private func changed(_ changes: [ChangedPath]) async {
        pending += changes
        await drain()
    }

    private func drain() async {
        guard !busy, !pending.isEmpty, let previous = current else { return }
        busy = true
        let changes = pending
        pending = []
        let r = await scanner.refresh(previous, changes: changes)
        current = r
        publish(Update(result: r, volume: Self.volume(), scanning: false))
        let newIDs = Set(r.items.map(\.id))
        let removed = previous.items.map(\.id).filter { !newIDs.contains($0) }
        let remeasured = r.units.filter { id, _ in r.items.first { $0.id == id }?.scannedAt == r.scannedAt }
        try? await cache?.save(items: Self.encode(r.items), units: Self.encodeUnits(remeasured), removed: removed)
        busy = false
        await drain()
    }

    func trash(_ items: [CleanupItem]) async -> TrashResult {
        let r = await scanner.trash(items)
        if let c = current {
            current = c.removing(Set(r.movedIDs))
            publish(Update(result: current, volume: Self.volume(), scanning: busy))
            try? await cache?.save(items: [], units: [:], removed: r.movedIDs)
        }
        return r
    }

    // MARK: Encoding

    private static func encode(_ items: [CleanupItem]) -> [CachedCleanupItem] {
        let enc = JSONEncoder()
        return items.compactMap { i in
            guard let data = try? enc.encode(i) else { return nil }
            return CachedCleanupItem(id: i.id, path: i.urls.first?.path ?? i.id, sizeBytes: i.sizeBytes, lastUsed: i.lastUsed,
                                     scannedAt: i.scannedAt ?? Date(), payload: data)
        }
    }

    private static func encodeUnits(_ units: [String: [SizeUnit]]) -> [String: [CachedSizeUnit]] {
        units.mapValues { $0.map { CachedSizeUnit(path: $0.path, isFileSet: $0.isFileSet, bytes: $0.bytes ?? 0) } }
    }

    private static func decode(_ snap: CleanupCacheStore.Snapshot) -> ScanResult {
        let dec = JSONDecoder()
        let items = snap.items.compactMap { try? dec.decode(CleanupItem.self, from: $0.payload) }
        let groups = CleanupCategory.allCases.compactMap { cat in
            let list = items.filter { $0.category == cat }.sorted { $0.sizeBytes > $1.sizeBytes }
            return list.isEmpty ? nil : CleanupGroup(category: cat, items: list)
        }
        let units = snap.units.mapValues { $0.map { SizeUnit(path: $0.path, isFileSet: $0.isFileSet, bytes: $0.bytes) } }
        let scanned = items.compactMap(\.scannedAt).max() ?? snap.fullScanAt ?? Date()
        return ScanResult(groups: groups, units: units, scannedAt: scanned)
    }

    private static func volume() -> VolumeInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]),
              let total = v.volumeTotalCapacity
        else { return nil }
        return VolumeInfo(total: UInt64(total), available: UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0)), name: v.volumeLocalizedName ?? "Disk")
    }
}
