import Foundation

public struct ClaudeSession: Sendable, Identifiable, Equatable {
    public var id: String
    /// `ClaudeHome.id` of the config dir the session was found in.
    public var home: String
    /// The `cwd` the session ran in.
    public var projectPath: String?
    public var gitBranch: String?
    /// `/rename` title, else Claude Code's generated title or summary, else the first prompt (80 chars).
    public var title: String
    public var startedAt: Date?
    public var lastActivityAt: Date?
    /// Prompts typed plus assistant messages, main conversation only.
    public var messageCount: Int
    public var toolCalls: Int
    public var failedToolCalls: Int
    /// Includes subagent usage.
    public var tokens: TokenUsage
    public var costUSD: Double
    /// Model with the most output tokens.
    public var model: String?
    /// Some usage came from a model the price table does not know; `costUSD` leaves it out.
    public var hasUnpricedUsage: Bool
}

public struct SessionHit: Sendable, Equatable {
    public var sessionID: String
    public var title: String
    public var projectPath: String?
    public var role: Role
    public var timestamp: Date?
    /// Matched terms wrapped in `snippetMarkers`.
    public var snippet: String
    public enum Role: String, Sendable { case user, assistant }
    public static let snippetMarkers = (open: "\u{2}", close: "\u{3}")
}

public struct UsageBucket: Sendable, Equatable {
    public enum Size: Sendable { case hour, day }
    public var start: Date
    public var tokens: TokenUsage
    public var costUSD: Double
}

public struct ProjectUsage: Sendable, Equatable {
    public var projectPath: String
    public var sessions: Int
    public var tokens: TokenUsage
    public var costUSD: Double
}

public struct HomeUsage: Sendable, Equatable {
    /// `ClaudeHome.id`.
    public var home: String
    public var sessions: Int
    public var tokens: TokenUsage
    public var costUSD: Double
}

public struct ModelUsage: Sendable, Equatable {
    public var model: String
    public var messages: Int
    public var tokens: TokenUsage
    public var costUSD: Double
    public var isPriced: Bool
}

/// One prompt and what the assistant did until the next prompt.
public struct Turn: Sendable, Equatable {
    public var index: Int
    public var timestamp: Date?
    public var prompt: String
    /// Assistant messages in the main conversation.
    public var steps: Int
    /// Distinct files touched by Edit/MultiEdit/Write/NotebookEdit.
    public var filesChanged: [String]
    public var failures: Int
    /// Last assistant text of the turn, first line, up to 200 characters.
    public var reply: String?

    /// "12 steps, 3 files changed, 1 failed".
    public var summary: String {
        var parts = ["\(steps) \(steps == 1 ? "step" : "steps")"]
        if !filesChanged.isEmpty { parts.append("\(filesChanged.count) \(filesChanged.count == 1 ? "file" : "files") changed") }
        if failures > 0 { parts.append("\(failures) failed") }
        return parts.joined(separator: ", ")
    }
}

public struct RefreshStats: Sendable, Equatable {
    public var filesSeen = 0
    public var filesChanged = 0
    public var bytesRead = 0
    public var linesParsed = 0
    public var malformedLines = 0
    public var sessionsTouched = 0
    public var duration: TimeInterval = 0
    public init() {}
}
