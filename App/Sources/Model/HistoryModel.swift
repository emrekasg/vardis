import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications
import VardisCore
import VardisStore

/// History for Today and Time Machine. Every live tick is handed to `HistoryRecorder` through an
/// ordered stream and written off the main thread. Screens read prepared values only; queries run
/// in the background and replace what is shown when they finish, so a screen never waits.
@MainActor
@Observable
final class HistoryModel {
    private(set) var today: TodayData?
    private(set) var week: WeekStrip?
    private(set) var moment: MomentData?
    /// The moment Time Machine shows. Changing it starts a query; the old answer stays until the new one lands.
    private(set) var selected: Date?
    /// The day Today shows (start of day). Today unless the person picked another.
    private(set) var day: Date = Calendar.current.startOfDay(for: Date())
    /// Free bytes on the startup disk over the last 30 days, two-hour averages, for Disk Cleanup.
    private(set) var freeSpace: [Point] = []
    /// The app frontmost right now and since when; written to `app_focus` when it changes.
    @ObservationIgnored private var focus: FocusSpan?
    @ObservationIgnored private var followsToday = true

    static let summaryKey = "today.summaryNotification"
    static let summaryLastKey = "today.summaryLastDay"
    var summaryNotification: Bool = UserDefaults.standard.bool(forKey: HistoryModel.summaryKey) {
        didSet {
            UserDefaults.standard.set(summaryNotification, forKey: Self.summaryKey)
            if summaryNotification { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        }
    }

    @ObservationIgnored private var recorder: HistoryRecorder?
    /// Read access for screens that chart history (Now, Apps). The recorder owns the only connection.
    var queryStore: HistoryStore? { recorder?.store }
    @ObservationIgnored private var feed: AsyncStream<RecorderInput>.Continuation?
    @ObservationIgnored private var momentTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(live: LiveModel) {
        guard recorder == nil else { return }
        let retentionDays = max(1, UserDefaults.standard.integer(forKey: Pref.historyRetentionDays))
        guard let rec = try? HistoryRecorder(url: CleanupModel.supportURL("history.sqlite"), retention: TimeInterval(retentionDays) * 86_400) else { return }
        recorder = rec
        let (stream, cont) = AsyncStream<RecorderInput>.makeStream(bufferingPolicy: .bufferingNewest(600))
        feed = cont
        Task.detached(priority: .utility) {
            for await input in stream { await rec.handle(input) }
        }
        live.onEveryFullSample { [weak self] s in self?.feed?.yield(.snapshot(s)) }
        observeWorkspace()
        // Assertions are polled every 60 s off the main thread.
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let holders = PowerAssertions.holders()
                await MainActor.run { _ = self?.feed?.yield(.assertions(holders, Date())) }
                await self?.sendDailySummaryIfDue()
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
            }
        }
        // Prepare both screens shortly after launch so their first open shows data.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.refreshToday()
            await self?.refreshWeek()
        }
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        let app: @Sendable (Notification, HistoryEvent.Kind) -> HistoryEvent? = { n, kind in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.activationPolicy == .regular,
                  a.processIdentifier != getpid() else { return nil }
            return HistoryEvent(timestamp: Date(), kind: kind, app: a.localizedName ?? a.bundleIdentifier ?? "App", detail: a.bundleIdentifier ?? "")
        }
        let pairs: [(Notification.Name, @Sendable (Notification) -> HistoryEvent?)] = [
            (NSWorkspace.didLaunchApplicationNotification, { app($0, .appLaunched) }),
            (NSWorkspace.didTerminateApplicationNotification, { app($0, .appQuit) }),
            (NSWorkspace.willSleepNotification, { _ in HistoryEvent(timestamp: Date(), kind: .sleep, detail: "Mac went to sleep") }),
            (NSWorkspace.didWakeNotification, { _ in HistoryEvent(timestamp: Date(), kind: .wake, detail: "Mac woke up") }),
        ]
        for (name, make) in pairs {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let e = make(n) else { return }
                MainActor.assumeIsolated { _ = self?.feed?.yield(.event(e)) }
            })
        }
        observeFocus()
    }

    // MARK: Foreground time

    /// Frontmost-app changes become `app_focus` rows. Sleep and screen lock end the current stretch,
    /// so time away from the Mac is not counted as use. Notifications only; nothing is polled.
    private func observeFocus() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? "", name = app?.localizedName ?? ""
            MainActor.assumeIsolated { self?.focusChanged(bundleID: id, name: name) }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endFocus() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFocus() }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFocus() }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFocus() }
        })
        resumeFocus()
    }

    private func focusChanged(bundleID: String, name: String) {
        guard !name.isEmpty else { return }
        if let f = focus, f.bundleID == bundleID, f.name == name { return }
        endFocus()
        focus = FocusSpan(start: Date(), end: Date(), bundleID: bundleID, name: name)
    }

    private func endFocus() {
        guard var f = focus else { return }
        f.end = Date()
        focus = nil
        feed?.yield(.focus(f))
    }

    private func resumeFocus() {
        guard focus == nil, let app = NSWorkspace.shared.frontmostApplication else { return }
        focusChanged(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
    }

    /// The open stretch, up to now, for Today.
    private var openFocus: FocusSpan? {
        guard var f = focus else { return nil }
        f.end = Date()
        return f
    }

    // MARK: Queries

    func refreshToday() async {
        guard let store = recorder?.store else { return }
        let now = Date()
        // A new day started while the app ran: follow it, unless the person picked an earlier day.
        let todayStart = Calendar.current.startOfDay(for: now)
        if followsToday, day < todayStart { day = todayStart }
        let day = day, open = openFocus
        let built = await Task.detached(priority: .userInitiated) { await TodayData.build(store: store, day: day, now: now, openFocus: open) }.value
        if let built, built.dayStart == self.day { today = built }
    }

    /// Shows another day on Today. The current data stays on screen until the new day's lands.
    func showDay(_ d: Date) {
        let start = Calendar.current.startOfDay(for: min(d, Date()))
        followsToday = start == Calendar.current.startOfDay(for: Date())
        guard start != day else { return }
        day = start
        Task { await refreshToday() }
    }

    func refreshFreeSpace() async {
        guard let store = recorder?.store else { return }
        let now = Date()
        let pts = await Task.detached(priority: .utility) { () -> [Point] in
            let from = now.addingTimeInterval(-30 * 86_400)
            let rows = (try? await store.series(.diskFree, from: from, to: now)) ?? []
            // Two-hour averages: 360 points at most.
            var buckets: [Int64: (Double, Int)] = [:]
            for r in rows {
                let k = Int64(r.timestamp.timeIntervalSince1970) / 7_200
                let c = buckets[k] ?? (0, 0)
                buckets[k] = (c.0 + r.avg, c.1 + 1)
            }
            return buckets.sorted { $0.key < $1.key }.map { Point(timestamp: Date(timeIntervalSince1970: TimeInterval($0.key * 7_200)), avg: $0.value.0 / Double($0.value.1), max: 0) }
        }.value
        freeSpace = pts
    }

    /// Optional end-of-day note (off by default): after 21:00, once a day, the day's summary line.
    private func sendDailySummaryIfDue() async {
        guard summaryNotification, let store = recorder?.store else { return }
        let now = Date()
        let cal = Calendar.current
        guard cal.component(.hour, from: now) >= 21 else { return }
        let key = cal.startOfDay(for: now).formatted(.iso8601.year().month().day())
        guard UserDefaults.standard.string(forKey: Self.summaryLastKey) != key else { return }
        UserDefaults.standard.set(key, forKey: Self.summaryLastKey)
        let open = openFocus
        guard let t = await Task.detached(priority: .utility, operation: { await TodayData.build(store: store, day: now, now: now, openFocus: open) }).value,
              t.hasData else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your Mac today"
        content.body = ([t.summary] + t.standouts.prefix(2).map(\.title)).joined(separator: " ")
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "today.summary.\(key)", content: content, trigger: nil))
    }

    func refreshWeek() async {
        guard let store = recorder?.store else { return }
        let now = Date()
        guard let built = await Task.detached(priority: .userInitiated, operation: { await WeekStrip.build(store: store, now: now) }).value else { return }
        week = built
        if selected == nil || selected! < built.start { select(built.suggested ?? now) }
    }

    /// Moves the playhead. Queries for the new moment; a newer move cancels an older query.
    func select(_ t: Date) {
        let clamped = week.map { min(max(t, $0.start), $0.end) } ?? t
        selected = clamped
        momentTask?.cancel()
        momentTask = Task { [weak self] in
            guard let store = self?.recorder?.store else { return }
            let m = await Task.detached(priority: .userInitiated) { await MomentData.build(store: store, at: clamped, now: Date()) }.value
            guard !Task.isCancelled else { return }
            self?.moment = m
        }
    }
}

enum RecorderInput: Sendable {
    case snapshot(Snapshot)
    case event(HistoryEvent)
    case assertions([Int32: PowerAssertions.Holder], Date)
    case focus(FocusSpan)
}

/// Serial writer: appends snapshots, runs the detectors, compacts every 10 minutes and prunes
/// past the retention window. Owns the only HistoryStore connection.
actor HistoryRecorder {
    let store: HistoryStore
    private let retention: TimeInterval
    private var detector = SnapshotDetector()
    private var assertions = AssertionTracker()
    private var lastMaintenance = Date()
    private var reportedGrowth: [String: Date] = [:]

    init(url: URL, retention: TimeInterval) throws {
        store = try HistoryStore(url: url)
        self.retention = retention
    }

    private var seededPressure = false
    private var seededAssertions = false

    func handle(_ input: RecorderInput) async {
        switch input {
        case .snapshot(let s):
            if !seededPressure {
                seededPressure = true
                let recent = (try? await store.events(from: s.timestamp.addingTimeInterval(-86_400), to: s.timestamp)) ?? []
                if let last = recent.last(where: { $0.kind == .memoryPressure }), let p = MemoryPressure(rawValue: last.detail) {
                    detector.seed(pressure: p)
                } else {
                    detector.seed(pressure: .normal)
                }
            }
            try? await store.append(s)
            let events = detector.ingest(s)
            if !events.isEmpty { try? await store.append(events: events) }
            if s.timestamp.timeIntervalSince(lastMaintenance) >= 600 { await maintain(now: s.timestamp) }
        case .event(let e):
            try? await store.append(events: [e])
        case .focus(let f):
            try? await store.appendFocus([f])
        case .assertions(let holders, let now):
            var events: [HistoryEvent] = []
            if !seededAssertions {
                seededAssertions = true
                events += await adoptOpenSpells(holders, now: now)
            }
            events += assertions.update(holders.mapValues { ($0.name, $0.reason) }, now: now)
            if !events.isEmpty { try? await store.append(events: events) }
        }
    }

    /// Spells an earlier run left open: still held means continue it, gone means it ended
    /// while Vardis was not running, so it is closed at the last moment Vardis recorded.
    private func adoptOpenSpells(_ holders: [Int32: PowerAssertions.Holder], now: Date) async -> [HistoryEvent] {
        let recent = (try? await store.events(from: now.addingTimeInterval(-7 * 86_400), to: now)) ?? []
        var open: [String: HistoryEvent] = [:]
        for e in recent where e.app != nil {
            if e.kind == .keptAwakeStarted { open[e.app!] = e }
            if e.kind == .keptAwakeEnded { open[e.app!] = nil }
        }
        let lastSeen = (try? await store.series(.cpu, from: now.addingTimeInterval(-7 * 86_400), to: now.addingTimeInterval(-30)))?.last?.timestamp
        var out: [HistoryEvent] = []
        for (app, e) in open {
            if let (pid, h) = holders.first(where: { $0.value.name == app }) {
                assertions.adopt(pid: pid, name: h.name, reason: h.reason, since: e.timestamp)
            } else {
                let end = max(e.timestamp, lastSeen ?? e.timestamp)
                out.append(HistoryEvent(timestamp: end, kind: .keptAwakeEnded, app: app, detail: e.detail, value: end.timeIntervalSince(e.timestamp)))
            }
        }
        return out
    }

    private func maintain(now: Date) async {
        lastMaintenance = now
        try? await store.compact(now: now)
        try? await store.prune(retention: retention, now: now)
        await detectMemoryGrowth(now: now)
    }

    /// Per app, a straight line through the last 6 h of 1-minute memory points.
    private func detectMemoryGrowth(now: Date) async {
        guard let rows = try? await store.appSeries(from: now.addingTimeInterval(-6 * 3_600), to: now) else { return }
        var perApp: [String: (name: String, minutes: [Int64: (sum: Double, n: Int)])] = [:]
        for r in rows {
            let minute = Int64(r.timestamp.timeIntervalSince1970) / 60
            var entry = perApp[r.appID] ?? (r.name, [:])
            let cur = entry.minutes[minute] ?? (0, 0)
            entry.minutes[minute] = (cur.sum + Double(r.memory), cur.n + 1)
            perApp[r.appID] = entry
        }
        var events: [HistoryEvent] = []
        for (id, entry) in perApp {
            if let last = reportedGrowth[id], now.timeIntervalSince(last) < 6 * 3_600 { continue }
            let pts = entry.minutes.sorted { $0.key < $1.key }.map { (t: TimeInterval($0.key * 60), bytes: $0.value.sum / Double($0.value.n)) }
            guard let fit = MemoryTrend.fit(pts), MemoryTrend.isSteadyGrowth(fit) else { continue }
            reportedGrowth[id] = now
            events.append(HistoryEvent(timestamp: now, kind: .memoryGrowth, app: entry.name,
                                       detail: "\(Fmt.bytes(UInt64(max(0, fit.first)))) to \(Fmt.bytes(UInt64(max(0, fit.last)))) over \(Fmt.duration(fit.span)) without a restart",
                                       value: fit.bytesPerHour))
        }
        if !events.isEmpty { try? await store.append(events: events) }
    }
}

/// Who holds a power assertion that keeps the Mac from sleeping (`IOPMCopyAssertionsByProcess`).
enum PowerAssertions {
    struct Holder: Sendable { var name: String; var reason: String }

    static let sleepPreventing: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let ignored: Set<String> = ["powerd", "Vardis"]

    static func holders() -> [Int32: Holder] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let cf = dict?.takeRetainedValue() else { return [:] }
        guard let byPID = cf as NSDictionary as? [NSNumber: [[String: Any]]] else { return [:] }
        var out: [Int32: Holder] = [:]
        for (pidNum, list) in byPID {
            let pid = pidNum.int32Value
            guard pid != getpid(), let a = list.first(where: { sleepPreventing.contains($0["AssertType"] as? String ?? "") }) else { continue }
            let path = executablePath(pid: pid)
            // System daemons (audio, Bluetooth, Handoff) hold these on the person's behalf; they are not news.
            if let path, systemPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            let name = appName(pid: pid)
            guard !ignored.contains(name) else { continue }
            out[pid] = Holder(name: name, reason: a["AssertName"] as? String ?? "Keeping the Mac awake")
        }
        return out
    }

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]

    static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? string(buf) : nil
    }

    /// The outermost `.app` in the executable path, else the process name.
    static func appName(pid: Int32) -> String {
        if let path = executablePath(pid: pid) {
            if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
            return (path as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return string(name)
    }

    private static func string(_ c: [CChar]) -> String {
        String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
