import Foundation
import VardisCore
import VardisStore

/// A history series ready to chart: bucket starts and values, oldest first.
struct HistorySeries: Sendable, Equatable {
    var times: [Date] = []
    var values: [Double] = []
    var isEmpty: Bool { times.count < 2 }
}

/// One app's past, for the Apps inspector.
struct AppHistory: Sendable, Equatable {
    var times: [Date] = []
    var cpu: [Double] = []
    var memory: [Double] = []
}

/// Read-only queries for Now and Apps. Every query runs off the main thread on the store's actor,
/// and returns nil-free, chart-ready values; a missing store yields empty results, never an error.
extension HistoryModel {
    /// `metric` over the last `seconds`, averaged into at most `points` buckets.
    func series(_ metric: Metric, last seconds: TimeInterval, points: Int = 240) async -> HistorySeries {
        guard let store = queryStore else { return HistorySeries() }
        let now = Date()
        return await Task.detached(priority: .userInitiated) {
            let rows = (try? await store.series(metric, from: now.addingTimeInterval(-seconds), to: now)) ?? []
            return Self.bucket(rows.map { ($0.timestamp, $0.avg) }, from: now.addingTimeInterval(-seconds), to: now, points: points)
        }.value
    }

    /// One app's CPU and memory over the last `seconds`, in at most `points` buckets.
    /// History keeps only the top apps per point; buckets where the app was not ranked read as gaps (0).
    func appHistory(id: String, last seconds: TimeInterval, points: Int = 240) async -> AppHistory {
        guard let store = queryStore else { return AppHistory() }
        let now = Date()
        return await Task.detached(priority: .userInitiated) {
            let from = now.addingTimeInterval(-seconds)
            let rows = ((try? await store.appSeries(from: from, to: now)) ?? []).filter { $0.appID == id }
            let cpu = Self.bucket(rows.map { ($0.timestamp, $0.cpu) }, from: from, to: now, points: points)
            let mem = Self.bucket(rows.map { ($0.timestamp, Double($0.memory)) }, from: from, to: now, points: points)
            return AppHistory(times: cpu.times, cpu: cpu.values, memory: mem.values)
        }.value
    }

    /// Memory per app over the last hour, `points` buckets each, for table sparklines.
    func appMemoryLastHour(points: Int = 30) async -> [String: [Double]] {
        guard let store = queryStore else { return [:] }
        let now = Date()
        return await Task.detached(priority: .utility) {
            let from = now.addingTimeInterval(-3_600)
            let rows = (try? await store.appSeries(from: from, to: now)) ?? []
            var byApp: [String: [(Date, Double)]] = [:]
            for r in rows { byApp[r.appID, default: []].append((r.timestamp, Double(r.memory))) }
            return byApp.mapValues { Self.bucket($0, from: from, to: now, points: points).values }
        }.value
    }

    /// Events about one app (launches, quits, hangs, kept awake, memory growth, high CPU), newest first.
    /// Events name apps by display name; launch and quit also carry the bundle id in `detail`.
    func events(forApp name: String, id: String, last seconds: TimeInterval = 7 * 86_400, limit: Int = 60) async -> [HistoryEvent] {
        guard let store = queryStore else { return [] }
        let now = Date()
        return await Task.detached(priority: .userInitiated) {
            let all = (try? await store.events(from: now.addingTimeInterval(-seconds), to: now)) ?? []
            return Array(all.filter { $0.app == name || ($0.detail == id && ($0.kind == .appLaunched || $0.kind == .appQuit)) }.reversed().prefix(limit))
        }.value
    }

    /// Display names of apps the memory growth detector flagged in the last `seconds`.
    func growthFlaggedApps(last seconds: TimeInterval = 86_400) async -> Set<String> {
        guard let store = queryStore else { return [] }
        let now = Date()
        return await Task.detached(priority: .utility) {
            let all = (try? await store.events(from: now.addingTimeInterval(-seconds), to: now)) ?? []
            return Set(all.filter { $0.kind == .memoryGrowth }.compactMap(\.app))
        }.value
    }

    /// Averages (time, value) pairs into `points` equal buckets between `from` and `to`.
    /// Empty buckets carry the previous value when `fillForward` (idle sampling writes every 30 s), else read 0.
    nonisolated static func bucket(_ rows: [(Date, Double)], from: Date, to: Date, points: Int, fillForward: Bool = true) -> HistorySeries {
        guard !rows.isEmpty, points > 1, to > from else { return HistorySeries() }
        let span = to.timeIntervalSince(from)
        let width = span / Double(points)
        var sums = [Double](repeating: 0, count: points)
        var counts = [Int](repeating: 0, count: points)
        for (t, v) in rows {
            let i = Int(t.timeIntervalSince(from) / width)
            guard i >= 0 else { continue }
            let k = min(points - 1, i)
            sums[k] += v
            counts[k] += 1
        }
        // Start at the first bucket with data so a short history is not drawn as a long flat zero.
        guard let first = counts.firstIndex(where: { $0 > 0 }) else { return HistorySeries() }
        var times: [Date] = []
        var values: [Double] = []
        var last = 0.0
        for k in first..<points {
            if counts[k] > 0 { last = sums[k] / Double(counts[k]) } else if !fillForward { last = 0 }
            times.append(from.addingTimeInterval(Double(k) * width))
            values.append(last)
        }
        return HistorySeries(times: times, values: values)
    }
}
