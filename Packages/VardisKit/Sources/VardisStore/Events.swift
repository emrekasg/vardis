import Foundation
import VardisCore

/// Something worth pointing at later: Today's digest, Time Machine's "what happened around it", alerts.
public struct HistoryEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case appLaunched, appQuit
        /// `detail` is the new pressure level ("normal", "warning", "critical").
        case memoryPressure
        /// `value` is swap in use, bytes.
        case swapGrew
        /// An app stayed above the CPU threshold; `value` is the threshold.
        case cpuHog
        /// The hot spell ended; `value` is its length in seconds.
        case cpuHogEnded
        /// `value` is the growth rate in bytes per hour; `detail` says from what to what.
        case memoryGrowth
        case sleep, wake
        /// An app holds a power assertion that keeps the Mac awake; `detail` is the assertion name.
        case keptAwakeStarted
        /// `value` is how long it was held, seconds.
        case keptAwakeEnded
    }

    public var timestamp: Date
    public var kind: Kind
    public var app: String?
    public var detail: String
    public var value: Double?

    public init(timestamp: Date, kind: Kind, app: String? = nil, detail: String = "", value: Double? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
        self.detail = detail
        self.value = value
    }
}

/// Detectors that only need the live snapshot stream: pressure changes, swap growth steps,
/// and apps that stay above `cpuThreshold` (fraction of the whole Mac) for `cpuHoldSeconds`.
public struct SnapshotDetector: Sendable {
    public var cpuThreshold = 0.8
    public var cpuRearm = 0.6
    public var cpuHoldSeconds: TimeInterval = 120
    public var swapStep: UInt64 = 1_000_000_000

    private var lastPressure: MemoryPressure?
    private var swapLevel: UInt64?
    private struct Hot: Sendable { var name: String; var since: Date; var fired: Bool }
    private var hot: [String: Hot] = [:]

    public init() {}

    /// The pressure level already on record (from an earlier run), so a relaunch does not
    /// report the same level again.
    public mutating func seed(pressure: MemoryPressure) { lastPressure = pressure }

    public mutating func ingest(_ s: Snapshot) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        let t = s.timestamp

        if let last = lastPressure, last != s.memory.pressure {
            out.append(HistoryEvent(timestamp: t, kind: .memoryPressure, detail: s.memory.pressure.rawValue))
        } else if lastPressure == nil, s.memory.pressure != .normal {
            out.append(HistoryEvent(timestamp: t, kind: .memoryPressure, detail: s.memory.pressure.rawValue))
        }
        lastPressure = s.memory.pressure

        let level = s.memory.swapUsed / swapStep
        if let last = swapLevel, level > last {
            out.append(HistoryEvent(timestamp: t, kind: .swapGrew, detail: "Swap reached \(Fmt.bytes(level * swapStep))", value: Double(s.memory.swapUsed)))
        }
        swapLevel = level

        var seen = Set<String>()
        for app in s.apps {
            seen.insert(app.id)
            if app.cpu >= cpuThreshold {
                var h = hot[app.id] ?? Hot(name: app.name, since: t, fired: false)
                if !h.fired, t.timeIntervalSince(h.since) >= cpuHoldSeconds {
                    h.fired = true
                    out.append(HistoryEvent(timestamp: h.since, kind: .cpuHog, app: app.name,
                                            detail: "Above \(Fmt.percent(cpuThreshold)) CPU for \(Fmt.duration(cpuHoldSeconds))", value: cpuThreshold))
                }
                hot[app.id] = h
            } else if app.cpu < cpuRearm {
                end(app.id, at: t, into: &out)
            }
        }
        for id in hot.keys where !seen.contains(id) { end(id, at: t, into: &out) }
        return out
    }

    private mutating func end(_ id: String, at t: Date, into out: inout [HistoryEvent]) {
        guard let h = hot.removeValue(forKey: id) else { return }
        if h.fired {
            let d = t.timeIntervalSince(h.since)
            out.append(HistoryEvent(timestamp: t, kind: .cpuHogEnded, app: h.name, detail: "Busy for \(Fmt.duration(d))", value: d))
        }
    }
}

/// Least-squares line through (seconds, bytes) points, used to spot apps whose memory only goes up.
public enum MemoryTrend {
    public struct Fit: Sendable, Equatable {
        /// Bytes per second.
        public var slope: Double
        public var r2: Double
        public var span: TimeInterval
        public var first: Double
        public var last: Double
        public var count: Int
        public var bytesPerHour: Double { slope * 3_600 }
    }

    public static func fit(_ points: [(t: TimeInterval, bytes: Double)]) -> Fit? {
        let n = Double(points.count)
        guard points.count >= 3, let t0 = points.first?.t, let t1 = points.last?.t, t1 > t0 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let x = p.t - t0, y = p.bytes
            sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y
        }
        let vx = sxx - sx * sx / n
        let vy = syy - sy * sy / n
        guard vx > 0 else { return nil }
        let cov = sxy - sx * sy / n
        let slope = cov / vx
        let r2 = vy > 0 ? (cov * cov) / (vx * vy) : 0
        let intercept = (sy - slope * sx) / n
        return Fit(slope: slope, r2: r2, span: t1 - t0, first: intercept, last: intercept + slope * (t1 - t0), count: points.count)
    }

    /// Thresholds for "steady growth": at least 50 MB an hour, R² above 0.8, three hours of data
    /// with 120+ points, and 300 MB gained overall.
    public static func isSteadyGrowth(_ f: Fit, minBytesPerHour: Double = 50_000_000, minR2: Double = 0.8,
                                      minSpan: TimeInterval = 3 * 3_600, minPoints: Int = 120, minGrowth: Double = 300_000_000) -> Bool {
        f.bytesPerHour > minBytesPerHour && f.r2 > minR2 && f.span >= minSpan && f.count >= minPoints && f.last - f.first >= minGrowth
    }
}

/// Turns 60-second polls of "who holds a sleep-preventing assertion" into start/end events.
public struct AssertionTracker: Sendable {
    private struct Held: Sendable { var name: String; var reason: String; var since: Date }
    private var held: [Int32: Held] = [:]

    public init() {}

    /// `holders`: pid -> (app name, assertion name).
    public mutating func update(_ holders: [Int32: (name: String, reason: String)], now: Date) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        for (pid, h) in holders.sorted(by: { $0.key < $1.key }) where held[pid] == nil {
            held[pid] = Held(name: h.name, reason: h.reason, since: now)
            out.append(HistoryEvent(timestamp: now, kind: .keptAwakeStarted, app: h.name, detail: h.reason))
        }
        for (pid, h) in held.sorted(by: { $0.key < $1.key }) where holders[pid] == nil {
            held[pid] = nil
            let d = now.timeIntervalSince(h.since)
            out.append(HistoryEvent(timestamp: now, kind: .keptAwakeEnded, app: h.name, detail: h.reason, value: d))
        }
        return out
    }

    /// Continues a spell recorded by an earlier run without reporting a new start.
    public mutating func adopt(pid: Int32, name: String, reason: String, since: Date) {
        held[pid] = Held(name: name, reason: reason, since: since)
    }

    /// Open spells, for "kept awake right now".
    public var active: [(app: String, since: Date)] { held.values.map { ($0.name, $0.since) }.sorted { $0.since < $1.since } }
}
