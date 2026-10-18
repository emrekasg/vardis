import Foundation

/// A transcript on disk with the stat fields used to detect change.
struct TranscriptFile: Sendable {
    var path: String
    var size: UInt64
    var mtime: Double
    /// Lives under `<session>/subagents/`.
    var isSubagent: Bool
    /// Session id from the path: the file name for main transcripts, the parent folder for subagents.
    var pathSessionID: String
    /// `projects/<slug>` folder name.
    var slug: String
}

/// Walks `<home>/projects` with readdir + stat (no Foundation enumerator; this runs on every refresh).
enum TranscriptFiles {
    static func list(projects: URL) -> [TranscriptFile] {
        var out: [TranscriptFile] = []
        let root = projects.path
        for slug in entries(root) where slug.isDir {
            walk(root + "/" + slug.name, slug: slug.name, depth: 0, sessionDir: nil, out: &out)
        }
        return out
    }

    private static func walk(_ dir: String, slug: String, depth: Int, sessionDir: String?, out: inout [TranscriptFile]) {
        for e in entries(dir) {
            let path = dir + "/" + e.name
            if e.isDir {
                // <slug>/<session-uuid>/subagents/... ; skip tool-results and other non-transcript folders early.
                guard depth < 5 else { continue }
                if depth == 0, !looksLikeUUID(e.name) { continue }
                if depth == 1, e.name != "subagents" { continue }
                walk(path, slug: slug, depth: depth + 1, sessionDir: sessionDir ?? e.name, out: &out)
            } else if e.name.hasSuffix(".jsonl") {
                var st = stat()
                guard stat(path, &st) == 0 else { continue }
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                let sub = sessionDir != nil
                let sid = sessionDir ?? String(e.name.dropLast(".jsonl".count))
                out.append(TranscriptFile(path: path, size: UInt64(st.st_size), mtime: mtime, isSubagent: sub, pathSessionID: sid, slug: slug))
            }
        }
    }

    private static func entries(_ dir: String) -> [(name: String, isDir: Bool)] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var out: [(String, Bool)] = []
        while let ent = readdir(d) {
            let name = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.hasPrefix(".") { continue }
            var isDir = ent.pointee.d_type == DT_DIR
            if ent.pointee.d_type == DT_UNKNOWN || ent.pointee.d_type == DT_LNK {
                var st = stat()
                if stat(dir + "/" + name, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
            }
            out.append((name, isDir))
        }
        return out
    }

    static func looksLikeUUID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 { if c != 45 { return false } }
            else if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)) { return false }
        }
        return true
    }
}

/// Claude Code's project folder name for a cwd: every character outside `[A-Za-z0-9]` becomes `-`.
/// Checked against the real folders on the build machine (`/` and `.` both map to `-`).
public enum ProjectSlug {
    public static func slug(for cwd: String) -> String {
        String(String.UnicodeScalarView(cwd.unicodeScalars.map { s in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? s : "-"
        }))
    }
}
