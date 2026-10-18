import Foundation
import Testing
@testable import VardisClaude

@Suite struct IndexTests {
    @Test func indexesSessionTotalsToolsAndTitle() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        let stats = await index.refresh()
        #expect(stats.filesSeen == 3)
        #expect(stats.filesChanged == 3)

        let s = try #require(try await index.session(id: Fixtures.sessionID))
        #expect(s.title == "Streaming parser refactor")
        #expect(s.projectPath == Fixtures.cwd)
        #expect(s.gitBranch == "main")
        #expect(s.toolCalls == 3)          // Read, Edit, Write; the subagent's Bash is not a main-chain call
        #expect(s.failedToolCalls == 1)
        #expect(s.messageCount == 2 + 5)   // 2 typed prompts + 5 distinct assistant messages
        // Main chain + subagent, each message once.
        let expected = TokenUsage(input: 10 + 2 + 2 + 1 + 3 + 100, output: 50 + 30 + 40 + 20 + 7 + 220,
                                  cacheCreation: 100 + 500, cacheRead: 1000 + 2000 + 2000 + 3000 + 100)
        #expect(s.tokens == expected)
        #expect(s.model == "claude-haiku-4-5-20251001" || s.model == "claude-opus-5-5")
        #expect(!s.hasUnpricedUsage)

        let p = Pricing.bundled
        let want = p.cost(TokenUsage(input: 10, output: 50, cacheCreation: 100, cacheRead: 1000), model: "claude-opus-5-5").usd
            + p.cost(TokenUsage(input: 2, output: 30, cacheRead: 2000), model: "claude-opus-5-5").usd
            + p.cost(TokenUsage(input: 2, output: 40, cacheCreation: 500, cacheRead: 2000, cacheCreation1h: 500), model: "claude-opus-5-5").usd
            + p.cost(TokenUsage(input: 1, output: 20, cacheRead: 3000), model: "claude-opus-5-5").usd
            + p.cost(TokenUsage(input: 3, output: 7, cacheRead: 100), model: "claude-sonnet-5-5").usd
            + p.cost(TokenUsage(input: 100, output: 220), model: "claude-haiku-4-5").usd
        #expect(abs(s.costUSD - want) < 1e-12)

        let legacy = try #require(try await index.session(id: Fixtures.legacySessionID))
        #expect(legacy.title == "Legacy summary title")
    }

    @Test func titleFallsBackToTruncatedFirstPrompt() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Drop the ai-title line.
        let url = Fixtures.mainTranscript(home)
        let text = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.contains("\"ai-title\"") }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let s = try #require(try await index.session(id: Fixtures.sessionID))
        #expect(s.title.count == 80)
        #expect(s.title.hasPrefix("Refactor the parser module"))
        #expect(s.title.hasSuffix("\u{2026}"))
    }

    @Test func turnsSummariseSteps() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let turns = try await index.turns(sessionID: Fixtures.sessionID)
        #expect(turns.count == 2)
        #expect(turns[0].steps == 4)
        #expect(turns[0].filesChanged == [Fixtures.cwd + "/Sources/Parser.swift", Fixtures.cwd + "/Sources/Stream.swift"])
        #expect(turns[0].failures == 1)
        #expect(turns[0].reply == "Done: the parser now streams chunks.")
        #expect(turns[0].summary == "4 steps, 2 files changed, 1 failed")
        #expect(turns[1].prompt == "Add tests for the zebra edge case")
        #expect(turns[1].summary == "1 step")
    }

    @Test func incrementalRefreshResumesFromOffset() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let before = try #require(try await index.session(id: Fixtures.sessionID))

        let idle = await index.refresh()
        #expect(idle.filesChanged == 0)
        #expect(idle.bytesRead == 0)

        let url = Fixtures.mainTranscript(home)
        // A streamed copy of an existing message (must not double count) split across two writes, plus a new one.
        let dup = #"{"type":"assistant","sessionId":"\#(Fixtures.sessionID)","isSidechain":false,"requestId":"req_5","timestamp":"2026-10-01T11:00:00.000Z","message":{"id":"msg_A5","model":"claude-sonnet-5-5","content":[{"type":"text","text":"more"}],"usage":{"input_tokens":3,"output_tokens":9,"cache_creation_input_tokens":0,"cache_read_input_tokens":100}}}"#
        let half = dup.utf8.count / 2
        try append(String(dup.prefix(half)), to: url)
        let mid = await index.refresh()
        #expect(mid.filesChanged == 1)
        #expect(mid.linesParsed == 0)
        try append(String(dup.dropFirst(half)) + "\n", to: url)
        let after = await index.refresh()
        #expect(after.linesParsed == 1)
        let s = try #require(try await index.session(id: Fixtures.sessionID))
        #expect(s.tokens.output == before.tokens.output + 2)   // 7 -> 9 for msg_A5
        #expect(s.messageCount == before.messageCount)
        #expect(s.lastActivityAt == ISO8601.parse("2026-10-01T11:00:00.000Z"))

        // A second index over the same DB file continues from the stored offsets.
        let reopened = try Fixtures.makeIndex(home, tmp: tmp)
        let again = await reopened.refresh()
        #expect(again.filesChanged == 0)
    }

    @Test func searchFindsTextWithSnippetAndSkipsToolOutput() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let hits = try await index.search("zebra")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.sessionID == Fixtures.sessionID)
        #expect(hit.title == "Streaming parser refactor")
        let m = SessionHit.snippetMarkers
        #expect(hit.snippet.contains(m.open + "zebra" + m.close))
        #expect(try await index.search("strea").first?.sessionID == Fixtures.sessionID)   // prefix match on last word
        #expect(try await index.search("aardvark").isEmpty)                                 // tool output is not indexed
        #expect(try await index.search("narwhal").isEmpty)                                  // subagent text is not indexed
        #expect(try await index.search("\"  ").isEmpty)
    }

    @Test func usageQueries() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let from = Date(timeIntervalSince1970: 1_790_800_000), to = Date(timeIntervalSince1970: 1_790_900_000)
        let days = try await index.usage(from: from, to: to, bucket: .day)
        let hours = try await index.usage(from: from, to: to, bucket: .hour)
        let session = try #require(try await index.session(id: Fixtures.sessionID))
        #expect(days.reduce(TokenUsage.zero) { $0 + $1.tokens }.total == session.tokens.total)
        #expect(abs(hours.reduce(0) { $0 + $1.costUSD } - session.costUSD) < 1e-12)
        let models = try await index.usageByModel(from: from, to: to)
        #expect(Set(models.map(\.model)) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"])
        #expect(models.first { $0.model == "claude-opus-5-5" }?.messages == 4)
        let projects = try await index.usageByProject(from: from, to: to)
        #expect(projects.map(\.projectPath) == [Fixtures.cwd])
        let listed = try await index.sessions(limit: 10, offset: 0, projectFilter: Fixtures.cwd)
        #expect(listed.count == 2)
        #expect(try await index.sessions(limit: 10, offset: 0, projectFilter: "/nope").isEmpty)
    }

    @Test func resumeCommandEscaping() async throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = try Fixtures.makeIndex(home, tmp: tmp)
        await index.refresh()
        let cmd = try #require(try await index.resumeCommand(sessionID: Fixtures.sessionID))
        #expect(cmd == "cd '/Users/test/my proj' && CLAUDE_CONFIG_DIR=\(Shell.quote(home.url.path)) claude --resume \(Fixtures.sessionID)")
        #expect(ClaudeIndex.resumeCommand(sessionID: "abc", cwd: "/tmp/it's here", home: ClaudeHome(url: ClaudeHome.defaultURL))
                == #"cd '/tmp/it'\''s here' && claude --resume abc"#)
        #expect(ClaudeIndex.resumeCommand(sessionID: "abc", cwd: "/plain/path") == "cd /plain/path && claude --resume abc")
        #expect(Shell.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func discoveryFindsHomesWithProjects() throws {
        let (_, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".claude-empty"), withIntermediateDirectories: true)
        let extra = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: extra.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let homes = ClaudeDiscovery.discover(extra: [extra, extra], environment: [:], homeDirectory: tmp)
        #expect(homes.map(\.label) == ["test", "elsewhere"])
    }
}
