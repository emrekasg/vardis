import Foundation

public enum CleanupCategory: String, CaseIterable, Sendable, Codable {
    case xcode, simulators, nodeModules, docker, packageCaches, largeOldFiles

    public var title: String {
        switch self {
        case .xcode: "Xcode"
        case .simulators: "Simulators"
        case .nodeModules: "node_modules"
        case .docker: "Docker"
        case .packageCaches: "Package caches"
        case .largeOldFiles: "Large old files"
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
    public var isAdvisory: Bool { advisoryCommand != nil }

    public init(id: String, category: CleanupCategory, title: String, detail: String, urls: [URL], sizeBytes: UInt64, lastUsed: Date?, safety: Safety, selectedByDefault: Bool, advisoryCommand: String? = nil, scannedAt: Date? = nil) {
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
    public var home: URL
    public var projectRoots: [URL]
    public var protectRecentDays: Int
    public var largeFileMinBytes: UInt64
    public var largeFileMinAgeDays: Int
    public var enabled: Set<CleanupCategory>
    /// When set (App Store edition), only items inside these folders are scanned; Docker is skipped.
    public var allowedRoots: [URL]?

    /// Large old files are opt-in, so they are off unless `enabled` says otherwise.
    public static let defaultEnabled: Set<CleanupCategory> = Set(CleanupCategory.allCases).subtracting([.largeOldFiles])

    /// Common project folders under `home` that exist.
    public static func defaultProjectRoots(home: URL) -> [URL] {
        ["Developer", "Projects", "Code", "code", "src", "dev", "repos", "git", "work", "Sites"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
        r.groups = groups.compactMap { g in
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
}
