import Testing
@testable import VardisSampling

struct AppGrouperTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let ancestors: [String]
        let expected: AppGrouper.Owner
        var testDescription: String { path }
    }

    static let cases: [Case] = [
        Case(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
             ancestors: [], expected: .bundle(path: "/Applications/Google Chrome.app")),
        Case(path: "/Applications/Xcode.app/Contents/MacOS/Xcode", ancestors: [], expected: .bundle(path: "/Applications/Xcode.app")),
        Case(path: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", ancestors: [], expected: .bundle(path: "/Applications/Xcode.app")),
        Case(path: "/usr/bin/git", ancestors: [], expected: .executable(name: "git", isSystem: true)),
        Case(path: "/opt/homebrew/bin/node",
             ancestors: ["/bin/zsh", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"],
             expected: .bundle(path: "/System/Applications/Utilities/Terminal.app")),
        Case(path: "/Users/me/bin/tool", ancestors: ["/sbin/launchd"], expected: .executable(name: "tool", isSystem: false)),
        Case(path: "/System/Library/CoreServices/Finder.app", ancestors: [], expected: .bundle(path: "/System/Library/CoreServices/Finder.app")),
    ]

    @Test(arguments: cases)
    func owner(_ c: Case) {
        #expect(AppGrouper.owner(executablePath: c.path, ancestorPaths: c.ancestors) == c.expected)
    }

    @Test func notFooledByAppPrefix() {
        #expect(AppGrouper.outermostAppBundle(in: "/Users/me/apple/bin/x") == nil)
        #expect(AppGrouper.outermostAppBundle(in: "/Users/me/my.apps/bin/x") == nil)
    }

    @Test func bundleIdentityReadsInfoPlist() {
        let identity = AppGrouper.bundleIdentity(path: "/System/Applications/Calculator.app")
        #expect(identity.id == "com.apple.calculator")
        #expect(identity.name == "Calculator")
    }

    @Test func bundleIdentityFallsBackToFileName() {
        let identity = AppGrouper.bundleIdentity(path: "/nonexistent/Some Tool.app")
        #expect(identity.id == "/nonexistent/Some Tool.app")
        #expect(identity.name == "Some Tool")
    }
}

@Test func namesCommandLineToolsByToolNotVersion() {
    #expect(AppGrouper.toolIdentity(name: "2.1.302", path: "/Users/x/.local/share/claude/versions/2.1.302") == ("cli.claude-code", "Claude Code CLI"))
    #expect(AppGrouper.toolIdentity(name: "1.4.0", path: "/Users/x/.local/share/foo/versions/1.4.0") == ("cli.foo", "foo"))
    #expect(AppGrouper.toolIdentity(name: "node", path: "/opt/homebrew/bin/node") == ("node", "node"))
}
