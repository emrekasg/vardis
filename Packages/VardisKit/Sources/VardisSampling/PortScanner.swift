import Darwin
import Foundation

/// One socket a process is waiting on.
public struct ListeningPort: Sendable, Hashable, Comparable {
    public enum Transport: String, Sendable { case tcp = "TCP", udp = "UDP" }
    public var port: UInt16
    public var transport: Transport
    /// Bound to 127.0.0.1 / ::1 only, so other machines cannot reach it.
    public var localOnly: Bool

    public init(port: UInt16, transport: Transport, localOnly: Bool) {
        self.port = port
        self.transport = transport
        self.localOnly = localOnly
    }

    /// Ports that speak something other than HTTP (databases, brokers, ssh, ...).
    static let nonHTTPPorts: Set<UInt16> = [21, 22, 23, 25, 53, 110, 143, 389, 445, 465, 587, 993, 995, 1433, 1521, 1883, 2375, 2376,
                                            3306, 3389, 4369, 5432, 5672, 5900, 6379, 6380, 9092, 9200, 9300, 11211, 25672, 27017, 50051]

    /// Worth an "Open in browser" button: TCP, not a known non-HTTP service, and not an ephemeral port.
    public var looksLikeHTTP: Bool {
        transport == .tcp && !Self.nonHTTPPorts.contains(port) && port < 32768
    }

    public static func < (a: ListeningPort, b: ListeningPort) -> Bool {
        a.port != b.port ? a.port < b.port : a.transport == .tcp && b.transport == .udp
    }
}

/// A process of the current user with at least one listening socket.
public struct ServerProcess: Sendable, Identifiable, Equatable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var executablePath: String
    /// Working directory, nil when the kernel would not say.
    public var workingDirectory: String?
    /// Nearest ancestor of the working directory that looks like a project (has .git, package.json, ...).
    public var projectPath: String?
    public var started: Date
    /// Sorted by port.
    public var ports: [ListeningPort]
    public var establishedConnections: Int
    /// Fraction of the whole Mac since the previous scan.
    public var cpu: Double
    public var memory: UInt64
    /// Set when the process used no CPU for `idleAfter` and has no established connections.
    public var isIdle: Bool
}

/// Finds listening sockets with libproc only (no lsof, no netstat).
/// PROC_PIDLISTFDS per process of the current user, then PROC_PIDFDSOCKETINFO per socket descriptor.
public actor PortScanner {
    /// How long a server must stay without CPU before it is called idle.
    public let idleAfter: TimeInterval
    private let uid = getuid()
    private let cores = Double(max(1, SystemInfo.logicalCores))
    private let timebase = MachTimebase()
    private var pids = [Int32](repeating: 0, count: 4096)
    private var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
    private var idle: [ProcessKey: IdleTracker] = [:]
    private var lastTicks: [ProcessKey: (ticks: UInt64, at: UInt64)] = [:]
    private var projectCache: [String: String?] = [:]

    public init(idleAfter: TimeInterval = 30 * 60) {
        self.idleAfter = idleAfter
    }

    public func scan() -> [ServerProcess] {
        let now = Date()
        let nowNanos = SystemInfo.uptimeNanos()
        var out = [ServerProcess]()
        var seen = Set<ProcessKey>()
        let count = listUserPIDs()
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, let (server, key) = server(pid: pid, now: now, nowNanos: nowNanos) else { continue }
            seen.insert(key)
            out.append(server)
        }
        idle = idle.filter { seen.contains($0.key) }
        lastTicks = lastTicks.filter { seen.contains($0.key) }
        return out.sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }
    }

    /// Listening sockets of these pids only (one app's processes), without walking every process.
    /// Pids of other users are skipped, as in `scan()`.
    public func scan(pids wanted: [Int32]) -> [ServerProcess] {
        let now = Date()
        let nowNanos = SystemInfo.uptimeNanos()
        return Set(wanted).compactMap { $0 > 0 ? server(pid: $0, now: now, nowNanos: nowNanos)?.0 : nil }
            .sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }
    }

    private func server(pid: Int32, now: Date, nowNanos: UInt64) -> (ServerProcess, ProcessKey)? {
        guard let sockets = sockets(of: pid), !sockets.ports.isEmpty else { return nil }
        guard let bsd = Self.bsdInfo(pid), bsd.pbi_uid == uid else { return nil }
        var usage = rusage_info_v6()
        let gotUsage = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0 }
        }
        let key = ProcessKey(pid: pid, start: gotUsage ? usage.ri_proc_start_abstime : 0)

        let ticks = usage.ri_user_time &+ usage.ri_system_time
        var cpu = 0.0
        if let last = lastTicks[key], nowNanos > last.at {
            cpu = ProcessCollector.cpuFraction(cpuNanos: timebase.nanos(ProcessCollector.delta(last.ticks, ticks)),
                                               wallNanos: Double(nowNanos - last.at), cores: cores)
        }
        lastTicks[key] = (ticks, nowNanos)
        var tracker = idle[key] ?? IdleTracker(since: now)
        tracker.observe(cpuNanos: timebase.nanos(ticks), at: now)
        idle[key] = tracker

        let path = Self.executablePath(pid)
        let rawName = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? Self.string(bsd.pbi_name).nonEmpty ?? Self.string(bsd.pbi_comm)
        // Same naming as the Apps screen, so a binary called "2.1.302" reads as its tool.
        let name = AppGrouper.toolIdentity(name: rawName, path: path ?? "").name
        let cwd = Self.workingDirectory(pid)
        let server = ServerProcess(
            pid: pid, name: name, executablePath: path ?? "",
            workingDirectory: cwd, projectPath: cwd.flatMap(project(for:)),
            started: Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6),
            ports: sockets.ports, establishedConnections: sockets.established,
            cpu: cpu, memory: gotUsage ? usage.ri_phys_footprint : 0,
            isIdle: sockets.established == 0 && tracker.isIdle(at: now, after: idleAfter)
        )
        return (server, key)
    }

    // MARK: Sockets

    struct Sockets {
        var ports: [ListeningPort]
        var established: Int
    }

    private func sockets(of pid: Int32) -> Sockets? {
        var bytes: Int32
        while true {
            bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { return nil }
            // A full buffer may mean truncation; grow and ask again.
            if Int(bytes) < fds.count * MemoryLayout<proc_fdinfo>.stride || fds.count >= 65536 { break }
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fds.count * 4)
        }
        let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var ports = Set<ListeningPort>()
        var established = 0
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for i in 0..<n where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let psi = info.psi
            let inet: in_sockinfo
            let state: Int32?
            if psi.soi_kind == Int32(SOCKINFO_TCP) {
                inet = psi.soi_proto.pri_tcp.tcpsi_ini
                state = psi.soi_proto.pri_tcp.tcpsi_state
            } else if psi.soi_kind == Int32(SOCKINFO_IN) {
                inet = psi.soi_proto.pri_in
                state = nil
            } else { continue }
            let local = Self.port(networkOrder: inet.insi_lport)
            let foreign = Self.port(networkOrder: inet.insi_fport)
            switch Self.classify(kind: psi.soi_kind, protocol: psi.soi_protocol, tcpState: state, localPort: local, foreignPort: foreign) {
            case .listening(let transport):
                ports.insert(ListeningPort(port: local, transport: transport, localOnly: Self.isLoopback(inet)))
            case .established:
                established += 1
            case .ignored:
                break
            }
        }
        return Sockets(ports: Self.merge(ports), established: established)
    }

    enum SocketRole: Equatable {
        case listening(ListeningPort.Transport)
        case established
        case ignored
    }

    /// UDP ports used for service discovery by nearly every app; not servers the user started.
    static let discoveryUDPPorts: Set<UInt16> = [137, 138, 1900, 5353]

    /// What one socket means for the Ports screen.
    /// UDP has no listen state: an unconnected socket bound to a fixed (non-ephemeral) port counts as listening.
    static func classify(kind: Int32, protocol proto: Int32, tcpState: Int32?, localPort: UInt16, foreignPort: UInt16) -> SocketRole {
        if kind == Int32(SOCKINFO_TCP) {
            switch tcpState {
            case Int32(TSI_S_LISTEN): return localPort == 0 ? .ignored : .listening(.tcp)
            case Int32(TSI_S_ESTABLISHED): return .established
            default: return .ignored
            }
        }
        guard kind == Int32(SOCKINFO_IN), proto == IPPROTO_UDP, localPort != 0, foreignPort == 0,
              localPort < 49152, !discoveryUDPPorts.contains(localPort) else { return .ignored }
        return .listening(.udp)
    }

    /// `insi_lport` holds the port in network byte order in its low 16 bits.
    @inline(__always) static func port(networkOrder raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    static func isLoopback(_ inet: in_sockinfo) -> Bool {
        if inet.insi_vflag & UInt8(INI_IPV4) != 0, inet.insi_vflag & UInt8(INI_IPV6) == 0 {
            return isLoopbackIPv4(networkOrder: inet.insi_laddr.ina_46.i46a_addr4.s_addr)
        }
        var a = inet.insi_laddr.ina_6
        return withUnsafeBytes(of: &a) { isLoopbackIPv6(Array($0)) }
    }

    /// 127.0.0.0/8, address in network byte order.
    static func isLoopbackIPv4(networkOrder s_addr: UInt32) -> Bool { UInt32(bigEndian: s_addr) >> 24 == 127 }

    /// ::1, or an IPv4-mapped loopback (::ffff:127.x.x.x).
    static func isLoopbackIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
    }

    /// One entry per port and transport. IPv4 and IPv6 sockets on one port merge; reachable from outside wins.
    static func merge(_ ports: Set<ListeningPort>) -> [ListeningPort] {
        var byKey: [String: ListeningPort] = [:]
        for p in ports {
            let k = "\(p.transport.rawValue)/\(p.port)"
            if let existing = byKey[k] { byKey[k]?.localOnly = existing.localOnly && p.localOnly } else { byKey[k] = p }
        }
        return byKey.values.sorted()
    }

    // MARK: Projects

    static let projectMarkers = [".git", "package.json", "Package.swift", "go.mod", "Cargo.toml", "pyproject.toml", "Gemfile", "pom.xml", "build.gradle", "composer.json", "deno.json"]

    private func project(for cwd: String) -> String? {
        if let cached = projectCache[cwd] { return cached }
        let root = Self.projectRoot(for: cwd, home: NSHomeDirectory()) { FileManager.default.fileExists(atPath: $0) }
        if projectCache.count > 512 { projectCache.removeAll() }
        projectCache[cwd] = root
        return root
    }

    /// Nearest folder at or above `cwd` with a project marker, never climbing to the home folder or "/".
    /// Without a marker the working directory itself is the project; "/" and home are never projects.
    static func projectRoot(for cwd: String, home: String, exists: (String) -> Bool) -> String? {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let start = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard start != "/", start != home, !start.isEmpty else { return nil }
        var dir = start
        while dir != home, dir != "/", !dir.isEmpty {
            if projectMarkers.contains(where: { exists(dir + "/" + $0) }) { return dir }
            guard let slash = dir.lastIndex(of: "/") else { break }
            dir = String(dir[..<slash])
        }
        return start
    }

    // MARK: libproc helpers

    /// True while `pid` is still the process that started at `started` (pids are reused).
    public static func isRunning(pid: Int32, started: Date) -> Bool {
        guard let bsd = bsdInfo(pid) else { return false }
        let start = Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6
        return abs(start - started.timeIntervalSince1970) < 0.001
    }

    private func listUserPIDs() -> Int {
        while true {
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { return 0 }
            let n = Int(bytes) / MemoryLayout<Int32>.stride
            if n < pids.count { return n }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? bsd : nil
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return ProcessCollector.executablePathFromArguments(pid) }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return string(info.pvi_cdir.vip_path).nonEmpty
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Remembers when a process last used CPU. Survives between scans, even if the screen was closed.
struct IdleTracker: Equatable {
    /// CPU time below this between two scans counts as no CPU (timers in an idle server).
    static let noiseFraction = 0.001
    private(set) var cpuNanos: Double
    private(set) var since: Date
    private var lastSeen: Date

    init(since: Date) {
        cpuNanos = -1
        self.since = since
        lastSeen = since
    }

    mutating func observe(cpuNanos now: Double, at date: Date) {
        defer { lastSeen = date; cpuNanos = now }
        guard cpuNanos >= 0 else { return }
        let wall = max(1, date.timeIntervalSince(lastSeen)) * 1e9
        if now - cpuNanos > wall * Self.noiseFraction { since = date }
    }

    func isIdle(at date: Date, after: TimeInterval) -> Bool { date.timeIntervalSince(since) >= after }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
