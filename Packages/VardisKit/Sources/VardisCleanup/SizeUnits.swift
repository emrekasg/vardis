import Foundation

/// A measurable piece of an item: a directory tree (sized recursively) or the loose regular
/// files directly inside one directory. An item's size is the sum of its units.
public struct SizeUnit: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var isFileSet: Bool
    /// Known size; nil until measured.
    public var bytes: UInt64?

    public init(path: String, isFileSet: Bool, bytes: UInt64? = nil) {
        self.path = path
        self.isFileSet = isFileSet
        self.bytes = bytes
    }

    /// Identity without the size.
    public var key: String { (isFileSet ? "f:" : "d:") + path }
}

/// A change FSEvents reported: a directory whose contents changed, and whether everything
/// below it must be treated as changed (events were coalesced or dropped).
public struct ChangedPath: Sendable, Equatable {
    public var path: String
    public var recursive: Bool

    public init(path: String, recursive: Bool) {
        self.path = path
        self.recursive = recursive
    }
}

public enum SizeUnits {
    /// Directories with fewer subdirectories than this are opened further, so a cache like
    /// `pnpm/store/v10/files/00…ff` splits into its 256 shards instead of one 300k-file tree.
    static let splitBelow = 16
    static let maxSplitDepth = 4

    /// Splits `root` into units by listing directories only (no recursive walk). File-set
    /// units come back already measured. A regular file root is one unit.
    public static func partition(root: String) -> [SizeUnit] {
        var st = stat()
        guard lstat(root, &st) == 0 else { return [] }
        if st.st_mode & S_IFMT == S_IFREG { return [SizeUnit(path: root, isFileSet: false, bytes: UInt64(st.st_blocks) * 512)] }
        guard st.st_mode & S_IFMT == S_IFDIR else { return [] }
        var out: [SizeUnit] = []
        func split(_ dir: String, depth: Int) {
            let entries = FastSizer.list(dir)
            let files = entries.reduce(UInt64(0)) { $0 + ($1.isDirectory ? 0 : $1.bytes) }
            if entries.contains(where: { !$0.isDirectory }) { out.append(SizeUnit(path: dir, isFileSet: true, bytes: files)) }
            let subdirs = entries.filter(\.isDirectory).map { dir + "/" + $0.name }
            if subdirs.count < splitBelow, depth < maxSplitDepth {
                for s in subdirs { split(s, depth: depth + 1) }
            } else {
                out += subdirs.map { SizeUnit(path: $0, isFileSet: false) }
            }
        }
        split(root, depth: 0)
        return out
    }

    /// Whether a change makes this unit's cached size stale.
    static func isDirty(_ unit: SizeUnit, _ changes: [ChangedPath]) -> Bool {
        changes.contains { c in
            if unit.isFileSet { return c.path == unit.path || (c.recursive && unit.path.hasPrefix(c.path + "/")) }
            return c.path == unit.path || c.path.hasPrefix(unit.path + "/") || (c.recursive && unit.path.hasPrefix(c.path + "/"))
        }
    }

    /// Re-partitions `root` and reuses `previous` sizes for units the changes did not touch.
    /// Returns units with every size filled in, and how many had to be measured.
    public static func refresh(root: String, previous: [SizeUnit], changes: [ChangedPath]) -> (units: [SizeUnit], measured: Int) {
        let known = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var units = partition(root: root)
        var todo: [Int] = []
        for (i, u) in units.enumerated() where u.bytes == nil {
            if let k = known[u.key]?.bytes, !isDirty(u, changes) { units[i].bytes = k } else { todo.append(i) }
        }
        let measured = measure(todo.map { units[$0] })
        for (j, i) in todo.enumerated() { units[i].bytes = measured[j] }
        return (units, todo.count)
    }

    /// Measures tree units (file sets keep the size the listing gave them) in parallel at utility
    /// QoS. Blocks the calling thread until done. `bytes` on a tree unit is only an ordering hint:
    /// the largest previous sizes start first so one huge shard does not finish last.
    public static func measure(_ units: [SizeUnit], workers: Int = ProcessInfo.processInfo.activeProcessorCount) -> [UInt64] {
        guard !units.isEmpty else { return [] }
        let out = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: units.count)
        out.initialize(repeating: 0)
        defer { out.deallocate() }
        let order = units.indices.sorted { (units[$0].bytes ?? .max) > (units[$1].bytes ?? .max) }
        let base = UncheckedSendable(out)
        let lanes = max(1, min(workers, order.count))
        let qos: DispatchQoS.QoSClass = workers <= 2 ? .background : .utility
        DispatchQueue.global(qos: qos).sync {
            // Each lane takes every `lanes`-th unit, largest first, so at most `lanes` threads walk the disk.
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var k = lane
                while k < order.count {
                    let i = order[k]
                    let u = units[i]
                    base.value[i] = u.isFileSet ? (u.bytes ?? shallowFiles(u.path)) : FastSizer.bulkAllocatedSize(u.path)
                    k += lanes
                }
            }
        }
        return Array(out)
    }

    /// Allocated bytes of the regular files directly inside `dir`.
    public static func shallowFiles(_ dir: String) -> UInt64 {
        FastSizer.list(dir).reduce(0) { $0 + ($1.isDirectory ? 0 : $1.bytes) }
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
