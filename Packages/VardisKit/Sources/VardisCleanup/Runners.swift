import Foundation

/// Lists unavailable simulator devices. Returns `simctl list devices unavailable -j` output, or nil when simctl is absent.
public protocol SimctlRunner: Sendable {
    func unavailableDevicesJSON() async -> Data?
}

/// Output of one command.
public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data, stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs the Docker CLI (Docker Desktop, OrbStack and Colima all ship one). Returns nil when no
/// `docker` binary exists. Tests pass a stub, so nothing real is ever removed by them.
public protocol DockerRunner: Sendable {
    func docker(_ arguments: [String], timeout: TimeInterval) async -> CommandOutput?
}

public struct SystemSimctlRunner: SimctlRunner {
    public init() {}

    public func unavailableDevicesJSON() async -> Data? {
        // `xcrun` on a Mac without developer tools pops an install dialog, so check
        // that the selected developer directory really has simctl before calling it.
        guard let dir = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], timeout: 5)
            .flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !dir.isEmpty,
            FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/simctl")
        else { return nil }
        return ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "list", "devices", "unavailable", "-j"], timeout: 20)
    }
}

public struct SystemDockerRunner: DockerRunner {
    public init() {}

    /// Same places the Docker screen looks, plus PATH.
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.orbstack/bin/docker",
                          home + "/.docker/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
                          "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") { candidates.append(dir + "/docker") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func docker(_ arguments: [String], timeout: TimeInterval) async -> CommandOutput? {
        guard let exe = Self.executable() else { return nil }
        return ProcessRunner.runFull(exe, arguments, timeout: timeout)
    }
}

enum ProcessRunner {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs a tool and returns stdout when it exits 0 within `timeout`.
    static func run(_ executable: URL, _ args: [String], timeout: TimeInterval) -> Data? {
        guard let r = runFull(executable, args, timeout: timeout), r.status == 0 else { return nil }
        return r.stdout
    }

    /// Runs a tool; nil when it cannot start or does not finish within `timeout`.
    static func runFull(_ executable: URL, _ args: [String], timeout: TimeInterval) -> CommandOutput? {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }

        let box = Box(), errBox = Box()
        let readDone = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.set(handle.readDataToEndOfFile())
            readDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errHandle.readDataToEndOfFile())
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        _ = readDone.wait(timeout: .now() + 2)
        return CommandOutput(status: p.terminationStatus, stdout: box.get(),
                             stderr: String(decoding: errBox.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Parsing

struct SimDevice: Decodable, Sendable {
    var udid: String
    var name: String
    var isAvailable: Bool?
    var availabilityError: String?
}

enum SimctlParser {
    /// Pairs of (runtime label, device).
    static func devices(_ data: Data) -> [(runtime: String, device: SimDevice)] {
        struct Root: Decodable { var devices: [String: [SimDevice]] }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        return root.devices.sorted { $0.key < $1.key }.flatMap { key, list in
            list.filter { $0.isAvailable != true }.map { (runtimeLabel(key), $0) }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-0" -> "iOS 17.0"
    static func runtimeLabel(_ key: String) -> String {
        let last = key.split(separator: ".").last.map(String.init) ?? key
        let parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return last }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }
}

struct DockerUsage: Sendable, Equatable {
    var type: String
    var reclaimableBytes: UInt64
    var totalCount: String
}

enum DockerParser {
    private struct Row: Decodable {
        var `Type`: String
        var Reclaimable: String?
        var TotalCount: String?
    }

    /// Accepts JSON lines (current Docker) or a JSON array.
    static func usage(_ data: Data) -> [DockerUsage] {
        var rows: [Row] = []
        if let arr = try? JSONDecoder().decode([Row].self, from: data) {
            rows = arr
        } else {
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let r = try? JSONDecoder().decode(Row.self, from: Data(line)) { rows.append(r) }
            }
        }
        return rows.map { DockerUsage(type: $0.Type, reclaimableBytes: parseSize($0.Reclaimable ?? "0B"), totalCount: $0.TotalCount ?? "") }
    }

    /// Docker prints decimal units: "1.2GB", "512.5kB", "800MB (66%)".
    static func parseSize(_ s: String) -> UInt64 {
        let head = s.split(separator: " ").first.map(String.init) ?? s
        let digits = head.prefix { $0.isNumber || $0 == "." }
        guard let n = Double(digits) else { return 0 }
        let unit = head.dropFirst(digits.count).uppercased()
        let mult: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        case "PB": 1e15
        default: 1
        }
        return UInt64(max(0, n * mult))
    }
}
