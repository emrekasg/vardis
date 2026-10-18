import Darwin
import Foundation

public struct LiveSession: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var startedAt: Date?
    public var cwd: String
    public var executablePath: String
    /// Matched session, when a transcript was found for the cwd.
    public var sessionID: String?
    public var transcriptURL: URL?
    public var home: ClaudeHome?
}

/// Finds running Claude Code processes with libproc (no shelling out).
public enum LiveSessions {
    /// Helper subcommands Claude Code runs as separate processes; they are not conversations.
    static let helperSubcommands: Set<String> = ["bg-pty-host", "bg-spare", "mcp", "daemon", "update", "doctor", "--version", "-v"]

    public static func detect(homes: [ClaudeHome] = ClaudeDiscovery.discover()) -> [LiveSession] {
        var found: [LiveSession] = []
        var pidsSeen = Set<Int32>()
        var parents: [Int32: Int32] = [:]
        for pid in allPIDs() where pid > 0 {
            guard let path = executablePath(pid) else { continue }
            let args = arguments(pid)
            guard isClaudeCode(path: path, args: args) else { continue }
            guard let info = bsdInfo(pid), let cwd = currentDirectory(pid) else { continue }
            pidsSeen.insert(pid)
            parents[pid] = Int32(info.pbi_ppid)
            var s = LiveSession(pid: pid, startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6),
                                cwd: cwd, executablePath: path)
            s.sessionID = explicitSessionID(args)
            found.append(s)
        }
        // A launcher and the process it starts share the cwd: keep the innermost one.
        let all = found
        found.removeAll { s in all.contains { other in other.pid != s.pid && parents[other.pid] == s.pid && other.cwd == s.cwd } }
        return match(found, homes: homes)
    }

    /// Pairs each process with a transcript: an explicit `--resume`/`--session-id` first, otherwise the newest
    /// `.jsonl` in the cwd's project folder (newest process gets the newest file).
    static func match(_ sessions: [LiveSession], homes: [ClaudeHome]) -> [LiveSession] {
        var out = sessions.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        var used = Set<String>()
        for i in out.indices {
            let slug = ProjectSlug.slug(for: out[i].cwd)
            var candidates: [(url: URL, mtime: Date, home: ClaudeHome)] = []
            for home in homes {
                let dir = home.projectsURL.appendingPathComponent(slug, isDirectory: true)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                for n in names where n.hasSuffix(".jsonl") {
                    let url = dir.appendingPathComponent(n)
                    let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                    candidates.append((url, m, home))
                }
            }
            if let sid = out[i].sessionID, let c = candidates.first(where: { $0.url.deletingPathExtension().lastPathComponent == sid }) {
                out[i].transcriptURL = c.url
                out[i].home = c.home
                used.insert(sid)
                continue
            }
            guard out[i].sessionID == nil else { continue }
            for c in candidates.sorted(by: { $0.mtime > $1.mtime }) {
                let sid = c.url.deletingPathExtension().lastPathComponent
                if used.contains(sid) { continue }
                used.insert(sid)
                out[i].sessionID = sid
                out[i].transcriptURL = c.url
                out[i].home = c.home
                break
            }
        }
        return out
    }

    static func isClaudeCode(path: String, args: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        let isNative = name == "claude" || path.contains("/claude/versions/")
        let isNode = (name == "node" || name == "bun") && args.dropFirst().contains { $0.contains("claude-code") || $0.contains("@anthropic-ai/claude") }
        guard isNative || isNode else { return false }
        // The native binary also runs embedded tools under another argv0 (e.g. `ugrep`); those are not sessions.
        if isNative, let argv0 = args.first {
            let a0 = (argv0.split(separator: " ").first.map(String.init) ?? argv0) as NSString
            let base = a0.lastPathComponent
            let isVersion = !base.isEmpty && base.allSatisfy { $0.isNumber || $0 == "." }
            if !base.hasPrefix("claude"), !isVersion { return false }
        }
        let sub = isNode ? args.dropFirst(2).first : args.dropFirst().first
        if let sub, helperSubcommands.contains(sub) { return false }
        if let argv0 = args.first, argv0.hasPrefix("claude "), helperSubcommands.contains(String(argv0.dropFirst(7))) { return false }
        return true
    }

    static func explicitSessionID(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == "--resume" || a == "-r" || a == "--session-id", i + 1 < args.count, TranscriptFiles.looksLikeUUID(args[i + 1]) { return args[i + 1] }
            if a.hasPrefix("--resume="), case let v = String(a.dropFirst(9)), TranscriptFiles.looksLikeUUID(v) { return v }
            if a.hasPrefix("--session-id="), case let v = String(a.dropFirst(13)), TranscriptFiles.looksLikeUUID(v) { return v }
        }
        return nil
    }

    // MARK: - libproc

    static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got)))
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// argv via `KERN_PROCARGS2`: argc, exec path, padding, then argv strings.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}
