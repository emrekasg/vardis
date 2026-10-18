import Foundation

/// One Claude Code config directory (what `CLAUDE_CONFIG_DIR` points at). Transcripts live in `<url>/projects`.
public struct ClaudeHome: Sendable, Hashable, Identifiable {
    public var url: URL
    public var label: String

    public init(url: URL, label: String? = nil) {
        self.url = url.standardizedFileURL
        self.label = label ?? ClaudeHome.defaultLabel(for: self.url)
    }

    public var id: String { url.path }
    public var projectsURL: URL { url.appendingPathComponent("projects", isDirectory: true) }

    /// True for `~/.claude`, the home Claude Code uses without `CLAUDE_CONFIG_DIR`.
    public var isDefault: Bool { url.path == ClaudeHome.defaultURL.path }

    public static var defaultURL: URL {
        URL(fileURLWithPath: realHomeDirectory, isDirectory: true).appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
    }

    static func defaultLabel(for url: URL) -> String {
        let name = url.lastPathComponent
        if url.path == defaultURL.path { return "Default" }
        if name.hasPrefix(".claude-") { return String(name.dropFirst(".claude-".count)) }
        return name
    }

    /// The user's real home, also inside an App Sandbox container.
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
}

public enum ClaudeDiscovery {
    /// `~/.claude`, every `~/.claude-*` folder with a `projects/` subfolder, `$CLAUDE_CONFIG_DIR`, then `extra`.
    /// Folders without `projects/` are skipped, duplicates (after resolving symlinks) are dropped.
    public static func discover(
        extra: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil
    ) -> [ClaudeHome] {
        let fm = FileManager.default
        let home = homeDirectory ?? URL(fileURLWithPath: ClaudeHome.realHomeDirectory, isDirectory: true)
        var candidates: [URL] = [home.appendingPathComponent(".claude", isDirectory: true)]
        if let names = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in names.sorted() where name.hasPrefix(".claude-") {
                candidates.append(home.appendingPathComponent(name, isDirectory: true))
            }
        }
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        candidates.append(contentsOf: extra)

        var seen = Set<String>()
        var out: [ClaudeHome] = []
        for url in candidates {
            var isDir: ObjCBool = false
            let projects = url.appendingPathComponent("projects").path
            guard fm.fileExists(atPath: projects, isDirectory: &isDir), isDir.boolValue else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(resolved).inserted else { continue }
            out.append(ClaudeHome(url: url))
        }
        return out
    }
}
