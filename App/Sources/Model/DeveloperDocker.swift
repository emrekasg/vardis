import Foundation
import Observation
import VardisCore

struct DockerContainer: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var image: String
    var status: String
    var state: String
    var ports: String
    var cpu: Double?
    var memory: String?
    var isRunning: Bool { state == "running" || state == "restarting" }
}

struct DockerDiskUsage: Identifiable, Equatable, Sendable {
    var id: String { type }
    var type: String
    var total: String
    var active: String
    var size: String
    var reclaimable: String
}

/// Docker through its own CLI. Runs only while the Docker screen is visible; nothing is polled otherwise.
@MainActor
@Observable
final class DockerModel {
    static let shared = DockerModel()

    enum Availability: Equatable {
        case checking
        case notInstalled
        case daemonDown(String)
        case ready
    }

    private(set) var availability: Availability = .checking
    private(set) var containers: [DockerContainer] = []
    private(set) var disk: [DockerDiskUsage] = []
    private(set) var busy: Set<String> = []

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var statsStream: StatsStream?
    @ObservationIgnored private var stats: [String: (cpu: Double, memory: String)] = [:]
    @ObservationIgnored private var lastDisk: ContinuousClock.Instant?
    @ObservationIgnored private var visible = 0

    func appear() {
        visible += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(300))
            }
        }
    }

    func disappear() {
        visible = max(0, visible - 1)
        guard visible == 0 else { return }
        loop?.cancel()
        loop = nil
        statsStream?.stop()
        statsStream = nil
    }

    private func refresh() async {
        guard let docker = Self.dockerExecutable() else {
            availability = .notInstalled
            return
        }
        let ps = await CommandRunner.run(docker, ["ps", "-a", "--format", "{{json .}}"], timeout: 2)
        guard !Task.isCancelled else { return }
        guard ps.status == 0 else {
            availability = .daemonDown(Self.daemonMessage(ps.error))
            containers = []
            statsStream?.stop()
            statsStream = nil
            return
        }
        availability = .ready
        // `docker stats --no-stream` takes about 2 s per call (it waits for two readings), so one streaming
        // process feeds CPU and memory while the screen is open instead of a new process every refresh.
        if statsStream == nil {
            statsStream = StatsStream(docker: docker) { [weak self] line in self?.ingestStats(line) }
        }
        var list = Self.parseContainers(ps.output)
        for i in list.indices {
            if list[i].isRunning, let s = stats[list[i].id] { list[i].cpu = s.cpu; list[i].memory = s.memory }
        }
        containers = list.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }

        // `docker system df` walks every image and volume (7 s on a busy engine), so it runs on its own,
        // at most every 30 s, and never holds up the container list.
        if lastDisk.map({ ContinuousClock.now - $0 > .seconds(30) }) ?? true {
            lastDisk = .now
            Task { [weak self] in
                let df = await CommandRunner.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 15)
                if df.status == 0 { self?.disk = Self.parseDisk(df.output) }
            }
        }
    }

    private func ingestStats(_ line: String) {
        guard let obj = Self.jsonObject(line), let id = obj["ID"] as? String else { return }
        let cpu = Self.percent(obj["CPUPerc"] as? String ?? "") ?? 0
        let mem = (obj["MemUsage"] as? String ?? "").split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        stats[id] = (cpu, mem)
        if let i = containers.firstIndex(where: { $0.id == id }) {
            containers[i].cpu = cpu
            containers[i].memory = mem
        }
    }

    /// Start or stop after the view has confirmed with the user.
    func perform(_ verb: String, on container: DockerContainer) async -> String? {
        guard let docker = Self.dockerExecutable() else { return "Docker is not installed." }
        busy.insert(container.id)
        defer { busy.remove(container.id) }
        let r = await CommandRunner.run(docker, [verb, container.id], timeout: 20)
        await refresh()
        return r.status == 0 ? nil : (r.error.isEmpty ? "Docker did not \(verb) \(container.name)." : r.error)
    }

    // MARK: Parsing

    static func jsonObject(_ line: String) -> [String: Any]? {
        // Streaming stats prefix lines with terminal escapes such as ESC[H and ESC[2J.
        guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close else { return nil }
        let data = Data(line[open...close].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseContainers(_ output: String) -> [DockerContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let o = jsonObject(String(line)), let id = o["ID"] as? String else { return nil }
            return DockerContainer(id: id, name: o["Names"] as? String ?? id, image: o["Image"] as? String ?? "",
                                   status: o["Status"] as? String ?? "", state: (o["State"] as? String ?? "").lowercased(),
                                   ports: tidyPorts(o["Ports"] as? String ?? ""), cpu: nil, memory: nil)
        }
    }

    static func parseDisk(_ output: String) -> [DockerDiskUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let o = jsonObject(String(line)), let type = o["Type"] as? String else { return nil }
            func s(_ k: String) -> String { (o[k] as? String) ?? (o[k] as? Int).map(String.init) ?? "" }
            return DockerDiskUsage(type: type, total: s("TotalCount"), active: s("Active"), size: s("Size"), reclaimable: s("Reclaimable"))
        }
    }

    /// "0.0.0.0:3124->3000/tcp, [::]:3124->3000/tcp" -> "3124→3000". IPv4 and IPv6 duplicates collapse.
    static func tidyPorts(_ raw: String) -> String {
        var seen = [String]()
        for part in raw.split(separator: ",") {
            var p = part.trimmingCharacters(in: .whitespaces)
            if let colon = p.range(of: ":", options: .backwards), p.contains("->") { p = String(p[colon.upperBound...]) }
            p = p.replacingOccurrences(of: "->", with: "→").replacingOccurrences(of: "/tcp", with: "")
            if !p.isEmpty, !seen.contains(p) { seen.append(p) }
        }
        return seen.joined(separator: ", ")
    }

    static func percent(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
    }

    static func daemonMessage(_ error: String) -> String {
        if error.contains("permission denied") {
            return "Docker refused the connection. Check that your user can use the Docker engine, then come back."
        }
        if error.contains("Cannot connect") || error.contains("daemon") || error.isEmpty {
            return "Docker is installed, but its engine is not running. Start Docker Desktop, OrbStack or Colima and this screen fills in."
        }
        return error
    }

    // MARK: Finding the CLI

    nonisolated static func dockerExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.orbstack/bin/docker",
                          home + "/.docker/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") { candidates.append(dir + "/docker") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Runs a short command off the main thread with a hard timeout.
enum CommandRunner {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, output: "", error: error.localizedDescription))
                    return
                }
                let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Read stderr concurrently so a chatty command cannot fill its pipe and stall.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()
                deadline.cancel()
                let timedOut = p.terminationReason == .uncaughtSignal
                cont.resume(returning: Result(status: timedOut ? -2 : p.terminationStatus,
                                              output: String(decoding: outData, as: UTF8.self),
                                              error: timedOut ? "Docker did not answer within \(Int(timeout)) s." :
                                                  String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}

/// `docker stats --format json` left running; each line is handed to the main actor.
final class StatsStream: @unchecked Sendable {
    private let process = Process()
    private var buffer = Data()

    @MainActor init(docker: URL, onLine: @escaping @MainActor (String) -> Void) {
        process.executableURL = docker
        process.arguments = ["stats", "--format", "{{json .}}"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { h.readabilityHandler = nil; return }
            self.buffer.append(chunk)
            var lines = [String]()
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: self.buffer[..<nl], as: UTF8.self))
                self.buffer.removeSubrange(...nl)
            }
            guard !lines.isEmpty else { return }
            Task { @MainActor in for l in lines { onLine(l) } }
        }
        try? process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}
