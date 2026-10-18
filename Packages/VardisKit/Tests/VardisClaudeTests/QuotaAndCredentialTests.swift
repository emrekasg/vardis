import Foundation
import Testing
@testable import VardisClaude

/// Serves canned responses; records the last request. Never touches the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct QuotaTests {
    func stubbedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test func parsesWindowsAndToleratesExtras() async throws {
        StubProtocol.status = 200
        StubProtocol.body = try Data(contentsOf: Fixtures.root.appendingPathComponent("quota.json"))
        let q = try await QuotaClient(session: stubbedSession(), url: URL(string: "https://stub.invalid/api/oauth/usage")!).fetch(accessToken: "test-token")
        #expect(q.fiveHour?.utilization == 42.5)
        #expect(q.fiveHour?.resetsAt == QuotaClient.date("2026-10-18T15:00:00.123Z"))
        #expect(q.sevenDay?.utilization == 7)
        #expect(q.sevenDay?.resetsAt == QuotaClient.date("2026-10-22T09:00:00Z"))
        #expect(q.sevenDayOpus == nil)
        #expect(q.sevenDaySonnet == QuotaWindow(utilization: 0, resetsAt: nil))
        #expect(q.other.keys.sorted() == ["seven_day_oauth_apps"])

        let req = try #require(StubProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func mapsHTTPErrors() async throws {
        StubProtocol.body = Data("{}".utf8)
        StubProtocol.status = 401
        await #expect(throws: QuotaError.unauthorized) {
            try await QuotaClient(session: stubbedSession()).fetch(accessToken: "x")
        }
        StubProtocol.status = 500
        await #expect(throws: QuotaError.http(500)) {
            try await QuotaClient(session: stubbedSession()).fetch(accessToken: "x")
        }
        #expect(throws: QuotaError.invalidResponse) { try QuotaClient.parse(Data("[1]".utf8)) }
    }
}

@Suite struct CredentialTests {
    @Test func readsAccessTokenOnly() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let json = #"{"claudeAiOauth":{"accessToken":"at-synthetic","refreshToken":"rt-synthetic","expiresAt":2000000}}"#
        #expect(ClaudeCredentials.accessToken(fromJSON: Data(json.utf8), now: now) == "at-synthetic")
        let expired = #"{"claudeAiOauth":{"accessToken":"at-synthetic","expiresAt":500000}}"#
        #expect(ClaudeCredentials.accessToken(fromJSON: Data(expired.utf8), now: now) == nil)
        #expect(ClaudeCredentials.accessToken(fromJSON: Data("{}".utf8), now: now) == nil)
    }

    @Test func fileFallbackForCustomHome() throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(#"{"claudeAiOauth":{"accessToken":"at-file","expiresAt":99999999999999}}"#.utf8)
            .write(to: home.url.appendingPathComponent(".credentials.json"))
        #expect(ClaudeCredentials.readAccessToken(home: home) == "at-file")
    }

    @Test func keychainServiceNames() {
        #expect(ClaudeCredentials.keychainService(for: ClaudeHome(url: ClaudeHome.defaultURL)) == "Claude Code-credentials")
        let custom = ClaudeCredentials.keychainService(for: ClaudeHome(url: URL(fileURLWithPath: "/tmp/x")))
        #expect(custom.hasPrefix("Claude Code-credentials-"))
        #expect(custom.count == "Claude Code-credentials-".count + 8)
    }
}

@Suite struct LiveSessionTests {
    @Test func classifiesProcesses() {
        #expect(LiveSessions.isClaudeCode(path: "/u/.local/share/claude/versions/2.1.0", args: ["claude"]))
        #expect(LiveSessions.isClaudeCode(path: "/u/.local/bin/claude", args: ["claude", "--resume"]))
        #expect(!LiveSessions.isClaudeCode(path: "/u/.local/bin/claude", args: ["claude", "bg-pty-host"]))
        #expect(!LiveSessions.isClaudeCode(path: "/u/.local/bin/claude", args: ["claude bg-spare"]))
        #expect(!LiveSessions.isClaudeCode(path: "/u/.local/share/claude/versions/2.1.0", args: ["ugrep", "-n", "x"]))
        #expect(LiveSessions.isClaudeCode(path: "/u/.local/share/claude/versions/2.1.0", args: ["2.1.0", "--print"]))
        #expect(!LiveSessions.isClaudeCode(path: "/Applications/Claude.app/Contents/MacOS/Claude", args: ["Claude"]))
        #expect(LiveSessions.isClaudeCode(path: "/opt/homebrew/bin/node", args: ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"]))
        #expect(!LiveSessions.isClaudeCode(path: "/opt/homebrew/bin/node", args: ["node", "server.js"]))
        #expect(LiveSessions.explicitSessionID(["claude", "--resume", Fixtures.sessionID]) == Fixtures.sessionID)
    }

    @Test func matchesNewestTranscriptInProjectFolder() throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let main = Fixtures.mainTranscript(home)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: main.path)
        let s = LiveSession(pid: 1, startedAt: Date(), cwd: Fixtures.cwd, executablePath: "/x/claude")
        let m = LiveSessions.match([s], homes: [home])
        #expect(m.first?.sessionID == Fixtures.sessionID)
        #expect(m.first?.home == home)
    }

    @Test func detectDoesNotCrash() {
        _ = LiveSessions.detect(homes: [])
    }
}
