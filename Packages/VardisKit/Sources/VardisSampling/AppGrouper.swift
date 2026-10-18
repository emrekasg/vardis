import Foundation
import VardisCore

/// One app as the user sees it. Instances are cached and reused across samples.
final class AppGroup {
    let id: String
    let name: String
    let bundleURL: URL?
    let isSystem: Bool
    fileprivate(set) var generation: UInt64 = 0
    /// Members in the last sample. Reused across samples.
    fileprivate(set) var members: [ProcessRecord] = []

    init(id: String, name: String, bundleURL: URL?, isSystem: Bool) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.isSystem = isSystem
    }

    var isBundle: Bool { bundleURL != nil }

    /// Footprint of all members, filled by `AppGrouper.group` so groups can be sorted before samples are built.
    fileprivate(set) var memory: UInt64 = 0

    func makeSample() -> AppSample {
        var cpu = 0.0, energy = 0.0, read = 0.0, write = 0.0
        var pids = [Int32]()
        pids.reserveCapacity(members.count)
        for p in members {
            cpu += p.cpu
            energy += p.energyWatts
            read += p.readPerSecond
            write += p.writePerSecond
            pids.append(p.pid)
        }
        return AppSample(id: id, name: name, bundleURL: bundleURL, isSystem: isSystem, processIDs: pids, cpu: min(1, cpu),
                         memory: memory, energyWatts: energy, diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write)
    }
}

/// Rolls processes into apps. Lookups are cached per bundle path and per process instance.
final class AppGrouper {
    /// What owns an executable, decided from paths alone.
    enum Owner: Equatable {
        case bundle(path: String)
        case executable(name: String, isSystem: Bool)
    }

    private var groupsByBundlePath: [String: AppGroup] = [:]
    private var groupsByID: [String: AppGroup] = [:]
    private var generation: UInt64 = 0
    private(set) var activeGroups: [AppGroup] = []

    // MARK: Pure rules

    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    /// The outermost `.app` bundle in a path, e.g. ".../Google Chrome.app" for a nested helper app.
    static func outermostAppBundle(in path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<path.index(r.lowerBound, offsetBy: 4)]) }
        if path.hasSuffix(".app") { return path }
        return nil
    }

    static func isSystemPath(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    static func executableName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Own bundle first, then the nearest ancestor (closest parent first) with a bundle, then the executable itself.
    static func owner(executablePath: String, name: String? = nil, ancestorPaths: [String]) -> Owner {
        if let bundle = outermostAppBundle(in: executablePath) { return .bundle(path: bundle) }
        for ancestor in ancestorPaths {
            if let bundle = outermostAppBundle(in: ancestor) { return .bundle(path: bundle) }
        }
        return .executable(name: name ?? executableName(executablePath), isSystem: isSystemPath(executablePath))
    }

    /// Display name and identifier from a bundle's Info.plist.
    static func bundleIdentity(path: String) -> (id: String, name: String) {
        let fileName = executableName(path)
        let fallbackName = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return (path, fallbackName)
        }
        let id = (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? path
        let name = [plist["CFBundleDisplayName"], plist["CFBundleName"]]
            .lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? fallbackName
        return (id, name)
    }

    // MARK: Grouping

    /// Assigns every active process to a group and fills `activeGroups`, sorted by memory descending.
    func group(_ processes: [ProcessRecord], byPID: [Int32: ProcessRecord]) {
        generation &+= 1
        activeGroups.removeAll(keepingCapacity: true)
        for p in processes {
            let g = p.group ?? resolve(p, byPID: byPID, depth: 0)
            if g.generation != generation {
                g.generation = generation
                g.members.removeAll(keepingCapacity: true)
                g.memory = 0
                activeGroups.append(g)
            }
            g.members.append(p)
            g.memory &+= p.memory
        }
        activeGroups.sort { $0.memory > $1.memory }
        if generation % 600 == 0 { pruneGroups() }
    }

    func group(id: String) -> AppGroup? {
        guard let g = groupsByID[id], g.generation == generation else { return nil }
        return g
    }

    private func resolve(_ p: ProcessRecord, byPID: [Int32: ProcessRecord], depth: Int) -> AppGroup {
        if let g = p.group { return g }
        let g: AppGroup
        if let bundle = Self.outermostAppBundle(in: p.path) {
            g = bundleGroup(path: bundle)
        } else if depth < 32, p.parentPID > 1, p.parentPID != p.pid, let parent = byPID[p.parentPID],
                  case let pg = resolve(parent, byPID: byPID, depth: depth + 1), pg.isBundle {
            g = pg
        } else {
            g = executableGroup(name: p.name, path: p.path)
        }
        p.group = g
        return g
    }

    private func bundleGroup(path: String) -> AppGroup {
        if let g = groupsByBundlePath[path] { return g }
        // Claude Code's CLI ships a helper .app next to its versioned binaries; keep them as one app.
        if path.contains("/claude/ClaudeCode.app"), let g = groupsByID["cli.claude-code"] { groupsByBundlePath[path] = g; return g }
        let identity = path.contains("/claude/ClaudeCode.app") ? (id: "cli.claude-code", name: "Claude Code CLI") : Self.bundleIdentity(path: path)
        let g = groupsByID[identity.id] ?? AppGroup(id: identity.id, name: identity.name,
                                                   bundleURL: URL(fileURLWithPath: path, isDirectory: true), isSystem: false)
        groupsByID[g.id] = g
        groupsByBundlePath[path] = g
        return g
    }

    private func executableGroup(name: String, path: String) -> AppGroup {
        let (id, display) = Self.toolIdentity(name: name, path: path)
        if let g = groupsByID[id] { return g }
        // A helper launched outside its bundle (same display name) joins the app instead of showing twice.
        if let app = groupsByBundlePath.values.first(where: { $0.name == display }) {
            groupsByID[id] = app
            return app
        }
        let g = AppGroup(id: id, name: display, bundleURL: nil, isSystem: Self.isSystemPath(path))
        groupsByID[id] = g
        return g
    }

    /// Names for command-line tools that would otherwise show as a bare binary or version number.
    static func toolIdentity(name: String, path: String) -> (id: String, name: String) {
        if path.contains("/claude/versions/") || name == "claude" { return ("cli.claude-code", "Claude Code CLI") }
        if name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) {
            // e.g. ~/.local/share/<tool>/versions/2.1.302: name it after the tool folder.
            let parts = path.split(separator: "/")
            if let v = parts.lastIndex(where: { $0 == "versions" }), v > 0 { let tool = String(parts[v - 1]); return ("cli." + tool, tool) }
            if parts.count >= 2 { let dir = String(parts[parts.count - 2]); return ("cli." + dir, dir) }
        }
        return (name, name)
    }

    /// Forgets groups not seen for a while so transient tools do not pile up.
    private func pruneGroups() {
        let cutoff = generation &- 600
        for (id, g) in groupsByID where g.generation < cutoff { groupsByID.removeValue(forKey: id) }
        for (path, g) in groupsByBundlePath where g.generation < cutoff { groupsByBundlePath.removeValue(forKey: path) }
    }
}
