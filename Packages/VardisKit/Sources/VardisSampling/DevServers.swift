import Darwin
import Foundation

/// Whose server a listening process is. Only `.yours` may ever be stopped by Vardis.
public enum ServerOwnership: String, Sendable, Hashable {
    /// Started by the current user: dev servers, databases, tools.
    case yours
    /// A container runtime forwarding a container's port (Docker Desktop, OrbStack, Colima/Lima).
    case container
    /// macOS or another account: system daemons, root, pid < 500, binaries under /System or /usr/libexec.
    case system

    public var label: String {
        switch self {
        case .yours: "Yours"
        case .container: "A container"
        case .system: "The system's"
        }
    }

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    static let containerNames: Set<String> = ["com.docker.backend", "com.docker.vpnkit", "vpnkit", "vpnkit-bridge", "com.docker.supervisor",
                                              "OrbStack Helper", "OrbStack", "orbstack", "limactl", "colima", "gvproxy"]
    static let containerPathMarkers = ["/Docker.app/", "/OrbStack.app/", "/.orbstack/", "/.colima/", "/lima/"]

    /// Containers first (their backends run as the user), then system, else yours.
    public static func classify(pid: Int32, uid: UInt32, currentUID: UInt32, name: String, path: String) -> ServerOwnership {
        if containerNames.contains(name) || containerPathMarkers.contains(where: path.contains) { return .container }
        if pid < 500 || uid != currentUID || systemPrefixes.contains(where: path.hasPrefix) { return .system }
        return .yours
    }
}

/// "3000", ":3000", "localhost:3000", "127.0.0.1:3000", "http://localhost:3000/" -> 3000. Anything else -> nil.
public enum PortQuery {
    public static func parse(_ raw: String) -> UInt16? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["http://", "https://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.lastIndex(of: ":") {
            let host = s[..<colon]
            guard host.isEmpty || ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]"].contains(String(host)) else { return nil }
            s = String(s[s.index(after: colon)...])
        }
        guard !s.isEmpty, s.count <= 5, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = Int(s), n > 0, n <= 65535 else { return nil }
        return UInt16(n)
    }
}

/// Ports a project says it wants, read from its own config files. Read-only, best effort, small files only.
public enum DevPortConfig {
    public static let files = ["package.json", "vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts", ".env", ".env.local", ".env.development"]

    /// Reads at most 256 KB of each known file in `folder`.
    public static func read(folder: String) -> [UInt16] {
        var contents: [String: String] = [:]
        for f in files {
            let path = folder + "/" + f
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            if let data = try? h.read(upToCount: 256 * 1024) { contents[f] = String(decoding: data, as: UTF8.self) }
        }
        return ports(files: contents)
    }

    /// Ports from file name -> contents. Unique, in order found.
    public static func ports(files: [String: String]) -> [UInt16] {
        var out: [UInt16] = []
        func add(_ p: UInt16?) { if let p, p > 0, !out.contains(p) { out.append(p) } }
        if let pkg = files["package.json"] { for p in packageJSONPorts(pkg) { add(p) } }
        for name in ["vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts"] {
            if let v = files[name] { add(vitePort(v)) }
        }
        for name in [".env", ".env.local", ".env.development"] {
            if let e = files[name] { add(envPort(e)) }
        }
        return out
    }

    /// `"dev": "vite --port 5174"`, `"next dev -p 3001"`, `"PORT=4000 node server.js"`.
    static func packageJSONPorts(_ json: String) -> [UInt16] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any],
              let dev = (scripts["dev"] ?? scripts["start"]) as? String else { return [] }
        return scriptPorts(dev)
    }

    static func scriptPorts(_ script: String) -> [UInt16] {
        let patterns = [#"--port[= ]+(\d{2,5})"#, #"(?:^|\s)-p[= ]+(\d{2,5})"#, #"(?:^|\s)PORT=(\d{2,5})"#]
        var out: [UInt16] = []
        for pattern in patterns {
            for m in matches(pattern, in: script) where !out.contains(m) { out.append(m) }
        }
        return out
    }

    /// `server: { port: 5173 }` in a vite config. The first `port:` with a literal number.
    static func vitePort(_ source: String) -> UInt16? {
        matches(#"\bport\s*:\s*(\d{2,5})"#, in: source).first
    }

    /// `PORT=3000` (optionally quoted or exported) in a .env file.
    static func envPort(_ source: String) -> UInt16? {
        for line in source.split(whereSeparator: \.isNewline) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("export ") { l.removeFirst(7) }
            guard l.hasPrefix("PORT=") else { continue }
            let v = l.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let n = UInt16(v), n > 0 { return n }
        }
        return nil
    }

    private static func matches(_ pattern: String, in s: String) -> [UInt16] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? UInt16(ns.substring(with: m.range(at: 1))) : nil
        }.filter { $0 > 0 }
    }
}

/// The `<title>` of an HTML page, whitespace collapsed and common entities decoded.
public enum HTMLTitle {
    public static func extract(from data: Data) -> String? {
        let s = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let open = s.range(of: "<title", options: .caseInsensitive),
              let gt = s.range(of: ">", range: open.upperBound..<s.endIndex),
              let close = s.range(of: "</title>", options: .caseInsensitive, range: gt.upperBound..<s.endIndex) else { return nil }
        var t = String(s[gt.upperBound..<close.lowerBound])
        for (e, r) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return t.count > 80 ? String(t.prefix(79)) + "…" : t
    }
}

/// Ends the user's own processes. Every call re-checks that the pid is still the same process instance,
/// belongs to the current user, and is not Vardis itself or launchd.
public enum ProcessStopper {
    public struct Target: Sendable, Hashable {
        public var pid: Int32
        public var started: Date
        public init(pid: Int32, started: Date) {
            self.pid = pid
            self.started = started
        }
    }

    /// Whether Vardis may signal this process at all.
    public static func mayStop(_ t: Target) -> Bool {
        guard t.pid > 1, t.pid != getpid(), let bsd = PortScanner.bsdInfo(t.pid), bsd.pbi_uid == getuid() else { return false }
        return PortScanner.isRunning(pid: t.pid, started: t.started)
    }

    /// Sends `signal` (SIGTERM or SIGKILL only). False if the process is gone, was replaced, or is not the user's.
    @discardableResult
    public static func send(_ signal: Int32, to t: Target) -> Bool {
        guard signal == SIGTERM || signal == SIGKILL, mayStop(t) else { return false }
        return kill(t.pid, signal) == 0
    }

    public static func isAlive(_ t: Target) -> Bool { PortScanner.isRunning(pid: t.pid, started: t.started) }

    /// Polls until every target has exited or `timeout` passes. Returns the ones still running.
    public static func waitForExit(_ targets: [Target], timeout: Duration = .seconds(3), poll: Duration = .milliseconds(100)) async -> [Target] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var alive = targets.filter(isAlive)
        while !alive.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: poll)
            alive = alive.filter(isAlive)
        }
        return alive
    }
}

/// Whether something accepts TCP connections on a loopback port, including processes Vardis cannot inspect.
public enum PortProbe {
    public static func isListening(port: UInt16, timeoutMilliseconds: Int32 = 200) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMilliseconds) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}

/// A running container with ports published on this Mac, from `docker ps --format` with `ContainerList.format`.
public struct PublishedContainer: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    /// `com.docker.compose.project`, when Compose started it.
    public var composeProject: String?
    /// `com.docker.compose.project.working_dir`: the folder `docker compose up` ran in.
    public var workingDirectory: String?
    public var ports: [ListeningPort]

    public init(id: String, name: String, image: String, composeProject: String?, workingDirectory: String?, ports: [ListeningPort]) {
        self.id = id
        self.name = name
        self.image = image
        self.composeProject = composeProject
        self.workingDirectory = workingDirectory
        self.ports = ports
    }
}

public enum ContainerList {
    /// Tab-separated, one container per line. Labels are read one by one so commas in values cannot split them.
    public static let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.Ports}}"

    public static func parse(_ output: String) -> [PublishedContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 6, !f[0].isEmpty else { return nil }
            let ports = hostPorts(f[5])
            guard !ports.isEmpty else { return nil }
            return PublishedContainer(id: f[0], name: f[1], image: f[2], composeProject: f[3].isEmpty ? nil : f[3],
                                      workingDirectory: f[4].isEmpty ? nil : f[4], ports: ports)
        }
    }

    /// "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:8000-8001->8000-8001/tcp, 9000/tcp" -> 5432, 8000, 8001.
    /// Unpublished container ports (no "->") are not reachable from the Mac and are skipped.
    public static func hostPorts(_ raw: String) -> [ListeningPort] {
        var out = Set<ListeningPort>()
        for part in raw.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let arrow = p.range(of: "->") else { continue }
            let host = p[..<arrow.lowerBound]
            let transport: ListeningPort.Transport = p.hasSuffix("/udp") ? .udp : .tcp
            guard let colon = host.lastIndex(of: ":") else { continue }
            let address = host[..<colon]
            let local = address.hasPrefix("127.") || address == "[::1]" || address == "::1"
            let range = host[host.index(after: colon)...].split(separator: "-").compactMap { UInt16($0) }
            guard let lo = range.first else { continue }
            let hi = range.count > 1 ? range[1] : lo
            guard hi >= lo, hi - lo < 64 else { continue }
            for port in lo...hi where port > 0 { out.insert(ListeningPort(port: port, transport: transport, localOnly: local)) }
        }
        return PortScanner.merge(out)
    }
}
