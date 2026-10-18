import Foundation
import Testing
@testable import VardisClaude

@Suite struct LiveAndAccountsTests {
    @Test func snippetMarksTermsCaseInsensitively() {
        let m = SessionHit.snippetMarkers
        let s = Snippet.make("Please check the Zebra crossing near the old\nbridge today", terms: ["zebra"])
        #expect(s.contains(m.open + "Zebra" + m.close))
        #expect(!s.contains("\n"))
        #expect(Snippet.make("streaming parser", terms: ["strea"]).contains(m.open + "streaming" + m.close))
    }

    @Test func contextWindowTable() {
        #expect(ContextWindow.size(model: "claude-opus-5-5") == 1_000_000)
        #expect(ContextWindow.size(model: "claude-haiku-4-5-20251001") == 200_000)
        #expect(ContextWindow.size(model: "claude-haiku-4-5", observed: 250_000) == 1_000_000)
        #expect(ContextWindow.size(model: "claude-sonnet-4-5[1m]") == 1_000_000)
        #expect(ContextWindow.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(ContextWindow.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ContextWindow.displayName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
    }

    @Test func liveTailFollowsToolsAndContext() throws {
        let (home, tmp) = try Fixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tail = LiveTail(url: Fixtures.mainTranscript(home))
        let a = tail.update()
        #expect(a.contextTokens > 0)
        #expect(a.model == "claude-sonnet-5-5")
        #expect(a.tools.contains { $0.name == "Read" && $0.state == .ok })
        #expect(a.tools.contains { $0.state == .failed })
        #expect(a.phase == .waiting)
        try append(#"{"type":"assistant","sessionId":"s","timestamp":"2026-10-01T12:00:00.000Z","message":{"id":"m9","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":300000},"content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"swift build\nmore"}}]}}"# + "\n", to: Fixtures.mainTranscript(home))
        let b = tail.update()
        #expect(b.phase == .runningTool)
        #expect(b.runningTool?.detail == "swift build")
        #expect(b.contextTokens == 300_005)
        #expect(b.contextWindow == 1_000_000)
    }

    @Test func activeAccountFileRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-active-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("active-account")
        #expect(ClaudeAccounts.readActive(file: file) == nil)                       // no file = default
        let work = tmp.appendingPathComponent("accounts/work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // A symlinked path is stored as the real path, so keychain naming follows the real dir.
        let alias = tmp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: work)
        try ClaudeAccounts.writeActive(ClaudeHome(url: alias), file: file)
        #expect(ClaudeAccounts.readActive(file: file)?.path == work.resolvingSymlinksInPath().path)
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("\n"))
        try ClaudeAccounts.writeActive(ClaudeHome(url: ClaudeHome.defaultURL), file: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "default\n")
        #expect(ClaudeAccounts.readActive(file: file) == nil)
        try "\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeAccounts.readActive(file: file) == nil)                       // empty = default
        try "relative/path\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeAccounts.readActive(file: file) == nil)                       // only absolute paths count
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
        #expect(ClaudeAccounts.isValidName("work-2"))
        #expect(!ClaudeAccounts.isValidName("../x"))
    }

    @Test func shimScriptContent() {
        let root = URL(fileURLWithPath: "/Users/someone/.vardis", isDirectory: true)
        let s = ClaudeAccounts.shimScript(root: root)
        #expect(s.hasPrefix("#!/bin/sh\n"))
        #expect(s.contains("vardis_root=/Users/someone/.vardis\n"))
        #expect(s.contains("vardis_bin=/Users/someone/.vardis/bin\n"))
        #expect(s.contains(#"<"$vardis_root/claude-real""#))
        #expect(s.contains(#"<"$vardis_root/active-account""#))
        #expect(s.contains(#"[ "$d" = "$vardis_bin" ] && continue"#))              // never resolves itself
        #expect(s.contains(#"""|default) unset CLAUDE_CONFIG_DIR"#))
        #expect(s.contains("export CLAUDE_CONFIG_DIR"))
        #expect(s.contains(#"exec "$real" "$@""#))
        #expect(!s.contains("$(") && !s.contains("`"))                               // no subprocesses
        // Only the not-found path writes to a stream, and it writes to stderr.
        let echoes = s.split(separator: "\n").filter { $0.contains("echo ") }
        #expect(echoes.count == 1 && echoes.allSatisfy { $0.hasSuffix(">&2") })
        // Paths with spaces or quotes are shell-quoted.
        let odd = ClaudeAccounts.shimScript(root: URL(fileURLWithPath: "/Users/o'k x/.vardis"))
        #expect(odd.contains(#"vardis_root='/Users/o'\''k x/.vardis'"#))
    }

    @Test func shimRunsWithStubClaude() throws {
        // Executes the generated shim against a stub, never the real Claude Code.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-shim-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent(".vardis", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let stub = tmp.appendingPathComponent("stub-claude")
        try "#!/bin/sh\nprintf '%s|%s\\n' \"${CLAUDE_CONFIG_DIR-unset}\" \"$*\"\nexit 7\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        let shim = root.appendingPathComponent("bin/claude")
        try ClaudeAccounts.shimScript(root: root).write(to: shim, atomically: true, encoding: .utf8)
        chmod(shim.path, 0o755)
        try (stub.path + "\n").write(to: root.appendingPathComponent("claude-real"), atomically: true, encoding: .utf8)
        func run() throws -> (String, String, Int32) {
            let p = Process()
            p.executableURL = shim
            p.arguments = ["--resume", "a b"]
            p.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/should/be/replaced"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run(); p.waitUntilExit()
            return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
        }
        var (out, err, code) = try run()
        #expect(out == "unset|--resume a b\n" && err.isEmpty && code == 7)          // no file: default, args and exit code forwarded
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try ClaudeAccounts.writeActive(ClaudeHome(url: work), file: root.appendingPathComponent("active-account"))
        (out, err, code) = try run()
        #expect(out == "\(work.path)|--resume a b\n" && err.isEmpty && code == 7)
        try FileManager.default.removeItem(at: root.appendingPathComponent("claude-real"))
        (out, err, code) = try run()                                                 // nothing on PATH: one stderr line, 127
        #expect(out.isEmpty && !err.isEmpty && code == 127)
    }
}
