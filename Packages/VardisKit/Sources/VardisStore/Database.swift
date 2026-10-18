import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// Thin wrapper over the system SQLite. Not thread-safe; own one instance per actor.
public final class Database {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]

    /// Pass `nil` for an in-memory database.
    public init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        if url != nil {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
        }
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError(code: sqlite3_errcode(handle), message: msg)
        }
    }

    /// Prepared statements are cached by SQL text.
    public func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] { s.reset(); return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        let s = Statement(stmt, db: handle)
        cache[sql] = s
        return s
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Statement {
    fileprivate let stmt: OpaquePointer
    private let db: OpaquePointer?

    fileprivate init(_ stmt: OpaquePointer, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Binds values to `?1`, `?2`, … in order.
    @discardableResult
    public func bind(_ values: [SQLValue]) -> Statement {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let x): sqlite3_bind_int64(stmt, idx, x)
            case .double(let x): sqlite3_bind_double(stmt, idx, x)
            case .text(let x): sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            case .blob(let x): _ = x.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(x.count), SQLITE_TRANSIENT) }
            }
        }
        return self
    }

    /// Runs a statement that returns no rows.
    public func run(_ values: [SQLValue] = []) throws {
        reset()
        bind(values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Iterates rows; return `false` from `body` to stop early.
    public func query(_ values: [SQLValue] = [], _ body: (Row) throws -> Bool) throws {
        reset()
        bind(values)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
            if try !body(Row(stmt: stmt)) { return }
        }
    }

    public func all<T>(_ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(values) { out.append(try map($0)); return true }
        return out
    }
}

public enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct Row {
    fileprivate let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}
