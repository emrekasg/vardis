import Foundation
import Testing
@testable import VardisClaude

@Suite struct ParserTests {
    @Test func streamedDuplicatesCountOnceWithMaxUsage() throws {
        let r = try TranscriptParser.parse(url: Fixtures.mainTranscript(ClaudeHome(url: Fixtures.root.appendingPathComponent("home"))))
        let msgs = TranscriptParser.dedupedAssistantMessages(r.events)
        #expect(msgs.map(\.messageID) == ["msg_A1", "msg_A2", "msg_A3", "msg_A4", "msg_A5"])
        let a1 = try #require(msgs.first)
        #expect(a1.usage == TokenUsage(input: 10, output: 50, cacheCreation: 100, cacheRead: 1000))
        #expect(a1.toolUses.map(\.name) == ["Read"])
        #expect(a1.text == "I will read the file first.")
        #expect(msgs[2].usage.cacheCreation1h == 500)
    }

    @Test func partialTrailingLineIsNotConsumed() throws {
        let line1 = #"{"type":"user","sessionId":"s","message":{"role":"user","content":"hello"}}"# + "\n"
        let partial = #"{"type":"assistant","sessionId":"s","message":{"id":"m1","#
        let data = Data((line1 + partial).utf8)
        let (events, consumed) = TranscriptParser.parse(data: data)
        #expect(events.count == 1)
        #expect(consumed == line1.utf8.count)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let r1 = try TranscriptParser.parse(url: url)
        #expect(r1.offset == UInt64(line1.utf8.count))
        try append(#""model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2}}}"# + "\n", to: url)
        let r2 = try TranscriptParser.parse(url: url, from: r1.offset)
        #expect(r2.events.count == 1)
        guard case .assistant(let a) = r2.events.first else { Issue.record("expected assistant"); return }
        #expect(a.usage.output == 2)
        #expect(r2.offset == UInt64(try Data(contentsOf: url).count))
    }

    @Test func sidechainLinesAreFlagged() throws {
        let url = Fixtures.root.appendingPathComponent("home/projects/\(Fixtures.slug)/\(Fixtures.sessionID)/subagents/agent-a1b2c3.jsonl")
        let r = try TranscriptParser.parse(url: url)
        #expect(r.events.count == 3)
        for e in r.events {
            switch e {
            case .user(let u): #expect(u.meta.isSidechain); #expect(!u.isPrompt)
            case .assistant(let a): #expect(a.meta.isSidechain); #expect(a.meta.sessionID == Fixtures.sessionID)
            case .title: Issue.record("unexpected title")
            }
        }
    }

    @Test func promptClassification() {
        let m = LineMeta()
        #expect(UserEntry(meta: m, isMeta: false, text: "fix the bug", toolResults: []).isPrompt)
        #expect(!UserEntry(meta: m, isMeta: false, text: "<command-name>/clear</command-name>", toolResults: []).isPrompt)
        #expect(!UserEntry(meta: m, isMeta: true, text: "fix", toolResults: []).isPrompt)
        #expect(!UserEntry(meta: m, isMeta: false, text: nil, toolResults: [ToolResult(toolUseID: "t", isError: false)]).isPrompt)
        #expect(UserEntry(meta: m, isMeta: false, text: "<3 this works", toolResults: []).isPrompt)
    }

    @Test func malformedLinesAreCountedNotFatal() {
        let data = Data("not json\n{\"type\":\"ai-title\",\"aiTitle\":\"T\",\"sessionId\":\"s\"}\n".utf8)
        let (events, consumed) = TranscriptParser.parse(data: data)
        #expect(events == [.title(TitleEntry(kind: .ai, text: "T", sessionID: "s"))])
        #expect(consumed == data.count)
    }

    @Test func timestamps() throws {
        let d = try #require(ISO8601.parse("2026-10-01T10:00:05.250Z"))
        #expect(abs(d.timeIntervalSince1970 - 1_790_848_805.25) < 0.0001)
        #expect(ISO8601.parse("2026-10-01T10:00:05Z")?.timeIntervalSince1970 == 1_790_848_805)
        #expect(ISO8601.parse("2026-10-01T12:00:05+02:00")?.timeIntervalSince1970 == 1_790_848_805)
    }

    @Test func slugMatchesClaudeCode() {
        #expect(ProjectSlug.slug(for: "/Users/test/my proj") == "-Users-test-my-proj")
        #expect(ProjectSlug.slug(for: "/Users/a/.config/x_y") == "-Users-a--config-x-y")
    }
}
