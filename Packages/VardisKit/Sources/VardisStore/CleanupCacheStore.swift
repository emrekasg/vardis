import Foundation

/// One Disk Cleanup result as stored on disk. `payload` is the full item as UTF-8 JSON, encoded by the caller.
public struct CachedCleanupItem: Sendable, Equatable {
    public var id: String
    public var path: String
    public var sizeBytes: UInt64
    public var lastUsed: Date?
    public var scannedAt: Date
    public var payload: Data

    public init(id: String, path: String, sizeBytes: UInt64, lastUsed: Date?, scannedAt: Date, payload: Data) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.scannedAt = scannedAt
        self.payload = payload
    }
}

/// A measured piece of an item (a subdirectory, or the loose files of one directory). Keeping
/// these lets a change inside one piece re-measure only that piece.
public struct CachedSizeUnit: Sendable, Equatable {
    public var path: String
    public var isFileSet: Bool
    public var bytes: UInt64

    public init(path: String, isFileSet: Bool, bytes: UInt64) {
        self.path = path
        self.isFileSet = isFileSet
        self.bytes = bytes
    }
}

/// `cleanup.sqlite`: the last scan, so opening Disk Cleanup shows results at once.
public actor CleanupCacheStore {
    public static let schemaVersion: Int64 = 1
    private let db: Database

    /// Pass `nil` for an in-memory store.
    public init(url: URL?) throws {
        let db = try Database(url: url)
        self.db = db
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version(component TEXT PRIMARY KEY, version INTEGER NOT NULL)")
        let current = try db.prepare("SELECT version FROM schema_version WHERE component = 'cleanup'").all { $0.int(0) }.first ?? 0
        if current > Self.schemaVersion {
            throw DatabaseError(code: -1, message: "cleanup schema \(current) is newer than this build (\(Self.schemaVersion))")
        }
        if current < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE cleanup_items(
                    id TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, last_used REAL, scanned_at REAL NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE cleanup_units(
                    item_id TEXT NOT NULL, path TEXT NOT NULL, file_set INTEGER NOT NULL, size INTEGER NOT NULL,
                    PRIMARY KEY(item_id, path, file_set)) WITHOUT ROWID;
                CREATE TABLE cleanup_meta(key TEXT PRIMARY KEY, value REAL NOT NULL);
                """)
                try db.prepare("INSERT OR REPLACE INTO schema_version(component, version) VALUES('cleanup', ?1)").run([.int(Self.schemaVersion)])
            }
        }
    }

    public struct Snapshot: Sendable {
        public var items: [CachedCleanupItem]
        public var units: [String: [CachedSizeUnit]]
        public var fullScanAt: Date?
    }

    public func load() throws -> Snapshot {
        let items = try db.prepare("SELECT id, path, size, last_used, scanned_at, payload FROM cleanup_items").all { r in
            CachedCleanupItem(id: r.text(0) ?? "", path: r.text(1) ?? "", sizeBytes: UInt64(max(0, r.int(2))),
                              lastUsed: r.isNull(3) ? nil : Date(timeIntervalSince1970: r.double(3)),
                              scannedAt: Date(timeIntervalSince1970: r.double(4)), payload: Data((r.text(5) ?? "").utf8))
        }
        var units: [String: [CachedSizeUnit]] = [:]
        try db.prepare("SELECT item_id, path, file_set, size FROM cleanup_units").query { r in
            units[r.text(0) ?? "", default: []].append(CachedSizeUnit(path: r.text(1) ?? "", isFileSet: r.int(2) != 0, bytes: UInt64(max(0, r.int(3)))))
            return true
        }
        let full = try db.prepare("SELECT value FROM cleanup_meta WHERE key = 'fullScanAt'").all { Date(timeIntervalSince1970: $0.double(0)) }.first
        return Snapshot(items: items, units: units, fullScanAt: full)
    }

    /// Upserts `items` (replacing their units when given), deletes `removed`, all in one transaction.
    /// `replaceAll` first clears everything (a full scan).
    public func save(items: [CachedCleanupItem], units: [String: [CachedSizeUnit]], removed: [String] = [],
                     replaceAll: Bool = false, fullScanAt: Date? = nil) throws {
        try db.transaction {
            if replaceAll {
                try db.execute("DELETE FROM cleanup_items; DELETE FROM cleanup_units;")
            }
            let delItem = try db.prepare("DELETE FROM cleanup_items WHERE id = ?1")
            let delUnits = try db.prepare("DELETE FROM cleanup_units WHERE item_id = ?1")
            for id in removed {
                try delItem.run([.text(id)])
                try delUnits.run([.text(id)])
            }
            let ins = try db.prepare("INSERT OR REPLACE INTO cleanup_items(id, path, size, last_used, scanned_at, payload) VALUES(?1, ?2, ?3, ?4, ?5, ?6)")
            for i in items {
                try ins.run([.text(i.id), .text(i.path), .int(Int64(clamping: i.sizeBytes)), i.lastUsed.map { .double($0.timeIntervalSince1970) } ?? .null,
                             .double(i.scannedAt.timeIntervalSince1970), .text(String(decoding: i.payload, as: UTF8.self))])
            }
            let insUnit = try db.prepare("INSERT OR REPLACE INTO cleanup_units(item_id, path, file_set, size) VALUES(?1, ?2, ?3, ?4)")
            for (id, list) in units {
                try delUnits.run([.text(id)])
                for u in list { try insUnit.run([.text(id), .text(u.path), .int(u.isFileSet ? 1 : 0), .int(Int64(clamping: u.bytes))]) }
            }
            if let fullScanAt {
                try db.prepare("INSERT OR REPLACE INTO cleanup_meta(key, value) VALUES('fullScanAt', ?1)").run([.double(fullScanAt.timeIntervalSince1970)])
            }
        }
    }
}
