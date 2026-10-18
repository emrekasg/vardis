import Foundation

/// Context window sizes. The one place that decides what "context %" is measured against.
public enum ContextWindow {
    public static let standard = 200_000
    public static let extended = 1_000_000

    /// Model ids Claude Code runs with the 1M window by default (observed: Opus 5.5 sessions above 900k tokens).
    static let extendedModels: [String] = ["claude-opus-5-5", "claude-sonnet-5-5"]

    /// - Parameter observed: largest prompt seen in the session; anything above 200k proves the 1M window.
    public static func size(model: String?, observed: Int = 0) -> Int {
        if observed > standard { return extended }
        guard let m = model?.lowercased() else { return standard }
        if m.contains("[1m]") || m.hasSuffix("-1m") { return extended }
        if extendedModels.contains(where: { m.hasPrefix($0) }) { return extended }
        return standard
    }

    /// "Opus 5.5" from "claude-opus-5-5-20261001".
    public static func displayName(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "–" }
        let m = model.lowercased().replacingOccurrences(of: "claude-", with: "")
        let parts = m.split(separator: "-").map(String.init)
        guard let fi = parts.firstIndex(where: { Int($0) == nil }) else { return model }
        let family = parts[fi]
        // Older ids put the version first (claude-3-7-sonnet); newer ones after (claude-opus-5-5).
        let version = fi > 0 ? Array(parts[..<fi]) : Array(parts[(fi + 1)...].prefix { $0.count <= 2 && Int($0) != nil })
        return family.capitalized + (version.isEmpty ? "" : " " + version.joined(separator: "."))
    }
}

public struct ToolActivity: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case running, ok, failed }
    public var id: String
    public var name: String
    /// Command, file path, pattern or description, shortened. Shown on screen only, never logged.
    public var detail: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var state: State
    /// Ran inside a subagent.
    public var isSidechain: Bool
}

public struct ContextPoint: Sendable, Equatable {
    public var time: Date
    public var tokens: Int
}

/// What a running session is doing, from the tail of its transcript.
public struct LiveActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// A tool call has no result yet.
        case runningTool
        /// The last line is a prompt or a tool result: the model is working.
        case thinking
        /// The assistant finished its turn.
        case waiting
        case unknown
    }
    public var model: String?
    /// Prompt size of the latest main-conversation assistant message.
    public var contextTokens = 0
    public var maxContextTokens = 0
    public var contextSeries: [ContextPoint] = []
    /// Newest first, at most 40.
    public var tools: [ToolActivity] = []
    public var lastEventAt: Date?
    public var phase: Phase = .unknown
    public var subagentCalls = 0

    public var contextWindow: Int { ContextWindow.size(model: model, observed: maxContextTokens) }
    public var contextFraction: Double { contextWindow > 0 ? min(1, Double(contextTokens) / Double(contextWindow)) : 0 }
    public var runningTool: ToolActivity? { tools.first { $0.state == .running && !$0.isSidechain } }

    public init() {}
}

/// Follows one transcript from its tail. The first read looks at the last few MB only; later reads parse only
/// appended bytes. Not thread-safe: keep one per session inside an actor.
public final class LiveTail: @unchecked Sendable {
    public let url: URL
    private var offset: UInt64 = 0
    private var started = false
    private(set) public var activity = LiveActivity()
    /// Oldest first; `activity.tools` is the newest slice of it, reversed.
    private var all: [ToolActivity] = []
    private var toolIndex: [String: Int] = [:]
    private var lastMessageID: String?

    static let initialWindow: UInt64 = 6 << 20
    static let maxTools = 40
    static let maxSeries = 600

    public init(url: URL) { self.url = url }

    /// Reads what was appended since the last call and returns the updated activity.
    @discardableResult
    public func update() -> LiveActivity {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return activity }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; started = false; activity = LiveActivity(); toolIndex = [:]; all = [] }
        var skipPartialFirstLine = false
        if !started {
            started = true
            if size > Self.initialWindow { offset = size - Self.initialWindow; skipPartialFirstLine = true }
        }
        guard size > offset, (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: Int(size - offset)) else { return activity }
        var start = data.startIndex
        if skipPartialFirstLine, let nl = data[start...].firstIndex(of: 0x0A) { start = data.index(after: nl) }
        let decoder = JSONDecoder()
        var consumedEnd = start
        while let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start, let line = try? decoder.decode(TailLine.self, from: data[start..<nl]) { apply(line) }
            start = data.index(after: nl)
            consumedEnd = start
        }
        offset += UInt64(data.distance(from: data.startIndex, to: consumedEnd))
        if all.count > Self.maxTools * 5 {
            all.removeFirst(all.count - Self.maxTools * 2)
            toolIndex = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        }
        activity.tools = Array(all.suffix(Self.maxTools).reversed())
        if activity.contextSeries.count > Self.maxSeries { activity.contextSeries.removeFirst(activity.contextSeries.count - Self.maxSeries) }
        return activity
    }

    private func apply(_ l: TailLine) {
        let ts = l.timestamp.flatMap(ISO8601.parse)
        let side = l.isSidechain ?? false
        if let ts { activity.lastEventAt = max(activity.lastEventAt ?? ts, ts) }
        switch l.type {
        case "assistant":
            guard let m = l.message else { return }
            if !side, let u = m.usage {
                let prompt = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0)
                if prompt > 0 {
                    activity.contextTokens = prompt
                    activity.maxContextTokens = max(activity.maxContextTokens, prompt)
                    if let ts, m.id != lastMessageID { activity.contextSeries.append(ContextPoint(time: ts, tokens: prompt)) }
                    else if let last = activity.contextSeries.indices.last { activity.contextSeries[last].tokens = prompt }
                }
                if let model = m.model, model != "<synthetic>", !model.isEmpty { activity.model = model }
                lastMessageID = m.id
            }
            var sawTool = false
            for b in m.blocks where b.type == "tool_use" {
                guard let id = b.id else { continue }
                sawTool = true
                if toolIndex[id] != nil { continue }
                let name = b.name ?? "Tool"
                if name == "Task" || name == "Agent" { activity.subagentCalls += 1 }
                let t = ToolActivity(id: id, name: name, detail: Self.detail(name: name, b.input), startedAt: ts, finishedAt: nil, state: .running, isSidechain: side)
                toolIndex[id] = all.count
                all.append(t)
            }
            if !side {
                let hasText = m.blocks.contains { $0.type == "text" && !($0.text ?? "").isEmpty }
                activity.phase = sawTool ? .runningTool : (hasText && m.stop_reason != "tool_use" ? .waiting : .thinking)
            }
        case "user":
            guard let m = l.message else { return }
            var sawResult = false
            for b in m.blocks where b.type == "tool_result" {
                guard let id = b.tool_use_id, let i = toolIndex[id], i < all.count else { continue }
                sawResult = true
                all[i].state = (b.is_error ?? false) ? .failed : .ok
                all[i].finishedAt = ts
            }
            if !side, l.isMeta != true {
                let pending = all.suffix(20).contains { $0.state == .running && !$0.isSidechain }
                if sawResult { activity.phase = pending ? .runningTool : .thinking }
                else if m.isPromptText { activity.phase = .thinking }
            }
        default:
            break
        }
    }

    static func detail(name: String, _ i: TailLine.Input?) -> String {
        guard let i else { return "" }
        let raw: String? = switch name {
        case "Bash": i.command ?? i.description
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": i.file_path ?? i.notebook_path
        case "Grep", "Glob": i.pattern.map { p in i.path.map { "\u{201C}\(p)\u{201D} in \(($0 as NSString).lastPathComponent)" } ?? "\u{201C}\(p)\u{201D}" }
        case "Task", "Agent": [i.subagent_type, i.description].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case "WebFetch": i.url
        case "WebSearch": i.query
        case "Skill": i.skill
        default: i.description ?? i.file_path ?? i.command ?? i.pattern ?? i.url ?? i.query
        }
        let one = (raw ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return one.count > 160 ? String(one.prefix(159)) + "\u{2026}" : one
    }
}

/// Wire shape for the tail reader: the parts of a line `LiveTail` needs, nothing else.
struct TailLine: Decodable {
    struct Input: Decodable {
        var command: String?
        var description: String?
        var file_path: String?
        var notebook_path: String?
        var pattern: String?
        var path: String?
        var subagent_type: String?
        var url: String?
        var query: String?
        var skill: String?

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            func s(_ k: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
            command = s(.command); description = s(.description); file_path = s(.file_path); notebook_path = s(.notebook_path)
            pattern = s(.pattern); path = s(.path); subagent_type = s(.subagent_type); url = s(.url); query = s(.query); skill = s(.skill)
        }
        enum Keys: String, CodingKey { case command, description, file_path, notebook_path, pattern, path, subagent_type, url, query, skill }
    }

    struct Block: Decodable {
        var type: String?
        var text: String?
        var id: String?
        var name: String?
        var input: Input?
        var tool_use_id: String?
        var is_error: Bool?

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            switch type {
            case "text": text = try? c.decodeIfPresent(String.self, forKey: .text)
            case "tool_use":
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                name = try? c.decodeIfPresent(String.self, forKey: .name)
                input = try? c.decodeIfPresent(Input.self, forKey: .input)
            case "tool_result":
                tool_use_id = try? c.decodeIfPresent(String.self, forKey: .tool_use_id)
                is_error = try? c.decodeIfPresent(Bool.self, forKey: .is_error)
            default: break
            }
        }
        enum Keys: String, CodingKey { case type, text, id, name, input, tool_use_id, is_error }
    }

    struct Usage: Decodable {
        var input_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
    }

    struct Message: Decodable {
        var id: String?
        var model: String?
        var stop_reason: String?
        var usage: Usage?
        var blocks: [Block] = []
        var isPromptText = false

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            stop_reason = try? c.decodeIfPresent(String.self, forKey: .stop_reason)
            usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            if let s = try? c.decodeIfPresent(String.self, forKey: .content) {
                isPromptText = !s.isEmpty && !UserEntry.startsWithWrapperTag(s)
            } else {
                blocks = (try? c.decodeIfPresent([Block].self, forKey: .content)) ?? []
                isPromptText = blocks.contains { $0.type == "text" && !($0.text ?? "").isEmpty }
            }
        }
        enum Keys: String, CodingKey { case id, model, stop_reason, usage, content }
    }

    var type: String?
    var timestamp: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var message: Message?

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        isMeta = try? c.decodeIfPresent(Bool.self, forKey: .isMeta)
        if type == "user" || type == "assistant" { message = try? c.decodeIfPresent(Message.self, forKey: .message) }
    }
    enum Keys: String, CodingKey { case type, timestamp, isSidechain, isMeta, message }
}
