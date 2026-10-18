import Foundation

/// Lists unavailable simulator devices. Returns `simctl list devices unavailable -j` output, or nil when simctl is absent.
public protocol SimctlRunner: Sendable {
    func unavailableDevicesJSON() async -> Data?
}

/// Returns `docker system df --format json` output, or nil when Docker is absent or not running.
public protocol DockerRunner: Sendable {
    func systemDFJSON() async -> Data?
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
    public static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    public init() {}

    public func systemDFJSON() async -> Data? {
        guard let path = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return ProcessRunner.run(URL(fileURLWithPath: path), ["system", "df", "--format", "json"], timeout: 30)
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
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }

        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.set(handle.readDataToEndOfFile())
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        return p.terminationStatus == 0 ? box.get() : nil
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
