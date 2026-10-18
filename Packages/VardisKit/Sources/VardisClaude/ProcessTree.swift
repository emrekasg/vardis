import Darwin
import Foundation

/// One process in a parent/child table built with libproc.
public struct ProcessNode: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    /// Short display name: the executable, or the script for interpreters (`node server.js` -> `server.js`).
    public var name: String
    public var residentBytes: UInt64
    public var startedAt: Date?
}

public enum ProcessTree {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "login", "env", "caffeinate", "timeout"]
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "uv", "uvx", "npx", "java"]

    /// pid -> parent pid for every process this user can see.
    public static func parents() -> [Int32: Int32] {
        var out: [Int32: Int32] = [:]
        for pid in LiveSessions.allPIDs() where pid > 0 {
            if let info = LiveSessions.bsdInfo(pid) { out[pid] = Int32(info.pbi_ppid) }
        }
        return out
    }

    /// Everything started under `root`, depth first, without the shells in between and without other Claude Code sessions.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> [ProcessNode] {
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        var out: [ProcessNode] = []
        var stack = (children[root] ?? []).sorted()
        var visited = Set<Int32>()
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted, visited.count < 2_000 else { continue }
            stack.append(contentsOf: (children[pid] ?? []).sorted())
            guard let path = LiveSessions.executablePath(pid) else { continue }
            let exe = (path as NSString).lastPathComponent
            if shells.contains(exe) { continue }
            let args = LiveSessions.arguments(pid)
            if LiveSessions.isClaudeCode(path: path, args: args) { continue }
            let info = LiveSessions.bsdInfo(pid)
            out.append(ProcessNode(pid: pid, ppid: parents[pid] ?? 0, name: displayName(exe: exe, args: args), residentBytes: resident(pid),
                                   startedAt: info.map { Date(timeIntervalSince1970: Double($0.pbi_start_tvsec)) }))
        }
        return out.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    /// Parent chain from `pid` up to (not including) launchd.
    public static func ancestors(of pid: Int32, parents: [Int32: Int32]? = nil) -> [Int32] {
        var out: [Int32] = []
        var p = pid
        for _ in 0..<64 {
            let next = parents?[p] ?? LiveSessions.bsdInfo(p).map { Int32($0.pbi_ppid) }
            guard let next, next > 1, next != p else { break }
            out.append(next)
            p = next
        }
        return out
    }

    public static func resident(_ pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_resident_size
    }

    static func displayName(exe: String, args: [String]) -> String {
        guard interpreters.contains(exe) || exe.hasPrefix("python") else { return exe }
        // First argument that looks like a script or package, not a flag.
        for a in args.dropFirst() where !a.hasPrefix("-") {
            let base = (a as NSString).lastPathComponent
            if base == "index.js" || base == "cli.js" || base == "main.js" || base == "dist" {
                let parent = ((a as NSString).deletingLastPathComponent as NSString)
                let pkg = parent.lastPathComponent == "dist" ? (parent.deletingLastPathComponent as NSString).lastPathComponent : parent.lastPathComponent
                if !pkg.isEmpty { return pkg }
            }
            return base.isEmpty ? exe : base
        }
        return exe
    }
}
