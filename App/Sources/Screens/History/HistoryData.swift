import Foundation
import VardisCore
import VardisStore

// Values Today and Time Machine draw. Built off the main thread from HistoryStore, then handed
// to the screens whole. Every sentence comes from fixed templates filled with measured values.

struct AppRef: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct Standout: Sendable, Identifiable, Equatable {
    enum Tone: Sendable { case orange, red, blue, green, neutral }
    var id: String
    var symbol: String
    var tone: Tone
    var title: String
    var detail: String
    var badge: String?
}

struct TodayData: Sendable {
    static let bucket: TimeInterval = 300

    struct Bucket: Sendable {
        var total: Double
        /// CPU of each `top` app, same order.
        var apps: [Double]
        var topApp: String?
        var topAppCPU: Double
    }

    var dayStart: Date
    var now: Date
    var recordingSince: Date?
    /// Seconds of history recorded today.
    var recorded: TimeInterval
    /// Index i covers `dayStart + i * bucket`; nil where nothing was recorded.
    var buckets: [Bucket?]
    var top: [AppRef]
    var events: [HistoryEvent]
    var summary: String
    var note: String?
    var standouts: [Standout]

    var hasData: Bool { buckets.contains { $0 != nil } }

    static func build(store: HistoryStore, now: Date) async -> TodayData? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        guard let cpu = try? await store.series(.cpu, from: dayStart, to: now) else { return nil }
        let apps = (try? await store.appSeries(from: dayStart, to: now)) ?? []
        let events = (try? await store.events(from: dayStart, to: now)) ?? []
        let earliest = try? await store.earliest()
        let battery = (try? await store.series(.battery, from: dayStart, to: now)) ?? []

        // Width of each stored point, so averages and totals weigh coarse points correctly.
        var width: [Int64: Double] = [:]
        for (i, p) in cpu.enumerated() {
            let t = p.timestamp.timeIntervalSince1970
            let next = i + 1 < cpu.count ? cpu[i + 1].timestamp.timeIntervalSince1970 : t + (i > 0 ? t - cpu[i - 1].timestamp.timeIntervalSince1970 : 1)
            width[Int64(t)] = min(max(1, next - t), 60)
        }
        let recorded = width.values.reduce(0, +)

        // Whole-day ranking.
        var cpuSeconds: [String: Double] = [:], energy: [String: Double] = [:], written: [String: Double] = [:]
        var names: [String: String] = [:]
        var writtenByHour: [String: [Int: Double]] = [:]
        for a in apps {
            let w = width[Int64(a.timestamp.timeIntervalSince1970)] ?? 1
            cpuSeconds[a.appID, default: 0] += a.cpu * w
            energy[a.appID, default: 0] += a.energy * w
            written[a.appID, default: 0] += a.diskWrite * w
            writtenByHour[a.appID, default: [:]][cal.component(.hour, from: a.timestamp), default: 0] += a.diskWrite * w
            names[a.appID] = a.name
        }
        let top = cpuSeconds.sorted { $0.value > $1.value }.prefix(3).filter { $0.value > 0 }.map { AppRef(id: $0.key, name: names[$0.key] ?? $0.key) }
        let topIndex = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1.id, $0) })

        // Five-minute buckets.
        let n = Int(ceil(86_400 / bucket))
        var sumTotal = [Double](repeating: 0, count: n), sumW = [Double](repeating: 0, count: n)
        var sumApps = [[Double]](repeating: [Double](repeating: 0, count: top.count), count: n)
        var bucketApp: [Int: [String: Double]] = [:]
        for p in cpu {
            let i = Int(p.timestamp.timeIntervalSince(dayStart) / bucket)
            guard i >= 0, i < n else { continue }
            let w = width[Int64(p.timestamp.timeIntervalSince1970)] ?? 1
            sumTotal[i] += p.avg * w
            sumW[i] += w
        }
        for a in apps {
            let i = Int(a.timestamp.timeIntervalSince(dayStart) / bucket)
            guard i >= 0, i < n else { continue }
            let w = width[Int64(a.timestamp.timeIntervalSince1970)] ?? 1
            if let k = topIndex[a.appID] { sumApps[i][k] += a.cpu * w }
            bucketApp[i, default: [:]][a.name, default: 0] += a.cpu * w
        }
        let buckets: [Bucket?] = (0..<n).map { i in
            guard sumW[i] > 0 else { return nil }
            let total = sumTotal[i] / sumW[i]
            let parts = sumApps[i].map { min($0 / sumW[i], total) }
            let best = bucketApp[i]?.max { $0.value < $1.value }
            return Bucket(total: total, apps: parts, topApp: best?.key, topAppCPU: (best?.value ?? 0) / sumW[i])
        }

        let since = earliest.map { max($0, dayStart) } ?? cpu.first?.timestamp
        // Pressure flips between levels many times while memory is tight; count episodes, not flips.
        // A new episode starts after 10 quiet minutes.
        var pressureEvents: [HistoryEvent] = []
        var lastPressure = Date.distantPast
        for e in events where e.kind == .memoryPressure && e.detail != MemoryPressure.normal.rawValue {
            if e.timestamp.timeIntervalSince(lastPressure) >= 600 { pressureEvents.append(e) }
            lastPressure = e.timestamp
        }
        let onBattery = !battery.isEmpty
        let energyTop = energy.max { $0.value < $1.value }.flatMap { $0.value > 0 ? AppRef(id: $0.key, name: names[$0.key] ?? $0.key) : nil }

        let avg = recorded > 0 ? cpu.reduce(0) { $0 + $1.avg * (width[Int64($1.timestamp.timeIntervalSince1970)] ?? 1) } / recorded : 0
        let peak = cpu.map(\.max).max() ?? 0
        var summary = summarize(avg: avg, peak: peak, cpuApp: top.first?.name, energyApp: energyTop?.name, onBattery: onBattery, pressureCount: pressureEvents.count)
        var note: String?
        if recorded < 3_600 {
            let started = since.map { $0.formatted(date: .omitted, time: .shortened) } ?? now.formatted(date: .omitted, time: .shortened)
            note = "Vardis started recording at \(started). Today fills in as the day goes on."
            if !cpu.isEmpty, recorded < 600 { summary = note!; note = nil }
        }

        var standouts: [Standout] = []
        let energyTotal = energy.values.reduce(0, +)
        if let e = energyTop, energyTotal > 0 {
            let share = (energy[e.id] ?? 0) / energyTotal
            if share >= 0.15 {
                let avgW = (energy[e.id] ?? 0) / max(1, recorded)
                standouts.append(Standout(id: "energy", symbol: onBattery ? "battery.50percent" : "bolt", tone: .orange,
                                          title: "\(e.name) used \(Fmt.percent(share)) of the energy apps drew today",
                                          detail: "About \(Fmt.watts(avgW)) on average across the \(Fmt.duration(recorded)) Vardis recorded."))
            }
        }
        for g in events.filter({ $0.kind == .memoryGrowth }).reversed().uniqued(by: { $0.app ?? "" }).prefix(2) {
            standouts.append(Standout(id: "growth-\(g.app ?? "")", symbol: "exclamationmark.triangle", tone: .red,
                                      title: "\(g.app ?? "An app")'s memory keeps growing",
                                      detail: "\(g.detail). This can be a leak; restarting the app gives the memory back.", badge: "Watching"))
        }
        if let (id, bytes) = written.max(by: { $0.value < $1.value }), bytes >= 1e9 {
            let hour = writtenByHour[id]?.max { $0.value < $1.value }
            let share = (hour?.value ?? 0) / bytes
            let when = hour.map { h in share > 0.5 ? "Most of it between \(String(format: "%02d:00", h.key)) and \(String(format: "%02d:00", (h.key + 1) % 24))." : "Spread across the day." } ?? ""
            standouts.append(Standout(id: "disk", symbol: "internaldrive", tone: .blue, title: "\(names[id] ?? id) wrote \(Fmt.bytes(UInt64(bytes))) to disk", detail: when))
        }
        let awake = keptAwake(events, now: now)
        if let a = awake.first, a.total >= 600 {
            let span = "\(a.from.formatted(date: .omitted, time: .shortened)) to \(a.to.formatted(date: .omitted, time: .shortened))"
            standouts.append(Standout(id: "awake", symbol: "moon", tone: .orange, title: "\(a.app) kept the Mac awake for \(Fmt.duration(a.total))",
                                      detail: "It asked macOS not to sleep (\(a.reason)), longest from \(span)."))
        }
        let hogs = cpuHogs(events, now: now)
        if let h = hogs.first {
            standouts.append(Standout(id: "cpu", symbol: "cpu", tone: .blue, title: "\(h.app) ran above 80% CPU for \(Fmt.duration(h.total))",
                                      detail: "Longest stretch started at \(h.start.formatted(date: .omitted, time: .shortened))."))
        }
        if !pressureEvents.isEmpty {
            let first = pressureEvents[0].timestamp.formatted(date: .omitted, time: .shortened)
            let critical = pressureEvents.contains { $0.detail == MemoryPressure.critical.rawValue }
            standouts.append(Standout(id: "pressure", symbol: "memorychip", tone: critical ? .red : .orange,
                                      title: pressureEvents.count == 1 ? "Memory ran short once" : "Memory ran short \(pressureEvents.count) times",
                                      detail: "First at \(first). Time Machine shows which apps held the memory then."))
        }

        return TodayData(dayStart: dayStart, now: now, recordingSince: since, recorded: recorded, buckets: buckets, top: top,
                         events: events.filter { $0.kind != .cpuHogEnded && $0.kind != .keptAwakeEnded }, summary: summary, note: note, standouts: standouts)
    }

    static func summarize(avg: Double, peak: Double, cpuApp: String?, energyApp: String?, onBattery: Bool, pressureCount: Int) -> String {
        let opening = avg >= 0.35 ? "A busy day." : (peak >= 0.8 ? "A calm day with a few busy moments." : "A quiet day.")
        var s = opening
        if let cpuApp {
            if let energyApp, energyApp != cpuApp {
                s += " \(cpuApp) carried the CPU, \(energyApp) carried the \(onBattery ? "battery" : "energy")."
            } else {
                s += " \(cpuApp) did most of the work."
            }
        }
        if pressureCount > 0 { s += pressureCount == 1 ? " Memory ran short once." : " Memory ran short \(pressureCount) times." }
        return s
    }

    struct Spell { var app: String; var total: TimeInterval; var from: Date; var to: Date; var reason: String; var start: Date }

    /// Per app: total time spent holding a sleep assertion today (open spells count until now).
    static func keptAwake(_ events: [HistoryEvent], now: Date) -> [Spell] {
        var open: [String: HistoryEvent] = [:]
        var out: [String: Spell] = [:]
        func add(_ app: String, _ from: Date, _ to: Date, _ reason: String) {
            let d = to.timeIntervalSince(from)
            var s = out[app] ?? Spell(app: app, total: 0, from: from, to: to, reason: reason, start: from)
            if d > s.to.timeIntervalSince(s.from) { s.from = from; s.to = to; s.reason = reason }
            s.total += d
            out[app] = s
        }
        for e in events {
            guard let app = e.app else { continue }
            if e.kind == .keptAwakeStarted { open[app] = e }
            if e.kind == .keptAwakeEnded { add(app, open.removeValue(forKey: app)?.timestamp ?? e.timestamp.addingTimeInterval(-(e.value ?? 0)), e.timestamp, e.detail) }
        }
        for (app, e) in open { add(app, e.timestamp, now, e.detail) }
        return out.values.sorted { $0.total > $1.total }
    }

    static func cpuHogs(_ events: [HistoryEvent], now: Date) -> [Spell] {
        var open: [String: Date] = [:]
        var out: [String: Spell] = [:]
        func add(_ app: String, _ from: Date, _ to: Date) {
            var s = out[app] ?? Spell(app: app, total: 0, from: from, to: to, reason: "", start: from)
            if to.timeIntervalSince(from) > s.to.timeIntervalSince(s.from) { s.from = from; s.to = to; s.start = from }
            s.total += to.timeIntervalSince(from)
            out[app] = s
        }
        for e in events {
            guard let app = e.app else { continue }
            if e.kind == .cpuHog { open[app] = e.timestamp }
            if e.kind == .cpuHogEnded, let from = open.removeValue(forKey: app) { add(app, from, e.timestamp) }
        }
        for (app, from) in open { add(app, from, now) }
        return out.values.sorted { $0.total > $1.total }
    }
}

struct WeekStrip: Sendable {
    struct Hour: Sendable {
        var start: Date
        var cpuMax: Double?
        var pressureMax: Double?
    }

    var start: Date
    var end: Date
    var hours: [Hour]
    /// The most strained recorded moment, where the playhead starts.
    var suggested: Date?
    var recordedFrom: Date?

    static func build(store: HistoryStore, now: Date) async -> WeekStrip? {
        let hourSec: TimeInterval = 3_600
        let end = now
        let start = Date(timeIntervalSince1970: (now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 / hourSec).rounded(.up) * hourSec)
        guard let cpu = try? await store.series(.cpu, from: start, to: end) else { return nil }
        let pressure = (try? await store.series(.pressure, from: start, to: end)) ?? []
        let count = Int(ceil(end.timeIntervalSince(start) / hourSec))
        var hours = (0..<count).map { Hour(start: start.addingTimeInterval(Double($0) * hourSec)) }
        var best: (Date, Double)?
        var pressureAt: [Int64: Double] = [:]
        for p in pressure {
            pressureAt[Int64(p.timestamp.timeIntervalSince1970)] = p.max
            let i = Int(p.timestamp.timeIntervalSince(start) / hourSec)
            guard i >= 0, i < count else { continue }
            hours[i].pressureMax = max(hours[i].pressureMax ?? 0, p.max)
        }
        for p in cpu {
            let i = Int(p.timestamp.timeIntervalSince(start) / hourSec)
            guard i >= 0, i < count else { continue }
            hours[i].cpuMax = max(hours[i].cpuMax ?? 0, p.max)
            let score = p.max + 2 * (pressureAt[Int64(p.timestamp.timeIntervalSince1970)] ?? 0)
            if best == nil || score > best!.1 { best = (p.timestamp, score) }
        }
        return WeekStrip(start: start, end: end, hours: hours, suggested: best?.0, recordedFrom: cpu.first?.timestamp)
    }
}

struct MomentData: Sendable {
    enum Cause: Sendable { case memory, cpu, disk, nothing, noData }

    var at: Date
    var cause: Cause
    var headline: String
    var detail: String
    var apps: [AppPoint]
    var values: [Metric: Double]
    var events: [HistoryEvent]

    static func build(store: HistoryStore, at: Date) async -> MomentData {
        let values = (try? await store.moment(at: at)) ?? [:]
        let byCPU = (try? await store.topApps(at: at, limit: 8, by: .cpu)) ?? []
        let byMem = (try? await store.topApps(at: at, limit: 8, by: .memory)) ?? []
        let events = (try? await store.events(from: at.addingTimeInterval(-900), to: at.addingTimeInterval(900))) ?? []
        return make(at: at, values: values, byCPU: byCPU, byMemory: byMem, events: events)
    }

    /// The rules, in order: memory pressure or swap growth means memory; CPU above 80% means CPU;
    /// writes above 100 MB/s mean disk; otherwise nothing unusual.
    static func make(at: Date, values: [Metric: Double], byCPU: [AppPoint], byMemory: [AppPoint], events: [HistoryEvent]) -> MomentData {
        guard let cpu = values[.cpu] else {
            return MomentData(at: at, cause: .noData, headline: "Vardis has nothing recorded for this moment.",
                              detail: "The Mac may have been asleep, or Vardis was not running.", apps: [], values: values, events: events)
        }
        let pressure = values[.pressure] ?? 0
        let swap = values[.swap] ?? 0
        let swapGrew = events.contains { $0.kind == .swapGrew }
        let write = values[.diskWrite] ?? 0
        let memTop = byMemory.first
        let cpuTop = byCPU.first
        let diskTop = (byCPU + byMemory).max { $0.diskWrite < $1.diskWrite }

        if pressure >= 0.5 || swapGrew {
            let level = pressure >= 1 ? "critical" : (pressure >= 0.5 ? "at warning" : "normal")
            var d = "Memory pressure was \(level), \(Fmt.bytes(UInt64(swap))) of swap in use and \(Fmt.bytes(UInt64(values[.compressed] ?? 0))) compressed."
            if let m = memTop { d += " \(m.name) held the most, \(Fmt.bytes(m.memory))." }
            let head = cpu >= 0.8 ? "Your Mac slowed down because memory ran out, and the CPU was busy too."
                : "Your Mac slowed down because memory ran out, not because of the CPU."
            return MomentData(at: at, cause: .memory, headline: head, detail: d, apps: merge(byMemory, byCPU, by: \.memory), values: values, events: events)
        }
        if cpu >= 0.8 {
            let d = cpuTop.map { "\($0.name) used \(Fmt.percent($0.cpu)) of the whole Mac. Memory was fine." } ?? "Memory was fine."
            return MomentData(at: at, cause: .cpu, headline: "The CPU was the bottleneck: it ran at \(Fmt.percent(cpu)).", detail: d,
                              apps: merge(byCPU, byMemory, by: \.cpu), values: values, events: events)
        }
        if write >= 100_000_000 {
            let d = diskTop.flatMap { $0.diskWrite > 0 ? "\($0.name) was writing \(Fmt.rate($0.diskWrite))." : nil } ?? "No single app stood out."
            return MomentData(at: at, cause: .disk, headline: "The disk was busy writing \(Fmt.rate(write)).", detail: d,
                              apps: merge(byCPU, byMemory, by: \.cpu), values: values, events: events)
        }
        return MomentData(at: at, cause: .nothing, headline: "Nothing unusual at this moment.",
                          detail: "CPU at \(Fmt.percent(cpu)), memory pressure normal\(swap > 0 ? ", \(Fmt.bytes(UInt64(swap))) of swap in use" : "").",
                          apps: merge(byCPU, byMemory, by: \.cpu), values: values, events: events)
    }

    private static func merge<T: Comparable>(_ a: [AppPoint], _ b: [AppPoint], by key: KeyPath<AppPoint, T>) -> [AppPoint] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.appID).inserted }.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(8).map { $0 }
    }
}

extension Sequence {
    func uniqued<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }
}
