import Foundation

enum DiskUsage {
    private static let fileKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Allocated bytes under `url`. A symlink counts as nothing and is never followed;
    /// the enumerator does not descend into symlinked directories either.
    static func allocatedSize(of url: URL) -> UInt64 {
        guard let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
              rv.isSymbolicLink != true
        else { return 0 }
        if rv.isDirectory != true { return UInt64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0) }

        // No .skipsPackageDescendants: bundles inside caches count too.
        guard let e = FileManager().enumerator(at: url, includingPropertiesForKeys: fileKeys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        let keySet = Set(fileKeys)
        var total: UInt64 = 0
        var finished = false
        while !finished {
            autoreleasepool {
                for _ in 0..<512 {
                    guard let f = e.nextObject() as? URL else { finished = true; return }
                    guard let v = try? f.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
                    total &+= UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// Newest modification date among `dir` and its direct children (cheap: one directory read).
    static func newestModification(in dir: URL, excluding: Set<String> = []) -> Date? {
        var newest = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let children = (try? FileManager().contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for c in children where !excluding.contains(c.lastPathComponent) {
            if let d = (try? c.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > (newest ?? .distantPast) {
                newest = d
            }
        }
        return newest
    }

    static func modification(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Real directories directly inside `dir` (no symlinks, no hidden entries).
    static func subdirectories(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager().contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }.sorted { $0.path < $1.path }
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    /// `node_modules` folders under `root`, at most `maxDepth` levels deep. Never descends into
    /// node_modules, hidden folders (.git included), Library, packages or symlinks.
    static func findNodeModules(under root: URL, maxDepth: Int = 4) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let keySet = Set(keys)
        let fm = FileManager()
        var found: [URL] = []
        func walk(_ dir: URL, childDepth: Int) {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return }
            for c in children {
                let name = c.lastPathComponent
                guard let v = try? c.resourceValues(forKeys: keySet), v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if name == "node_modules" { found.append(c); continue }
                if name.hasPrefix(".") || name == "Library" || v.isPackage == true { continue }
                if childDepth < maxDepth { walk(c, childDepth: childDepth + 1) }
            }
        }
        walk(root, childDepth: 1)
        return found
    }

    /// Regular files of at least `minBytes` last modified before `olderThan`.
    static func largeOldFiles(in dir: URL, minBytes: UInt64, olderThan: Date) -> [(url: URL, size: UInt64, modified: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        guard let e = FileManager().enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var out: [(URL, UInt64, Date)] = []
        var finished = false
        while !finished {
            autoreleasepool {
                for _ in 0..<512 {
                    guard let f = e.nextObject() as? URL else { finished = true; return }
                    guard let v = try? f.resourceValues(forKeys: keySet), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                    let size = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                    guard size >= minBytes, let m = v.contentModificationDate, m < olderThan else { continue }
                    out.append((f, size, m))
                }
            }
        }
        return out
    }
}
