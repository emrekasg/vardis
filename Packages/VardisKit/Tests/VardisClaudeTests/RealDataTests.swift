import Foundation
import Testing
@testable import VardisClaude

/// Opt-in: `VARDIS_REAL_CLAUDE=1 swift test --filter RealData`. Indexes the real `~/.claude` into a temp DB and
/// prints counts and timings only, never content.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VARDIS_REAL_CLAUDE"] == "1"
                && FileManager.default.fileExists(atPath: ClaudeHome.defaultURL.appendingPathComponent("projects").path)))
struct RealDataTests {
    @Test func indexRealHome() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = ClaudeHome(url: ClaudeHome.defaultURL)
        let index = try ClaudeIndex(databaseURL: tmp.appendingPathComponent("index.sqlite"), homes: { [home] })

        let first = await index.refresh()
        print("[real] initial: files=\(first.filesSeen) changed=\(first.filesChanged) MB=\(first.bytesRead / 1_000_000) lines=\(first.linesParsed) malformed=\(first.malformedLines) seconds=\(String(format: "%.2f", first.duration))")

        var idle: [Double] = []
        for _ in 0..<5 { idle.append(await index.refresh().duration * 1000) }
        print("[real] no-change refresh ms: \(idle.map { String(format: "%.1f", $0) }.joined(separator: " "))")

        let sessions = try await index.sessions(limit: 100_000)
        print("[real] sessions=\(sessions.count) totalTokens=\(sessions.reduce(0) { $0 + $1.tokens.total }) costUSD=\(String(format: "%.2f", sessions.reduce(0) { $0 + $1.costUSD })) unpricedSessions=\(sessions.filter(\.hasUnpricedUsage).count)")

        for q in ["error", "test", "the", "swift build", "refactor"] {
            let t = Date()
            let hits = try await index.search(q, limit: 50)
            print("[real] search hits=\(hits.count) ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) queryLength=\(q.count)")
        }
        var t = Date()
        let days = try await index.usage(from: Date().addingTimeInterval(-30 * 86_400), to: Date(), bucket: .day)
        print("[real] usage 30d by day buckets=\(days.count) ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000))")
        t = Date()
        let hours = try await index.usage(from: Date().addingTimeInterval(-7 * 86_400), to: Date(), bucket: .hour)
        print("[real] usage 7d by hour buckets=\(hours.count) ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000))")
        t = Date()
        let models = try await index.usageByModel(from: .distantPast, to: .distantFuture)
        let projects = try await index.usageByProject(from: .distantPast, to: .distantFuture)
        print("[real] by model=\(models.count) by project=\(projects.count) ms=\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) unpricedModels=\(models.filter { !$0.isPriced }.count)")

        let live = LiveSessions.detect(homes: [home])
        print("[real] live=\(live.count) matched=\(live.filter { $0.sessionID != nil }.count)")
        let dbSize = ["index.sqlite", "index.sqlite-wal"].reduce(0) { sum, name in
            sum + ((try? FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
        }
        print("[real] dbMB=\(dbSize / 1_000_000)")
    }
}
