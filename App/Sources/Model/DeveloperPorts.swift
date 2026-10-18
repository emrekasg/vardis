import AppKit
import Darwin
import Foundation
import Observation
import VardisCore
import VardisSampling

/// One thing listening on a port: a process, or a container published through Docker/OrbStack.
struct DevServer: Identifiable, Equatable {
    enum Kind: Equatable {
        case process(ServerProcess, AppIdentity?)
        case container(PublishedContainer)
    }

    var kind: Kind
    var projectPath: String?

    var id: String {
        switch kind {
        case .process(let p, _): "p\(p.pid)"
        case .container(let c): "c\(c.id)"
        }
    }
    var name: String {
        switch kind {
        case .process(let p, _): p.name
        case .container(let c): c.name
        }
    }
    var detail: String {
        switch kind {
        case .process(let p, _): "\(p.pid)"
        case .container(let c): c.image
        }
    }
    var ports: [ListeningPort] {
        switch kind {
        case .process(let p, _): p.ports
        case .container(let c): c.ports
        }
    }
    var ownership: ServerOwnership {
        switch kind {
        case .process(let p, _): p.ownership
        case .container: .container
        }
    }
    var process: ServerProcess? { if case .process(let p, _) = kind { p } else { nil } }
    var container: PublishedContainer? { if case .container(let c) = kind { c } else { nil } }
    var app: AppIdentity? { if case .process(_, let a) = kind { a } else { nil } }
    var cpu: Double? { process?.cpu }
    var memory: UInt64? { process?.memory }
    var started: Date? { process?.started }
    var idleSince: Date? { process?.idleSince }
    var isIdle: Bool { process?.isIdle ?? false }
    var httpPorts: [UInt16] { ports.filter(\.looksLikeHTTP).map(\.port) }

    /// Only the user's own processes and containers can be stopped. Container runtimes and system daemons never.
    var stopTarget: StopTarget? {
        switch kind {
        case .process(let p, _):
            guard p.ownership == .yours else { return nil }
            return StopTarget(kind: .process(.init(pid: p.pid, started: p.started)), name: p.name, project: projectPath,
                              ports: p.ports.map(\.port), memory: p.memory, idleSince: p.idleSince)
        case .container(let c):
            return StopTarget(kind: .container(id: c.id), name: c.name, project: projectPath,
                              ports: c.ports.map(\.port), memory: nil, idleSince: nil)
        }
    }
}

/// A port another project's config asks for, taken by someone else.
struct PortConflict: Equatable, Hashable {
    var port: UInt16
    var holder: String
}

struct DevProject: Identifiable, Equatable {
    enum Place: Hashable { case folder(String), elsewhere, system }
    var place: Place
    var servers: [DevServer]
    var conflicts: [PortConflict] = []

    var id: String {
        switch place {
        case .folder(let p): p
        case .elsewhere: "~elsewhere"
        case .system: "~system"
        }
    }
    var path: String? { if case .folder(let p) = place { p } else { nil } }
    var title: String {
        switch place {
        case .folder(let p): (p as NSString).lastPathComponent
        case .elsewhere: "Elsewhere"
        case .system: "macOS and other accounts"
        }
    }
    var subtitle: String {
        switch place {
        case .folder(let p): (p as NSString).abbreviatingWithTildeInPath
        case .elsewhere: "Started outside a project folder"
        case .system: "Never stopped from Vardis"
        }
    }
    var cpu: Double { servers.reduce(0) { $0 + ($1.cpu ?? 0) } }
    var memory: UInt64 { servers.reduce(0) { $0 + ($1.memory ?? 0) } }
    var ports: [ListeningPort] { servers.flatMap(\.ports).sorted() }
    var stopTargets: [StopTarget] { servers.compactMap(\.stopTarget) }
}

/// Something Vardis may stop after the user confirmed it.
struct StopTarget: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case process(ProcessStopper.Target)
        case container(id: String)
    }

    var kind: Kind
    var name: String
    var project: String?
    var ports: [UInt16]
    var memory: UInt64?
    var idleSince: Date?

    var id: String {
        switch kind {
        case .process(let t): "p\(t.pid)"
        case .container(let id): "c\(id)"
        }
    }
    var isContainer: Bool { if case .container = kind { true } else { false } }
    var projectName: String? { project.map { ($0 as NSString).lastPathComponent } }
    var portsText: String { ports.prefix(4).map { ":\($0)" }.joined(separator: " ") + (ports.count > 4 ? " +\(ports.count - 4)" : "") }
}

struct StopOutcome: Equatable {
    var stopped: [StopTarget] = []
    /// Did not quit within the grace period; may be force quit.
    var stillRunning: [StopTarget] = []
    var failed: [(target: StopTarget, message: String)] = []
    var freed: UInt64 { stopped.reduce(0) { $0 + ($1.memory ?? 0) } }

    static func == (a: StopOutcome, b: StopOutcome) -> Bool {
        a.stopped == b.stopped && a.stillRunning == b.stillRunning && a.failed.map(\.target) == b.failed.map(\.target)
    }
}

/// What `docker stop` and our own signals need to know about one HTTP port.
struct HTTPInfo: Equatable, Sendable {
    var title: String?
}

/// Listening sockets grouped by project folder, with Compose containers under the folder they came from.
/// Scans every 2 s while the Ports screen or the menu panel's Ports section is visible, and every 60 s
/// (scanner only: no Docker, no HTTP probes, no config reads) while only the sidebar badge needs a count.
/// The scanner and its idle bookkeeping live for the whole app run, so "idle" survives closing the screen.
@MainActor
@Observable
final class PortsModel {
    static let shared = PortsModel()

    /// Every project, system group included.
    private(set) var allProjects: [DevProject] = []
    private(set) var hasScanned = false
    /// Servers that are the user's or containers (what the badge counts).
    private(set) var devServerCount = 0
    private(set) var http: [UInt16: HTTPInfo] = [:]
    var showSystem = false

    var projects: [DevProject] { showSystem ? allProjects : allProjects.filter { $0.place != .system } }
    var servers: [DevServer] { projects.flatMap(\.servers) }
    var serverCount: Int { servers.count }
    var portCount: Int { servers.reduce(0) { $0 + $1.ports.count } }
    var systemServerCount: Int { allProjects.first { $0.place == .system }?.servers.count ?? 0 }
    /// Everything Vardis may stop, idle first.
    var stoppable: [StopTarget] {
        allProjects.flatMap(\.stopTargets).sorted { ($0.idleSince ?? .distantFuture) < ($1.idleSince ?? .distantFuture) }
    }
    var idleTargets: [StopTarget] { stoppable.filter { $0.idleSince != nil } }

    /// Servers of every ownership listening on `port`.
    func holders(of port: UInt16) -> [(project: DevProject, server: DevServer)] {
        allProjects.flatMap { p in p.servers.filter { $0.ports.contains { $0.port == port } }.map { (p, $0) } }
    }

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopIsFast = false
    @ObservationIgnored private var visible = 0
    @ObservationIgnored private var badgeViewers = 0
    @ObservationIgnored private weak var live: LiveModel?
    @ObservationIgnored private var containers: [PublishedContainer] = []
    @ObservationIgnored private var lastDocker: ContinuousClock.Instant?
    @ObservationIgnored private var dockerInFlight = false
    @ObservationIgnored private var httpProbed: [UInt16: (pid: String, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var probing = Set<UInt16>()
    @ObservationIgnored private var configPorts: [String: (ports: [UInt16], at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var lastFound: [ServerProcess] = []
    @ObservationIgnored private var lastApps: [Int32: AppIdentity] = [:]

    // MARK: Visibility

    /// The Ports screen or the menu panel's Ports section is on screen: full scans every 2 s.
    func appear(live: LiveModel?) {
        if let live { self.live = live }
        visible += 1
        reschedule()
    }

    func disappear() {
        visible = max(0, visible - 1)
        reschedule()
    }

    /// The sidebar badge is on screen: a scanner-only count every 60 s.
    func badgeAppear() {
        badgeViewers += 1
        reschedule()
    }

    func badgeDisappear() {
        badgeViewers = max(0, badgeViewers - 1)
        reschedule()
    }

    private func reschedule() {
        let fast = visible > 0
        let wanted = fast || badgeViewers > 0
        guard wanted else { loop?.cancel(); loop = nil; return }
        if loop != nil && loopIsFast == fast { return }
        loop?.cancel()
        loopIsFast = fast
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(full: fast)
                if fast {
                    try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(200))
                } else {
                    try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
                }
            }
        }
    }

    /// Scans now (after a stop, so the list does not show what just quit).
    func refreshSoon() {
        Task { await refresh(full: visible > 0) }
    }

    // MARK: Scanning

    /// A scanner-only pass for a count (menu bar readout). No Docker, HTTP probes or config reads.
    func refresh(live: LiveModel?) async {
        if let live { self.live = live }
        await refresh(full: false)
    }

    func refresh(full: Bool) async {
        let found = await scanner.scan()
        guard !Task.isCancelled else { return }
        lastFound = found
        if full {
            lastApps = await live?.apps(forPIDs: found.map(\.pid)) ?? [:]
            refreshContainersIfNeeded(found)
        } else if !found.contains(where: { $0.ownership == .container }) {
            // The runtime stopped while nobody was looking; its containers went with it.
            containers = []
        }
        rebuild()
        if full {
            probeHTTP()
            readConfigs()
        }
    }

    private func rebuild() {
        let next = Self.build(processes: lastFound, apps: lastApps, containers: containers, configPorts: configPorts.mapValues(\.ports))
        if next != allProjects { allProjects = next }
        let count = next.filter { $0.place != .system }.reduce(0) { $0 + $1.servers.count }
        if count != devServerCount { devServerCount = count }
        hasScanned = true
    }

    /// `docker ps` only while something is showing, at most every 5 s, and only when a container runtime
    /// is listening (so a Mac without Docker running never launches the CLI).
    private func refreshContainersIfNeeded(_ found: [ServerProcess]) {
        guard found.contains(where: { $0.ownership == .container }) else { containers = []; return }
        guard !dockerInFlight, lastDocker.map({ ContinuousClock.now - $0 > .seconds(5) }) ?? true else { return }
        guard let docker = DockerModel.dockerExecutable() else { return }
        dockerInFlight = true
        lastDocker = .now
        Task { [weak self] in
            let r = await CommandRunner.run(docker, ["ps", "--format", ContainerList.format], timeout: 3)
            guard let self else { return }
            self.dockerInFlight = false
            let list = r.status == 0 ? ContainerList.parse(r.output) : []
            if list != self.containers {
                self.containers = list
                self.rebuild()
            }
        }
    }

    /// Groups processes and containers by project folder; named projects first, then Elsewhere, then the system.
    /// A container runtime's ports that belong to a known container are shown as that container instead.
    static func build(processes: [ServerProcess], apps: [Int32: AppIdentity], containers: [PublishedContainer],
                      configPorts: [String: [UInt16]]) -> [DevProject] {
        let containerPorts = Set(containers.flatMap { $0.ports.map(\.port) })
        var servers: [(DevProject.Place, DevServer)] = []
        for p in processes {
            var p = p
            if p.ownership == .container {
                p.ports = p.ports.filter { !containerPorts.contains($0.port) }
                if p.ports.isEmpty { continue }
            }
            let place: DevProject.Place = p.ownership == .system ? .system : p.projectPath.map { .folder($0) } ?? .elsewhere
            servers.append((place, DevServer(kind: .process(p, apps[p.pid]), projectPath: p.projectPath)))
        }
        for c in containers {
            let place: DevProject.Place = c.workingDirectory.map { .folder($0) } ?? .elsewhere
            servers.append((place, DevServer(kind: .container(c), projectPath: c.workingDirectory)))
        }
        var projects = Dictionary(grouping: servers, by: \.0).map { place, list in
            DevProject(place: place, servers: list.map(\.1).sorted { ($0.ports.first?.port ?? 0, $0.name) < ($1.ports.first?.port ?? 0, $1.name) })
        }
        // A port this project's config asks for, held by a server outside the project.
        for i in projects.indices {
            guard let path = projects[i].path, let wanted = configPorts[path] else { continue }
            let own = Set(projects[i].ports.map(\.port))
            for port in wanted where !own.contains(port) {
                if let other = projects.first(where: { $0.id != projects[i].id && $0.ports.contains { $0.port == port } }) {
                    let holder = other.servers.first { $0.ports.contains { $0.port == port } }
                    projects[i].conflicts.append(PortConflict(port: port, holder: other.path == nil ? (holder?.name ?? other.title) : other.title))
                }
            }
        }
        func rank(_ p: DevProject) -> Int {
            switch p.place {
            case .folder: 0
            case .elsewhere: 1
            case .system: 2
            }
        }
        return projects.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    // MARK: HTTP probes and config files (only while visible)

    /// HEAD to 127.0.0.1 for HTTP-looking ports, cached per port and owning server for 60 s.
    private func probeHTTP() {
        let now = ContinuousClock.now
        var wanted: [(UInt16, String)] = []
        for s in servers where s.ownership != .system {
            for port in s.httpPorts {
                if probing.contains(port) { continue }
                if let last = httpProbed[port], last.pid == s.id, now - last.at < .seconds(60) { continue }
                wanted.append((port, s.id))
            }
        }
        guard !wanted.isEmpty else { return }
        for (port, owner) in wanted.prefix(8) {
            probing.insert(port)
            Task { [weak self] in
                let info = await HTTPProbe.probe(port: port)
                guard let self else { return }
                self.probing.remove(port)
                self.httpProbed[port] = (owner, .now)
                if self.http[port] != info { self.http[port] = info }
            }
        }
    }

    /// Ports a project's own config asks for, re-read every 30 s. Small files, off the main thread.
    private func readConfigs() {
        let now = ContinuousClock.now
        let paths = allProjects.compactMap(\.path).filter { p in configPorts[p].map { now - $0.at > .seconds(30) } ?? true }
        guard !paths.isEmpty else { return }
        for p in paths { configPorts[p] = (configPorts[p]?.ports ?? [], now) }
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { paths.map { ($0, DevPortConfig.read(folder: $0)) } }.value
            guard let self else { return }
            var changed = false
            for (p, ports) in read where self.configPorts[p]?.ports != ports {
                self.configPorts[p] = (ports, .now)
                changed = true
            }
            if changed { self.rebuild() }
        }
    }

    // MARK: Stopping (always after the user confirmed)

    /// SIGTERM to processes and `docker stop` to containers, then waits up to 3 s for the processes.
    func stop(_ targets: [StopTarget]) async -> StopOutcome {
        var outcome = StopOutcome()
        var signalled: [StopTarget] = []
        for t in targets {
            guard case .process(let p) = t.kind else { continue }
            if ProcessStopper.send(SIGTERM, to: p) {
                signalled.append(t)
            } else if ProcessStopper.isAlive(p) {
                outcome.failed.append((t, "Vardis is not allowed to stop it."))
            } else {
                outcome.stopped.append(t) // already gone
            }
        }
        async let containerResults = stopContainers(targets.filter(\.isContainer))
        let survivors = Set(await ProcessStopper.waitForExit(signalled.compactMap(\.processTarget), timeout: .seconds(3)))
        for t in signalled {
            if let p = t.processTarget, survivors.contains(p) { outcome.stillRunning.append(t) } else { outcome.stopped.append(t) }
        }
        for (t, error) in await containerResults {
            if let error { outcome.failed.append((t, error)) } else { outcome.stopped.append(t) }
        }
        refreshSoon()
        return outcome
    }

    /// SIGKILL to processes that ignored SIGTERM. The user asked for this a second time.
    func forceQuit(_ targets: [StopTarget]) async -> StopOutcome {
        var outcome = StopOutcome()
        var signalled: [StopTarget] = []
        for t in targets {
            guard let p = t.processTarget else { continue }
            if ProcessStopper.send(SIGKILL, to: p) { signalled.append(t) } else if !ProcessStopper.isAlive(p) { outcome.stopped.append(t) } else {
                outcome.failed.append((t, "Vardis is not allowed to stop it."))
            }
        }
        let survivors = Set(await ProcessStopper.waitForExit(signalled.compactMap(\.processTarget), timeout: .seconds(2)))
        for t in signalled {
            if let p = t.processTarget, survivors.contains(p) { outcome.failed.append((t, "It is still running.")) } else { outcome.stopped.append(t) }
        }
        refreshSoon()
        return outcome
    }

    private func stopContainers(_ targets: [StopTarget]) async -> [(StopTarget, String?)] {
        guard !targets.isEmpty else { return [] }
        guard let docker = DockerModel.dockerExecutable() else { return targets.map { ($0, "Docker is not installed.") } }
        return await withTaskGroup(of: (StopTarget, String?).self) { group in
            for t in targets {
                guard case .container(let id) = t.kind else { continue }
                group.addTask {
                    let r = await CommandRunner.run(docker, ["stop", id], timeout: 20)
                    return (t, r.status == 0 ? nil : (r.error.isEmpty ? "Docker did not stop it." : r.error))
                }
            }
            var out: [(StopTarget, String?)] = []
            for await r in group { out.append(r) }
            return out
        }
    }
}

extension StopTarget {
    var processTarget: ProcessStopper.Target? { if case .process(let t) = kind { t } else { nil } }
}

// MARK: Formatting

enum IdleFmt {
    /// "idle 40 min", "idle 2 h", "idle 3 days".
    static func text(since: Date, now: Date = .now) -> String {
        let m = max(0, Int(now.timeIntervalSince(since) / 60))
        if m < 60 { return "idle \(m) min" }
        if m < 48 * 60 { return "idle \(m / 60) h" }
        return "idle \(m / 1440) days"
    }

    /// "frees 96 MB" phrasing; nil when nothing is known.
    static func frees(_ targets: [StopTarget]) -> UInt64 { targets.reduce(0) { $0 + ($1.memory ?? 0) } }
}

/// Apps that can open a project folder.
@MainActor
enum ProjectOpeners {
    struct Opener: Identifiable {
        var id: String { bundleID }
        let name: String
        let bundleID: String
        let url: URL
    }

    static let terminal: Opener? = find("Terminal", "com.apple.Terminal")
    /// Installed editors, Cursor first.
    static let editors: [Opener] = [find("Cursor", "com.todesktop.230313mzl4w4u92"), find("Visual Studio Code", "com.microsoft.VSCode"),
                                    find("Zed", "dev.zed.Zed")].compactMap { $0 }

    private static func find(_ name: String, _ id: String) -> Opener? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Opener(name: name, bundleID: id, url: $0) }
    }

    static func open(_ folder: String, with opener: Opener) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: opener.url, configuration: config)
    }

    static func reveal(_ folder: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
    }

    static func browse(_ port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}
