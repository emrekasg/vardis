import Foundation
@testable import VardisClaude

enum Fixtures {
    static let sessionID = "11111111-1111-4111-8111-111111111111"
    static let legacySessionID = "22222222-2222-4222-8222-222222222222"
    static let cwd = "/Users/test/my proj"
    static let slug = "-Users-test-my-proj"

    static var root: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    /// Copies the fixture home into a fresh temp dir so tests can append to it.
    static func makeHome() throws -> (home: ClaudeHome, tmp: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dst = tmp.appendingPathComponent(".claude-test", isDirectory: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("home"), to: dst)
        return (ClaudeHome(url: dst), tmp)
    }

    static func mainTranscript(_ home: ClaudeHome) -> URL {
        home.projectsURL.appendingPathComponent(slug).appendingPathComponent(sessionID + ".jsonl")
    }

    static func makeIndex(_ home: ClaudeHome, tmp: URL) throws -> ClaudeIndex {
        try ClaudeIndex(databaseURL: tmp.appendingPathComponent("index.sqlite"), homes: { [home] })
    }
}

func append(_ text: String, to url: URL) throws {
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data(text.utf8))
    try h.close()
}
