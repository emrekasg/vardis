import Darwin
import Foundation

/// Allocated-size walkers. Both count regular files only, never follow symlinks and never
/// cross into another directory through a symlink. Sizes are allocated bytes (what the disk
/// gets back), the same number Finder's "on disk" shows.
public enum FastSizer {
    /// `getattrlistbulk` walk: one syscall returns name, type and allocated size for a whole
    /// batch of directory entries, so no per-file `stat`. Directories are opened relative to
    /// their parent (`openat`), so no path strings are built while walking.
    public static func bulkAllocatedSize(_ path: String) -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return UInt64(st.st_blocks) * 512
        case S_IFDIR: break
        default: return 0
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        return walk(fd: fd, buffer: buffer, depth: 0)
    }

    /// `fts_open(FTS_PHYSICAL)` walk, kept as the reference implementation and for benchmarks.
    public static func ftsAllocatedSize(_ path: String) -> UInt64 {
        var total: UInt64 = 0
        path.withCString { cpath in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cpath), nil]
            defer { free(argv[0]) }
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let ent = fts_read(fts) {
                if Int32(ent.pointee.fts_info) == FTS_F, let sp = ent.pointee.fts_statp {
                    total &+= UInt64(sp.pointee.st_blocks) * 512
                }
            }
        }
        return total
    }

    private static let bufferSize = 256 * 1024
    private static let maxDepth = 256

    private static func walk(fd: Int32, buffer: UnsafeMutableRawPointer, depth: Int) -> UInt64 {
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_ERROR)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        var total: UInt64 = 0
        var subdirs: [String] = []
        while true {
            let n = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if n <= 0 { break }
            var entry = buffer
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                var name: String?
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var failed = false
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                if !failed {
                    if type == UInt32(VREG.rawValue) {
                        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                            total &+= UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                        }
                    } else if type == UInt32(VDIR.rawValue), let name {
                        subdirs.append(name)
                    }
                }
                entry += length
            }
        }
        guard depth < maxDepth else { return total }
        for name in subdirs {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 { total &+= walk(fd: child, buffer: buffer, depth: depth + 1) }
        }
        return total
    }

    /// Entries directly inside `path`: (name, isDirectory, allocated bytes for regular files).
    /// Symlinks and other special files are reported with `isDirectory == false` and size 0.
    public static func list(_ path: String) -> [(name: String, isDirectory: Bool, bytes: UInt64)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_ERROR)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        var out: [(String, Bool, UInt64)] = []
        while true {
            let n = getattrlistbulk(fd, &list, buffer, size, 0)
            if n <= 0 { break }
            var entry = buffer
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var failed = false
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                if !failed, !name.isEmpty {
                    var bytes: UInt64 = 0
                    if type == UInt32(VREG.rawValue), returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        bytes = UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                    }
                    out.append((name, type == UInt32(VDIR.rawValue), bytes))
                }
                entry += length
            }
        }
        return out
    }
}
