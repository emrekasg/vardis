import AppKit
import CoreServices
import Foundation
import Observation
import UserNotifications
import VardisClaude
import VardisCore

/// Preference keys the Claude screens add on top of `Pref` (auto-switch rules not in the shared list).
enum ClaudePref {
    static let skipAbove = "claude.autoSwitch.skipAbove"          // percent, default 80
    static let cooldownMinutes = "claude.autoSwitch.cooldown"     // minutes, default 10
    static let accountOrder = "claude.accountOrder"               // [home path]
    static let switchLog = "claude.switchLog"                     // JSON [SwitchEvent]

    static func register() {
        UserDefaults.standard.register(defaults: [skipAbove: 80, cooldownMinutes: 10])
    }
}

/// One Claude Code config dir shown as an account.
struct ClaudeAccount: Identifiable, Equatable, Sendable {
    var id: String { home.id }
    var home: ClaudeHome
    var name: String
    var plan: String?
    var isManaged: Bool
    var isSignedIn: Bool

    var source: String {
        isManaged ? "added in Vardis" : "found in \(ClaudeModel.tildePath(home.url.path))"
    }
}

struct QuotaState: Equatable, Sendable {
    var quota: PlanQuota?
    var problem: String?
    var checkedAt: Date
}

struct SwitchEvent: Codable, Equatable, Identifiable, Sendable {
    var id: Date { time }
    var time: Date
    var from: String
    var to: String
    var reason: String
}

/// A running Claude Code process with everything the Live screen shows about it.
struct LiveSessionInfo: Identifiable, Equatable, Sendable {
    var id: Int32 { process.pid }
    var process: LiveSession
    var session: ClaudeSession?
    var activity: LiveActivity
    var children: [ProcessNode]
    var ancestors: [Int32]

    var projectName: String { (process.cwd as NSString).lastPathComponent }
    var branch: String? { session?.gitBranch }
    var model: String? { activity.model ?? session?.model }

    enum Status: Equatable { case running(String), working, waiting, idle(TimeInterval) }

    func status(now: Date = Date()) -> Status {
        let age = activity.lastEventAt.map { now.timeIntervalSince($0) } ?? .infinity
        switch activity.phase {
        case .runningTool:
            if let t = activity.runningTool { return .running(t.name) }
            return .working
        case .thinking where age < 600: return .working
        case .waiting where age < 300: return .waiting
        default: return .idle(age.isFinite ? age : 0)
        }
    }
}

struct IndexProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// Owns the Claude Code index, live session detection, plan quota and accounts.
/// Every index call runs on the index actor or a detached task; results are assigned here on the main actor.
@MainActor
@Observable
final class ClaudeModel {
    // MARK: Last known data (never cleared while refreshing, so screens never wait)

    private(set) var sessions: [ClaudeSession] = []
    private(set) var monthDays: [UsageBucket] = []
    private(set) var monthHours: [UsageBucket] = []
    private(set) var monthProjects: [ProjectUsage] = []
    private(set) var monthModels: [ModelUsage] = []
    private(set) var monthHomes: [HomeUsage] = []
    private(set) var lastHourTokens = 0
    private(set) var indexing: IndexProgress?
    private(set) var hasLoaded = false
    private(set) var lastRefresh: RefreshStats?

    private(set) var live: [LiveSessionInfo] = []
    private(set) var accounts: [ClaudeAccount] = []
    private(set) var quotas: [String: QuotaState] = [:]
    private(set) var activeHomeID: String?
    private(set) var switchLog: [SwitchEvent] = []
    /// Whether new shells run `claude` through Vardis's shim (`~/.vardis/bin/claude`).
    private(set) var shellState: ShellState = .unknown
    let shellKind = ClaudeAccounts.userShell

    enum ShellState: Equatable {
        case unknown
        /// A new login shell resolves `claude` to the shim: switching works.
        case active
        /// The PATH line is in the startup file but a new login shell does not pick the shim (another PATH entry wins).
        case lineAddedNotFirst
        case notSetUp
        /// No real Claude Code binary to forward to.
        case claudeMissing
    }

    let supportsQuota = Edition.current.supports(.keychainDiscovery)
    let supportsSwitching = Edition.current.supports(.accountSwitching)

    // MARK: Plumbing

    @ObservationIgnored private(set) var index: ClaudeIndex?
    @ObservationIgnored private var presenters = Set<String>()
    @ObservationIgnored private var liveLoop: Task<Void, Never>?
    @ObservationIgnored private var quotaLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshRunning = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var watcher: TranscriptWatcher?
    @ObservationIgnored private let liveWorker = LiveWorker()
    @ObservationIgnored private let quotaWorker = QuotaWorker()
    @ObservationIgnored private var started = false

    var isPresenting: Bool { !presenters.isEmpty }

    func start() {
        guard !started else { return }
        started = true
        ClaudePref.register()
        switchLog = Self.loadSwitchLog()
        reloadAccounts()
        let url = AppPaths.support.appending(path: "claude.sqlite")
        let firstRun = !FileManager.default.fileExists(atPath: url.path)
        Task.detached(priority: .utility) { [weak self] in
            let homes: @Sendable () -> [ClaudeHome] = { ClaudeModel.indexedHomes() }
            guard let index = try? ClaudeIndex(databaseURL: url, homes: homes) else { return }
            await self?.attach(index, firstRun: firstRun)
        }
        quotaLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuotas()
                let fast = self?.isPresenting ?? false
                try? await Task.sleep(for: fast ? .seconds(60) : .seconds(300), tolerance: .seconds(5))
            }
        }
    }

    private func attach(_ index: ClaudeIndex, firstRun: Bool) async {
        self.index = index
        if !firstRun { await reload() }       // cached data first, so screens fill at once
        if firstRun { indexing = IndexProgress(done: 0, total: 0) }
        await refresh()
        startWatching()
    }

    /// Config dirs to index: discovered homes plus Vardis-managed ones (they may not have transcripts yet).
    nonisolated static func indexedHomes() -> [ClaudeHome] {
        let managed = ClaudeAccounts.managedHomes()
        var homes = ClaudeDiscovery.discover(extra: managed.map(\.url))
        return homes
    }

    // MARK: Presence

    /// A Claude screen or the Claude menu announces it is on screen. Live detection runs only while one is.
    func setPresenting(_ id: String, _ visible: Bool) {
        let was = isPresenting
        if visible { presenters.insert(id) } else { presenters.remove(id) }
        if isPresenting && !was {
            startLiveLoop()
            if needsReload { needsReload = false; Task { await reload() } }
            if pendingRefresh != nil { pendingRefresh?.cancel(); pendingRefresh = nil; Task { await refresh() } }
            // Quota is polled every 60 s while visible; catch up now if the last check is stale.
            if quotas.values.map(\.checkedAt).min().map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                Task { await refreshQuotas() }
            }
        } else if !isPresenting && was {
            liveLoop?.cancel()
            liveLoop = nil
        }
    }

    private func startLiveLoop() {
        liveLoop?.cancel()
        liveLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLive()
                try? await Task.sleep(for: .seconds(5), tolerance: .milliseconds(500))
            }
        }
    }

    // MARK: Index refresh

    /// Coalesces: a request while one runs schedules exactly one more.
    func refresh() async {
        guard let index else { return }
        if refreshRunning { refreshAgain = true; return }
        refreshRunning = true
        defer { refreshRunning = false }
        repeat {
            refreshAgain = false
            let showProgress = indexing != nil
            let stats = await Task.detached(priority: .utility) {
                await index.refresh { done, total in
                    guard showProgress else { return }
                    Task { @MainActor [weak self] in self?.indexing = IndexProgress(done: done, total: total) }
                }
            }.value
            lastRefresh = stats
            lastRefreshAt = Date()
            indexing = nil
            if stats.filesChanged > 0 || !hasLoaded {
                if isPresenting || !hasLoaded { await reload() } else { needsReload = true }
            }
        } while refreshAgain
    }

    /// Reads everything the screens show from the index (off-main), then assigns it here.
    func reload() async {
        guard let index else { return }
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        let monthEnd = cal.dateInterval(of: .month, for: now)?.end ?? now
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            do {
                return Loaded(
                    sessions: try await index.sessions(limit: 5_000),
                    days: try await index.usage(from: monthStart, to: monthEnd, bucket: .day),
                    hours: try await index.usage(from: monthStart, to: monthEnd, bucket: .hour),
                    projects: try await index.usageByProject(from: monthStart, to: monthEnd),
                    models: try await index.usageByModel(from: monthStart, to: monthEnd),
                    homes: try await index.usageByHome(from: monthStart, to: monthEnd),
                    lastHour: try await index.usage(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60), bucket: .hour)
                        .reduce(0) { $0 + $1.tokens.total })
            } catch { return nil }
        }.value
        guard let result else { return }
        sessions = result.sessions
        monthDays = result.days
        monthHours = result.hours
        monthProjects = result.projects
        monthModels = result.models
        monthHomes = result.homes
        lastHourTokens = result.lastHour
        hasLoaded = true
    }

    private struct Loaded: Sendable {
        var sessions: [ClaudeSession]
        var days: [UsageBucket]
        var hours: [UsageBucket]
        var projects: [ProjectUsage]
        var models: [ModelUsage]
        var homes: [HomeUsage]
        var lastHour: Int
    }

    private func startWatching() {
        let paths = Self.indexedHomes().map(\.projectsURL.path)
        watcher = TranscriptWatcher(paths: paths) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt = Date.distantPast
    @ObservationIgnored private var needsReload = false

    /// Transcripts change every second while Claude Code runs. Index at most every 2 s while a Claude
    /// screen is visible and once a minute otherwise; screens re-query only when someone is looking.
    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        let gap: TimeInterval = isPresenting ? 2 : 60
        let wait = max(0, gap - Date().timeIntervalSince(lastRefreshAt))
        let tolerance: Duration = isPresenting ? .milliseconds(200) : .seconds(10)
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: tolerance)
            guard let self else { return }
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    // MARK: Queries for screens (off-main)

    func search(_ text: String) async -> [SessionHit] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? await index.search(text, limit: 200)) ?? [] }.value
    }

    func turns(sessionID: String) async -> [Turn] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? await index.turns(sessionID: sessionID)) ?? [] }.value
    }

    func resumeCommand(for s: ClaudeSession) -> String {
        ClaudeIndex.resumeCommand(sessionID: s.id, cwd: s.projectPath, home: ClaudeHome(url: URL(fileURLWithPath: s.home, isDirectory: true)))
    }

    func session(id: String) -> ClaudeSession? { sessions.first { $0.id == id } }

    // MARK: Live

    func refreshLive() async {
        let homes = Self.indexedHomes()
        let index = self.index
        let worker = liveWorker
        let found = await Task.detached(priority: .utility) { await worker.detect(homes: homes, index: index) }.value
        if found != live { live = found }
        if let index {
            let now = Date()
            let tokens = await Task.detached(priority: .utility) {
                ((try? await index.usage(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60), bucket: .hour)) ?? []).reduce(0) { $0 + $1.tokens.total }
            }.value
            if tokens != lastHourTokens { lastHourTokens = tokens }
        }
    }

    /// Brings the terminal app that owns a session to the front (the nearest ancestor with a Dock icon).
    func focusTerminal(_ s: LiveSessionInfo) -> Bool {
        for pid in s.ancestors {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app.activate()
            }
        }
        return false
    }

    func terminalName(_ s: LiveSessionInfo) -> String? {
        for pid in s.ancestors {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app.localizedName }
        }
        return nil
    }

    // MARK: Accounts

    func reloadAccounts() {
        var seen = Set<String>()
        var list: [ClaudeAccount] = []
        let managed = ClaudeAccounts.managedHomes()
        let managedPaths = Set(managed.map(\.url.path))
        for home in Self.indexedHomes() + managed {
            let real = home.url.resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { continue }
            let isManaged = managedPaths.contains(home.url.path)
            list.append(ClaudeAccount(home: home, name: home.isDefault ? "Default" : home.label, plan: ClaudeAccounts.plan(for: home),
                                      isManaged: isManaged, isSignedIn: ClaudeAccounts.isSignedIn(home)))
        }
        let order = UserDefaults.standard.stringArray(forKey: ClaudePref.accountOrder) ?? []
        list.sort { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            if a.home.isDefault != b.home.isDefault { return a.home.isDefault }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if list != accounts { accounts = list }
        // The shim's state file names the active account; no file (or `default`) means the stock ~/.claude.
        let targetPath = supportsSwitching ? ClaudeAccounts.readActive()?.resolvingSymlinksInPath().path : nil
        activeHomeID = targetPath.flatMap { t in list.first { $0.home.url.resolvingSymlinksInPath().path == t }?.id }
            ?? list.first { $0.home.isDefault }?.id ?? list.first?.id
    }

    /// Installs or updates the shim and checks whether a new login shell finds it first. Runs off the main thread.
    func checkShell() async {
        guard supportsSwitching else { return }
        let kind = shellKind
        let state = await Task.detached(priority: .utility) { () -> ShellState in
            guard (try? ClaudeAccounts.installShim()) ?? nil != nil else { return .claudeMissing }
            if ClaudeAccounts.shimIsFirstOnPath(kind) { return .active }
            return ClaudeAccounts.startupFileHasLine(kind) ? .lineAddedNotFirst : .notSetUp
        }.value
        if state != shellState { shellState = state }
    }

    var activeAccount: ClaudeAccount? { accounts.first { $0.id == activeHomeID } }

    func move(_ account: ClaudeAccount, by delta: Int) {
        guard let i = accounts.firstIndex(of: account) else { return }
        let j = max(0, min(accounts.count - 1, i + delta))
        guard i != j else { return }
        var list = accounts
        list.swapAt(i, j)
        accounts = list
        UserDefaults.standard.set(list.map(\.id), forKey: ClaudePref.accountOrder)
    }

    /// Manual or automatic switch: rewrites `~/.vardis/active-account`, which the shim reads on every `claude` start.
    /// Running sessions keep their account.
    @discardableResult
    func makeActive(_ account: ClaudeAccount, reason: String) -> Bool {
        guard supportsSwitching else { return false }
        let from = activeAccount?.name ?? "–"
        do { try ClaudeAccounts.writeActive(account.home) } catch { return false }
        activeHomeID = account.id
        logSwitch(SwitchEvent(time: Date(), from: from, to: account.name, reason: reason))
        return true
    }

    /// Appends the PATH line to the shell's startup file. Only called after the person confirmed in the UI.
    func appendShellSetup() async {
        guard supportsSwitching else { return }
        try? ClaudeAccounts.appendPathLine(shellKind)
        await checkShell()
    }

    private func logSwitch(_ e: SwitchEvent) {
        switchLog.insert(e, at: 0)
        if switchLog.count > 50 { switchLog.removeLast(switchLog.count - 50) }
        if let data = try? JSONEncoder().encode(switchLog) { UserDefaults.standard.set(data, forKey: ClaudePref.switchLog) }
    }

    private static func loadSwitchLog() -> [SwitchEvent] {
        guard let data = UserDefaults.standard.data(forKey: ClaudePref.switchLog) else { return [] }
        return (try? JSONDecoder().decode([SwitchEvent].self, from: data)) ?? []
    }

    // MARK: Quota

    func refreshQuotas() async {
        reloadAccounts()
        // Snapshot runs (README images, visual checks) stay offline and never touch the Keychain.
        guard supportsQuota, !CommandLine.arguments.contains("--snapshot") else { return }
        let homes = accounts.filter(\.isSignedIn).map(\.home) + accounts.filter { !$0.isSignedIn && $0.home.isDefault }.map(\.home)
        let worker = quotaWorker
        let results = await Task.detached(priority: .utility) { await worker.fetch(homes) }.value
        var next = quotas
        for (id, state) in results {
            // Keep the last good numbers when a check fails, and say why next to them.
            if state.quota == nil, let old = next[id]?.quota {
                next[id] = QuotaState(quota: old, problem: state.problem, checkedAt: state.checkedAt)
            } else {
                next[id] = state
            }
        }
        if next != quotas { quotas = next }
        evaluateAutoSwitch()
    }

    func quota(_ account: ClaudeAccount?) -> PlanQuota? { account.flatMap { quotas[$0.id]?.quota } }

    // MARK: Auto-switch

    struct Rules {
        var enabled: Bool
        var fiveHour: Double
        var weekly: Double
        var skipAbove: Double
        var cooldown: TimeInterval

        static var current: Rules {
            let d = UserDefaults.standard
            return Rules(enabled: d.bool(forKey: Pref.autoSwitch), fiveHour: Double(d.integer(forKey: Pref.autoSwitchFiveHour)),
                         weekly: Double(d.integer(forKey: Pref.autoSwitchWeekly)), skipAbove: Double(d.integer(forKey: ClaudePref.skipAbove)),
                         cooldown: Double(d.integer(forKey: ClaudePref.cooldownMinutes)) * 60)
        }
    }

    /// The account new sessions would move to when the active one crosses its threshold.
    func nextAccount(rules: Rules = .current) -> ClaudeAccount? {
        guard let active = activeAccount, let i = accounts.firstIndex(of: active), accounts.count > 1 else { return nil }
        for k in 1..<accounts.count {
            let a = accounts[(i + k) % accounts.count]
            guard a.isSignedIn, let q = quota(a) else { continue }
            if (q.fiveHour?.utilization ?? 0) >= rules.skipAbove { continue }
            if (q.sevenDay?.utilization ?? 0) >= rules.weekly { continue }
            return a
        }
        return nil
    }

    /// Accounts the rules skip right now, with their 5-hour use.
    func skippedAccounts(rules: Rules = .current) -> [(ClaudeAccount, Double)] {
        accounts.compactMap { a in
            guard a.id != activeHomeID, let u = quota(a)?.fiveHour?.utilization, u >= rules.skipAbove else { return nil }
            return (a, u)
        }
    }

    private func evaluateAutoSwitch() {
        let rules = Rules.current
        guard supportsSwitching, rules.enabled, let active = activeAccount, let q = quota(active) else { return }
        if let last = switchLog.first, Date().timeIntervalSince(last.time) < rules.cooldown { return }
        let five = q.fiveHour?.utilization ?? 0, week = q.sevenDay?.utilization ?? 0
        let reason: String
        if five >= rules.fiveHour { reason = "\(active.name) reached \(Int(five))% of its 5-hour window" }
        else if week >= rules.weekly { reason = "\(active.name) reached \(Int(week))% of its weekly limit" }
        else { return }
        guard let next = nextAccount(rules: rules), makeActive(next, reason: reason) else { return }
        if UserDefaults.standard.bool(forKey: Pref.alertSwitched) { Self.notify(title: "New Claude Code sessions use \(next.name)", body: reason) }
    }

    private static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "claude.switch.\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
    }

    // MARK: Formatting helpers shared by the screens

    nonisolated static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        for h in [real, home] where path.hasPrefix(h) { return "~" + path.dropFirst(h.count) }
        return path
    }

    nonisolated static func projectName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "No project" }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Background workers

/// Keeps one transcript tail per running session so each 5 s pass reads only new bytes.
actor LiveWorker {
    private var tails: [String: LiveTail] = [:]

    func detect(homes: [ClaudeHome], index: ClaudeIndex?) async -> [LiveSessionInfo] {
        let found = LiveSessions.detect(homes: homes)
        let parents = ProcessTree.parents()
        var out: [LiveSessionInfo] = []
        var keep = Set<String>()
        for p in found {
            var activity = LiveActivity()
            if let url = p.transcriptURL {
                keep.insert(url.path)
                let tail = tails[url.path] ?? LiveTail(url: url)
                tails[url.path] = tail
                activity = tail.update()
            }
            let session = p.sessionID.flatMap { id in index.map { ($0, id) } }
            var s: ClaudeSession?
            if let (idx, id) = session { s = try? await idx.session(id: id) }
            out.append(LiveSessionInfo(process: p, session: s, activity: activity,
                                       children: ProcessTree.descendants(of: p.pid, parents: parents),
                                       ancestors: ProcessTree.ancestors(of: p.pid, parents: parents)))
        }
        tails = tails.filter { keep.contains($0.key) }
        return out.sorted { ($0.activity.lastEventAt ?? .distantPast) > ($1.activity.lastEventAt ?? .distantPast) }
    }
}

/// Reads access tokens (Keychain or credentials file) and asks Anthropic for plan limits. Tokens stay inside
/// this actor, are never logged, and are dropped when the API rejects them.
actor QuotaWorker {
    private var tokens: [String: String] = [:]
    private let client = QuotaClient()

    func fetch(_ homes: [ClaudeHome]) async -> [String: QuotaState] {
        var out: [String: QuotaState] = [:]
        for home in homes { out[home.id] = await fetch(home) }
        return out
    }

    private func fetch(_ home: ClaudeHome) async -> QuotaState {
        for attempt in 0..<2 {
            let cached = attempt == 0 ? tokens[home.id] : nil
            guard let token = cached ?? ClaudeCredentials.readAccessToken(home: home) else {
                tokens[home.id] = nil
                return QuotaState(quota: nil, problem: "Not signed in", checkedAt: Date())
            }
            tokens[home.id] = token
            do {
                return QuotaState(quota: try await client.fetch(accessToken: token), problem: nil, checkedAt: Date())
            } catch QuotaError.unauthorized {
                tokens[home.id] = nil
                if cached == nil { return QuotaState(quota: nil, problem: "Sign-in expired", checkedAt: Date()) }
            } catch QuotaError.http(let code) {
                return QuotaState(quota: nil, problem: code == 429 ? "Rate limited" : "Anthropic returned \(code)", checkedAt: Date())
            } catch {
                return QuotaState(quota: nil, problem: "Offline", checkedAt: Date())
            }
        }
        return QuotaState(quota: nil, problem: "Sign-in expired", checkedAt: Date())
    }
}

/// FSEvents on each home's `projects` folder, coalesced with a 1 s latency. No polling.
final class TranscriptWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.vardis.claude.fsevents", qos: .utility)

    init?(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
