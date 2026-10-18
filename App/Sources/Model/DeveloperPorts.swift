import Darwin
import Foundation
import Observation
import VardisCore
import VardisSampling

struct ServerRow: Identifiable, Equatable {
    var process: ServerProcess
    var app: AppIdentity?
    var id: Int32 { process.pid }
}

struct ProjectGroup: Identifiable, Equatable {
    /// nil collects servers started outside any folder (launchd, "/").
    var path: String?
    var servers: [ServerRow]
    var id: String { path ?? "" }
    var title: String { path.map { ($0 as NSString).lastPathComponent } ?? "Elsewhere" }
    var subtitle: String { path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Started outside a project folder" }
}

/// Listening sockets of the user's processes. Scans every 2 s, only while the Ports screen is visible.
/// The scanner (and its idle bookkeeping) lives for the whole app run, so "idle" survives closing the screen.
@MainActor
@Observable
final class PortsModel {
    static let shared = PortsModel()

    private(set) var groups: [ProjectGroup] = []
    private(set) var hasScanned = false
    var serverCount: Int { groups.reduce(0) { $0 + $1.servers.count } }
    var portCount: Int { groups.reduce(0) { $0 + $1.servers.reduce(0) { $0 + $1.process.ports.count } } }

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visible = 0

    func appear(live: LiveModel) {
        visible += 1
        guard loop == nil else { return }
        loop = Task { [weak self, weak live] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(live: live)
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(200))
            }
        }
    }

    func disappear() {
        visible = max(0, visible - 1)
        guard visible == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    func refresh(live: LiveModel?) async {
        let found = await scanner.scan()
        let apps = await live?.apps(forPIDs: found.map(\.pid)) ?? [:]
        guard !Task.isCancelled else { return }
        let rows = found.map { ServerRow(process: $0, app: apps[$0.pid]) }
        let next = Self.group(rows)
        if next != groups { groups = next }
        hasScanned = true
    }

    /// Groups by project folder; named projects first (alphabetically), "Elsewhere" last.
    static func group(_ rows: [ServerRow]) -> [ProjectGroup] {
        let byPath = Dictionary(grouping: rows) { $0.process.projectPath }
        return byPath.map { ProjectGroup(path: $0.key, servers: $0.value.sorted { ($0.process.ports.first?.port ?? 0) < ($1.process.ports.first?.port ?? 0) }) }
            .sorted { a, b in
                switch (a.path, b.path) {
                case (nil, _): false
                case (_, nil): true
                default: a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
    }

    /// Sends `signal` to the process only if the pid still belongs to the same process instance.
    func send(_ signal: Int32, to p: ServerProcess) -> Bool {
        guard PortScanner.isRunning(pid: p.pid, started: p.started) else { return false }
        return kill(p.pid, signal) == 0
    }

    func isAlive(_ p: ServerProcess) -> Bool { PortScanner.isRunning(pid: p.pid, started: p.started) }
}
