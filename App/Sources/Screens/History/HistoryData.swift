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
    var actions: [StandoutAction] = []
}

/// Inline buttons on a digest row.
enum StandoutAction: Sendable, Equatable, Hashable {
    /// Opens Time Machine at that moment.
    case showMoment(Date)
    /// Quits and reopens the app, after a confirmation.
    case restartApp(String)
    case reviewCleanup
}

/// Metrics Today's chart can show.
enum DayMetric: String, CaseIterable, Sendable, Identifiable {
    case cpu, memory, energy, disk, network
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        case .disk: "Disk"
        case .network: "Network"
        }
    }
}

/// System daemons that hold sleep assertions on the person's behalf (audio, Bluetooth, Handoff, ...).
/// Hidden from "kept awake" unless the person asks to see them.
enum SystemDaemons {
    static let names: Set<String> = [
        "bluetoothd", "coreaudiod", "sharingd", "powerd", "audiomxd", "mediaremoted", "WindowServer", "backupd", "useractivityd",
        "rapportd", "nsurlsessiond", "apsd", "cloudd", "mds", "mds_stores", "softwareupdated", "airportd", "locationd",
        "runningboardd", "AirPlayXPCHelper", "coreduetd", "symptomsd", "identityservicesd", "bird", "nehelper", "UserEventAgent",
        "kernel_task", "launchd", "loginwindow", "hidd", "corebrightnessd", "remoted", "callservicesd", "avconferenced",
        "mDNSResponder", "configd", "timed", "trustd", "deleted", "suggestd", "spindump", "ReportCrash", "screensharingd",
    ]

    static func isSystem(_ name: String?) -> Bool {
        guard let name else { return false }
        return names.contains(name) || name.hasPrefix("com.apple.")
    }
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
    /// Five-minute averages for the other chart metrics, same indexing as `buckets`.
    var metrics: [DayMetric: [Double?]] = [:]
    /// Present only with at least three earlier days of history.
    var comparison: [Comparison]?
    var foreground: [AppTime] = []
    var background: [BackgroundApp] = []
    var batterySessions: [BatterySession] = []
    var isToday = true

    struct Comparison: Sendable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var normal: String
        /// today / normal; nil when the normal is zero.
        var ratio: Double?
        var days: Int
    }

    struct AppTime: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var bundleID: String
        var seconds: TimeInterval
    }

    struct BackgroundApp: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var energyShare: Double
        var foreground: TimeInterval
    }

    struct BatterySession: Sendable, Identifiable {
        var id: Date { start }
        var start: Date
        var end: Date
        var ongoing: Bool
        /// Charge used, 0...1.
        var used: Double?
        var topApps: [String]
    }

    var hasData: Bool { buckets.contains { $0 != nil } }

    /// The day containing `day`, up to `now` for today. `openFocus` is the app frontmost right now (not yet stored).
    static func build(store: HistoryStore, day: Date, now: Date, openFocus: FocusSpan? = nil) async -> TodayData? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let isToday = now < dayEnd
        let end = min(now, dayEnd)
        guard end > dayStart else { return nil }
        let now = end
        guard let cpu = try? await store.series(.cpu, from: dayStart, to: now) else { return nil }
        let apps = (try? await store.appSeries(from: dayStart, to: now)) ?? []
        let events = (try? await store.events(from: dayStart, to: now)) ?? []
        let earliest = try? await store.earliest()
        let battery = (try? await store.series(.battery, from: dayStart, to: now)) ?? []
        let onBattery = (try? await store.series(.onBattery, from: dayStart, to: now)) ?? []
        let memory = (try? await store.series(.memoryUsed, from: dayStart, to: now)) ?? []
        let diskR = (try? await store.series(.diskRead, from: dayStart, to: now)) ?? []
        let diskW = (try? await store.series(.diskWrite, from: dayStart, to: now)) ?? []
        let netIn = (try? await store.series(.netIn, from: dayStart, to: now)) ?? []
        let netOut = (try? await store.series(.netOut, from: dayStart, to: now)) ?? []
        var focus = (try? await store.focus(from: dayStart, to: now)) ?? []
        if isToday, var open = openFocus, open.end > dayStart {
            open.start = max(open.start, dayStart)
            focus.append(open)
        }
        let offset = TimeZone.current.secondsFromGMT(for: dayStart)
        let past = (try? await store.dailyStats(from: dayStart.addingTimeInterval(-7 * 86_400), to: dayStart, utcOffset: offset)) ?? []

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
        let wasOnBattery = onBattery.contains { $0.max >= 0.5 } || (onBattery.isEmpty && !battery.isEmpty)
        let energyTop = energy.max { $0.value < $1.value }.flatMap { $0.value > 0 ? AppRef(id: $0.key, name: names[$0.key] ?? $0.key) : nil }

        let avg = recorded > 0 ? cpu.reduce(0) { $0 + $1.avg * (width[Int64($1.timestamp.timeIntervalSince1970)] ?? 1) } / recorded : 0
        let peak = cpu.map(\.max).max() ?? 0
        var summary = summarize(avg: avg, peak: peak, cpuApp: top.first?.name, energyApp: energyTop?.name, onBattery: wasOnBattery, pressureCount: pressureEvents.count)
        var note: String?
        if recorded < 3_600, isToday {
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
                standouts.append(Standout(id: "energy", symbol: wasOnBattery ? "battery.50percent" : "bolt", tone: .orange,
                                          title: "\(e.name) used \(Fmt.percent(share)) of the energy apps drew today",
                                          detail: "About \(Fmt.watts(avgW)) on average across the \(Fmt.duration(recorded)) Vardis recorded."))
            }
        }
        for g in events.filter({ $0.kind == .memoryGrowth }).reversed().uniqued(by: { $0.app ?? "" }).prefix(2) {
            standouts.append(Standout(id: "growth-\(g.app ?? "")", symbol: "exclamationmark.triangle", tone: .red,
                                      title: "\(g.app ?? "An app")'s memory keeps growing",
                                      detail: "\(g.detail). This can be a leak; restarting the app gives the memory back.", badge: "Watching",
                                      actions: [.restartApp(g.app ?? ""), .showMoment(g.timestamp)].filter { $0 != .restartApp("") }))
        }
        if let (id, bytes) = written.max(by: { $0.value < $1.value }), bytes >= 1e9 {
            let hour = writtenByHour[id]?.max { $0.value < $1.value }
            let share = (hour?.value ?? 0) / bytes
            let when = hour.map { h in share > 0.5 ? "Most of it between \(String(format: "%02d:00", h.key)) and \(String(format: "%02d:00", (h.key + 1) % 24))." : "Spread across the day." } ?? ""
            let at = hour.flatMap { cal.date(bySettingHour: $0.key, minute: 30, second: 0, of: dayStart) }
            standouts.append(Standout(id: "disk", symbol: "internaldrive", tone: .blue, title: "\(names[id] ?? id) wrote \(Fmt.bytes(UInt64(bytes))) to disk", detail: when,
                                      actions: at.map { [.showMoment($0)] } ?? []))
        }
        let awake = keptAwake(events, now: now).filter { !SystemDaemons.isSystem($0.app) }
        if let a = awake.first, a.total >= 600 {
            let span = "\(a.from.formatted(date: .omitted, time: .shortened)) to \(a.to.formatted(date: .omitted, time: .shortened))"
            standouts.append(Standout(id: "awake", symbol: "moon", tone: .orange, title: "\(a.app) kept the Mac awake for \(Fmt.duration(a.total))",
                                      detail: "It asked macOS not to sleep (\(a.reason)), longest from \(span).", actions: [.showMoment(a.from)]))
        }
        let hogs = cpuHogs(events, now: now)
        if let h = hogs.first {
            standouts.append(Standout(id: "cpu", symbol: "cpu", tone: .blue, title: "\(h.app) ran above 80% CPU for \(Fmt.duration(h.total))",
                                      detail: "Longest stretch started at \(h.start.formatted(date: .omitted, time: .shortened)).", actions: [.showMoment(h.start.addingTimeInterval(60))]))
        }
        if !pressureEvents.isEmpty {
            let first = pressureEvents[0].timestamp.formatted(date: .omitted, time: .shortened)
            let critical = pressureEvents.contains { $0.detail == MemoryPressure.critical.rawValue }
            standouts.append(Standout(id: "pressure", symbol: "memorychip", tone: critical ? .red : .orange,
                                      title: pressureEvents.count == 1 ? "Memory ran short once" : "Memory ran short \(pressureEvents.count) times",
                                      detail: "First at \(first). Time Machine shows which apps held the memory then.",
                                      actions: [.showMoment(pressureEvents[0].timestamp.addingTimeInterval(30))]))
        }

        // Other chart metrics, five-minute averages weighted by point width.
        var metrics: [DayMetric: [Double?]] = [:]
        metrics[.memory] = bucketize(memory, dayStart: dayStart, n: n)
        metrics[.disk] = add(bucketize(diskR, dayStart: dayStart, n: n), bucketize(diskW, dayStart: dayStart, n: n))
        metrics[.network] = add(bucketize(netIn, dayStart: dayStart, n: n), bucketize(netOut, dayStart: dayStart, n: n))
        var energySum = [Double](repeating: 0, count: n)
        for a in apps {
            let i = Int(a.timestamp.timeIntervalSince(dayStart) / bucket)
            guard i >= 0, i < n else { continue }
            energySum[i] += a.energy * (width[Int64(a.timestamp.timeIntervalSince1970)] ?? 1)
        }
        metrics[.energy] = (0..<n).map { i in sumW[i] > 0 ? energySum[i] / sumW[i] : nil }

        // Compared with a normal day: the earlier days with at least an hour recorded.
        var comparison: [Comparison]?
        let normalDays = past.filter { $0.recorded >= 3_600 }
        if normalDays.count >= 3, recorded >= 3_600 {
            let k = Double(normalDays.count)
            let nCPU = normalDays.reduce(0) { $0 + $1.cpu } / k
            let nMem = normalDays.reduce(0) { $0 + $1.memory } / k
            let nW = normalDays.reduce(0) { $0 + $1.averageWatts } / k
            let memRecorded = memory.isEmpty ? 0 : weightedAverage(memory)
            let todayW = energyTotal / max(1, recorded)
            func ratio(_ a: Double, _ b: Double) -> Double? { b > 0 ? a / b : nil }
            comparison = [
                Comparison(title: "CPU", value: Fmt.percent(avg), normal: Fmt.percent(nCPU), ratio: ratio(avg, nCPU), days: normalDays.count),
                Comparison(title: "Memory in use", value: Fmt.bytes(UInt64(max(0, memRecorded))), normal: Fmt.bytes(UInt64(max(0, nMem))), ratio: ratio(memRecorded, nMem), days: normalDays.count),
                Comparison(title: "App energy", value: Fmt.watts(todayW), normal: Fmt.watts(nW), ratio: ratio(todayW, nW), days: normalDays.count),
            ]
        }

        // What was actually used: frontmost time per app, and apps that drew energy mostly unseen.
        var fg: [String: (bundle: String, seconds: TimeInterval)] = [:]
        for f in focus where !f.name.isEmpty {
            let cur = fg[f.name] ?? (f.bundleID, 0)
            fg[f.name] = (cur.bundle, cur.seconds + max(0, f.duration))
        }
        let foreground = fg.map { AppTime(name: $0.key, bundleID: $0.value.bundle, seconds: $0.value.seconds) }
            .filter { $0.seconds >= 60 }.sorted { $0.seconds > $1.seconds }.prefix(6).map { $0 }
        var energyByName: [String: Double] = [:]
        for (id, e) in energy { energyByName[names[id] ?? id, default: 0] += e }
        let background = energyByName.filter { energyTotal > 0 && $0.value / energyTotal >= 0.05 && (fg[$0.key]?.seconds ?? 0) < 600 }
            .sorted { $0.value > $1.value }.prefix(4)
            .map { BackgroundApp(name: $0.key, energyShare: $0.value / energyTotal, foreground: fg[$0.key]?.seconds ?? 0) }

        let sessions = batterySessions(onBattery: onBattery, charge: battery, apps: apps, width: width, names: names, now: now, isToday: isToday)

        var data = TodayData(dayStart: dayStart, now: now, recordingSince: since, recorded: recorded, buckets: buckets, top: top,
                             events: events.filter { $0.kind != .cpuHogEnded && $0.kind != .keptAwakeEnded }, summary: summary, note: note, standouts: standouts)
        data.metrics = metrics
        data.comparison = comparison
        data.foreground = foreground
        data.background = Array(background)
        data.batterySessions = sessions
        data.isToday = isToday
        return data
    }

    /// Five-minute averages of `pts`, each point weighted by the gap to the next one (capped at 60 s).
    static func bucketize(_ pts: [Point], dayStart: Date, n: Int) -> [Double?] {
        var sum = [Double](repeating: 0, count: n), w = [Double](repeating: 0, count: n)
        for (i, p) in pts.enumerated() {
            let t = p.timestamp.timeIntervalSince1970
            let next = i + 1 < pts.count ? pts[i + 1].timestamp.timeIntervalSince1970 : t + 1
            let width = min(max(1, next - t), 60)
            let k = Int(p.timestamp.timeIntervalSince(dayStart) / bucket)
            guard k >= 0, k < n else { continue }
            sum[k] += p.avg * width
            w[k] += width
        }
        return (0..<n).map { w[$0] > 0 ? sum[$0] / w[$0] : nil }
    }

    static func add(_ a: [Double?], _ b: [Double?]) -> [Double?] {
        zip(a, b).map { x, y in x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
    }

    static func weightedAverage(_ pts: [Point]) -> Double {
        var s = 0.0, w = 0.0
        for (i, p) in pts.enumerated() {
            let t = p.timestamp.timeIntervalSince1970
            let next = i + 1 < pts.count ? pts[i + 1].timestamp.timeIntervalSince1970 : t + 1
            let width = min(max(1, next - t), 60)
            s += p.avg * width; w += width
        }
        return w > 0 ? s / w : 0
    }

    /// Unplugged stretches of at least five minutes; gaps under five minutes join two stretches.
    static func batterySessions(onBattery: [Point], charge: [Point], apps: [AppPoint], width: [Int64: Double], names: [String: String],
                                now: Date, isToday: Bool) -> [BatterySession] {
        var runs: [(Date, Date)] = []
        var cur: (Date, Date)?
        for p in onBattery {
            if p.avg >= 0.5 {
                if let c = cur, p.timestamp.timeIntervalSince(c.1) <= 300 { cur = (c.0, p.timestamp) } else {
                    if let c = cur { runs.append(c) }
                    cur = (p.timestamp, p.timestamp)
                }
            }
        }
        if let c = cur { runs.append(c) }
        return runs.filter { $0.1.timeIntervalSince($0.0) >= 300 }.map { start, end in
            let inRun = charge.filter { $0.timestamp >= start && $0.timestamp <= end }
            let used = (inRun.first?.avg).flatMap { a in inRun.last.map { max(0, a - $0.avg) } }
            var e: [String: Double] = [:]
            for a in apps where a.timestamp >= start && a.timestamp <= end {
                e[names[a.appID] ?? a.name, default: 0] += a.energy * (width[Int64(a.timestamp.timeIntervalSince1970)] ?? 1)
            }
            let top = e.sorted { $0.value > $1.value }.prefix(3).filter { $0.value > 0 }.map(\.key)
            return BatterySession(start: start, end: end, ongoing: isToday && now.timeIntervalSince(end) < 120, used: used, topApps: top)
        }
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
    /// `events` collapsed for display, with kept-awake durations.
    var rows: [MomentEvent] = []

    static func build(store: HistoryStore, at: Date, now: Date = Date()) async -> MomentData {
        let values = (try? await store.moment(at: at)) ?? [:]
        let byCPU = (try? await store.topApps(at: at, limit: 8, by: .cpu)) ?? []
        let byMem = (try? await store.topApps(at: at, limit: 8, by: .memory)) ?? []
        // Later ends tell how long a kept-awake spell lasted.
        let wide = (try? await store.events(from: at.addingTimeInterval(-900), to: min(now, at.addingTimeInterval(12 * 3_600)))) ?? []
        let events = wide.filter { $0.timestamp <= at.addingTimeInterval(900) }
        var m = make(at: at, values: values, byCPU: byCPU, byMemory: byMem, events: events)
        m.rows = MomentEvent.collapse(events, later: wide, now: now, horizon: at.addingTimeInterval(12 * 3_600))
        return m
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

/// One line of "What happened around it": repeats collapsed, kept-awake spells with their length.
struct MomentEvent: Sendable, Identifiable {
    var id: Int
    var event: HistoryEvent
    /// How many times it happened within two minutes of the previous one.
    var count: Int
    var duration: TimeInterval?
    var ongoing: Bool
    var isSystem: Bool

    /// Same kind and app (and pressure level) within 2 minutes of the previous occurrence collapse into one row.
    static func collapse(_ events: [HistoryEvent], later: [HistoryEvent], now: Date, horizon: Date) -> [MomentEvent] {
        var out: [MomentEvent] = []
        var lastIndex: [String: (row: Int, at: Date)] = [:]
        for e in events {
            let key = "\(e.kind.rawValue)|\(e.app ?? "")|\(e.kind == .memoryPressure ? e.detail : "")"
            if let prev = lastIndex[key], e.timestamp.timeIntervalSince(prev.at) <= 120 {
                out[prev.row].count += 1
                lastIndex[key] = (prev.row, e.timestamp)
                continue
            }
            var row = MomentEvent(id: out.count, event: e, count: 1, duration: nil, ongoing: false,
                                  isSystem: (e.kind == .keptAwakeStarted || e.kind == .keptAwakeEnded) && SystemDaemons.isSystem(e.app))
            switch e.kind {
            case .keptAwakeStarted:
                if let end = later.first(where: { $0.kind == .keptAwakeEnded && $0.app == e.app && $0.timestamp >= e.timestamp }) {
                    row.duration = end.timestamp.timeIntervalSince(e.timestamp)
                } else if horizon >= now {
                    row.duration = now.timeIntervalSince(e.timestamp)
                    row.ongoing = true
                }
            case .keptAwakeEnded, .cpuHogEnded:
                row.duration = e.value
            case .cpuHog:
                if let end = later.first(where: { $0.kind == .cpuHogEnded && $0.app == e.app && $0.timestamp >= e.timestamp }) {
                    row.duration = end.timestamp.timeIntervalSince(e.timestamp)
                }
            default: break
            }
            lastIndex[key] = (out.count, e.timestamp)
            out.append(row)
        }
        return out
    }
}
