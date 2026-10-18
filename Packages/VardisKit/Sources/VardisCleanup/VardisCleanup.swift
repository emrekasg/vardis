import Foundation

/// Display order follows declaration order.
public enum CleanupCategory: String, CaseIterable, Sendable, Codable {
    case xcode, simulators, nodeModules, buildFolders, packageCaches, ideCaches
    case dockerImages, dockerBuildCache, dockerContainers, dockerVolumes
    case backups, largeOldFiles
    /// Older builds listed Docker as one advisory group. No longer produced; dropped when read from the cache.
    case docker

    public var title: String {
        switch self {
        case .xcode: "Xcode"
        case .simulators: "Simulators"
        case .nodeModules: "node_modules"
        case .buildFolders: "Build folders"
        case .packageCaches: "Package caches"
        case .ideCaches: "Editors and emulators"
        case .dockerImages: "Docker images"
        case .dockerBuildCache: "Docker build cache"
        case .dockerContainers: "Stopped containers"
        case .dockerVolumes: "Docker volumes"
        case .backups: "Backups and Trash"
        case .largeOldFiles: "Large old files"
        case .docker: "Docker"
        }
    }

    /// Removed by the Docker CLI, permanently, never through the Trash.
    public var isDocker: Bool {
        switch self {
        case .dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes, .docker: true
        default: false
        }
    }

    /// Categories a scan can produce (the legacy `.docker` is excluded).
    public static var current: [CleanupCategory] { allCases.filter { $0 != .docker } }
}

/// What the Docker CLI removes for one item.
public struct DockerRef: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case container, image, volume, buildCache }
    public var kind: Kind
    /// Container id, image tags (or the image id when untagged), volume name. Empty for build cache.
    public var refs: [String]
    /// Build cache only: prune entries unused for this many hours; nil prunes all unused cache.
    public var untilHours: Int?

    public init(kind: Kind, refs: [String], untilHours: Int? = nil) {
        self.kind = kind
        self.refs = refs
        self.untilHours = untilHours
    }

    /// Arguments after `docker`.
    public var arguments: [String] {
        switch kind {
        case .container: ["rm"] + refs
        case .image: ["rmi"] + refs
        case .volume: ["volume", "rm"] + refs
        case .buildCache: ["builder", "prune", "-f"] + (untilHours.map { ["--filter", "until=\($0)h"] } ?? [])
        }
    }
}

public enum Safety: String, Sendable, Codable {
    /// A build recreates it.
    case rebuildable
    /// A tool downloads it again when needed.
    case redownloads
    /// Gone for good once the Trash is emptied.
    case notRebuildable
    /// Belongs to a project used recently; protected.
    case activeProject
    /// The person must look before removing.
    case reviewFirst
}

public struct CleanupItem: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var category: CleanupCategory
    public var title: String
    public var detail: String
    /// What moves to the Trash. Empty for advisory items.
    public var urls: [URL]
    /// Allocated bytes on disk (for Docker: reclaimable bytes reported by Docker).
    public var sizeBytes: UInt64
    public var lastUsed: Date?
    public var safety: Safety
    public var selectedByDefault: Bool
    /// Set when Vardis never touches the files itself; the UI shows this command instead.
    public var advisoryCommand: String?
    /// When the size was last measured.
    public var scannedAt: Date?
    /// Set for Docker objects: removal goes through the Docker CLI and is permanent.
    public var docker: DockerRef?
    /// The size may count data shared with other items (hard links, shared layers): shown as "up to".
    public var sizeIsUpperBound: Bool?
    /// The project folder this item belongs to (node_modules, build folders, DerivedData).
    public var projectRoot: String?
    /// Last commit or checkout in that project (from `.git/logs/HEAD`), else its newest file.
    public var projectActive: Date?

    public var isAdvisory: Bool { advisoryCommand != nil }
    public var isPermanent: Bool { docker != nil }
    public var isUpperBound: Bool { sizeIsUpperBound == true }

    public init(id: String, category: CleanupCategory, title: String, detail: String, urls: [URL], sizeBytes: UInt64, lastUsed: Date?, safety: Safety, selectedByDefault: Bool, advisoryCommand: String? = nil, scannedAt: Date? = nil,
                docker: DockerRef? = nil, sizeIsUpperBound: Bool? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.urls = urls
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.safety = safety
        self.selectedByDefault = selectedByDefault
        self.advisoryCommand = advisoryCommand
        self.scannedAt = scannedAt
        self.docker = docker
        self.sizeIsUpperBound = sizeIsUpperBound
    }
}

public struct CleanupGroup: Sendable, Identifiable {
    public var id: CleanupCategory { category }
    public var category: CleanupCategory
    /// Largest first.
    public var items: [CleanupItem]
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var selectedBytes: UInt64 { items.reduce(0) { $0 + ($1.selectedByDefault ? $1.sizeBytes : 0) } }

    public init(category: CleanupCategory, items: [CleanupItem]) {
        self.category = category
        self.items = items
    }
}

public struct CleanupConfig: Sendable {
    /// Parallel folder walkers. Scans started by Vardis on its own use 2 so they stay out of the way;
    /// a scan the user asked for uses every core.
    public var sizingWorkers: Int = 2
    public var home: URL
    public var projectRoots: [URL]
    public var protectRecentDays: Int
    public var largeFileMinBytes: UInt64
    public var largeFileMinAgeDays: Int
    public var enabled: Set<CleanupCategory>
    /// Docker build cache unused for longer than this is preselected.
    public var dockerCacheAgeDays: Int = 30
    /// Homebrew prefixes whose Cellar is checked for old versions. Empty unless `home` is the real home.
    public var homebrewPrefixes: [String] = []
    /// When set (App Store edition), only items inside these folders are scanned; Docker is skipped.
    public var allowedRoots: [URL]?

    /// Large old files are opt-in, so they are off unless `enabled` says otherwise.
    public static let defaultEnabled: Set<CleanupCategory> = Set(CleanupCategory.current).subtracting([.largeOldFiles])

    /// Common project folders under `home` that exist.
    public static func defaultProjectRoots(home: URL) -> [URL] {
        ["Developer", "Projects", "Code", "code", "src", "dev", "repos", "git", "work", "Sites"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Folders directly in `home` that hold code: a project themselves, or one with a project up to
    /// two levels down (a `.git`, package.json, Cargo.toml, …). Standard macOS folders are skipped.
    /// Two directory levels are listed, nothing is measured.
    public static func discoverProjectRoots(home: URL) -> [URL] {
        let skip: Set<String> = ["Library", "Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
                                 "go", "OrbStack", "Postman", "Creative Cloud Files", "Dropbox", "Google Drive", "iCloud Drive"]
        let fm = FileManager()
        func hasMarker(_ dir: URL) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            return names.contains { DiskUsage.projectMarkers.contains($0) }
        }
        return DiskUsage.subdirectories(of: home).filter { dir in
            guard !skip.contains(dir.lastPathComponent) else { return false }
            if hasMarker(dir) { return true }
            for child in DiskUsage.subdirectories(of: dir).prefix(200) {
                if hasMarker(child) { return true }
                if DiskUsage.subdirectories(of: child).prefix(100).contains(where: hasMarker) { return true }
            }
            return false
        }
    }

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL]? = nil,
        protectRecentDays: Int = 14,
        largeFileMinBytes: UInt64 = 1_000_000_000,
        largeFileMinAgeDays: Int = 180,
        enabled: Set<CleanupCategory> = CleanupConfig.defaultEnabled,
        allowedRoots: [URL]? = nil
    ) {
        self.home = home
        self.projectRoots = projectRoots ?? CleanupConfig.defaultProjectRoots(home: home)
        self.protectRecentDays = protectRecentDays
        self.largeFileMinBytes = largeFileMinBytes
        self.largeFileMinAgeDays = largeFileMinAgeDays
        self.enabled = enabled
        self.allowedRoots = allowedRoots
        if home.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            homebrewPrefixes = ["/opt/homebrew", "/usr/local"]
        }
    }
}

/// A scan with the measured pieces of every item, so the next refresh re-measures only what changed.
public struct ScanResult: Sendable {
    public var groups: [CleanupGroup]
    /// Item id -> its size units.
    public var units: [String: [SizeUnit]]
    public var scannedAt: Date
    /// How many directory trees were measured (not reused) by the scan that made this result.
    public var measuredUnits: Int

    public init(groups: [CleanupGroup], units: [String: [SizeUnit]], scannedAt: Date, measuredUnits: Int = 0) {
        self.groups = groups
        self.units = units
        self.scannedAt = scannedAt
        self.measuredUnits = measuredUnits
    }

    public var items: [CleanupItem] { groups.flatMap(\.items) }

    /// The same result without `ids` (after they moved to the Trash).
    public func removing(_ ids: Set<String>) -> ScanResult {
        var r = self
        r.groups = groups.compactMap { g -> CleanupGroup? in
            let items = g.items.filter { !ids.contains($0.id) }
            return items.isEmpty ? nil : CleanupGroup(category: g.category, items: items)
        }
        for id in ids { r.units[id] = nil }
        return r
    }
}

public struct TrashResult: Sendable {
    public struct Failure: Sendable, Equatable {
        public var itemID: String
        public var url: URL?
        public var reason: String
    }

    public init() {}

    /// Items whose every URL reached the Trash.
    public var movedIDs: [String] = []

    /// Number of items whose every URL reached the Trash.
    public var moved: Int = 0
    /// Bytes of the items that moved.
    public var bytes: UInt64 = 0
    public var failures: [Failure] = []
    /// Where each moved URL landed in the Trash, for "Put back".
    public var trashed: [TrashedEntry] = []
    /// Docker objects removed permanently (counted in `moved` and `bytes` as well).
    public var permanentlyRemoved: Int = 0
}

/// One URL moved to the Trash: where it was and where it is now.
public struct TrashedEntry: Sendable, Equatable, Codable {
    public var itemID: String
    public var title: String
    public var original: URL
    public var inTrash: URL
    public var bytes: UInt64

    public init(itemID: String, title: String, original: URL, inTrash: URL, bytes: UInt64) {
        self.itemID = itemID
        self.title = title
        self.original = original
        self.inTrash = inTrash
        self.bytes = bytes
    }
}

public struct PutBackResult: Sendable {
    public var restored: [TrashedEntry] = []
    public var failures: [(entry: TrashedEntry, reason: String)] = []
    public init() {}
}
