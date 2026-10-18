import Foundation

public struct ParseResult: Sendable {
    public var events: [TranscriptEvent]
    /// Byte offset just past the last complete line. Resume from here next time.
    public var offset: UInt64
    public var bytesRead: Int
    public var lineCount: Int
    public var malformedLines: Int
}

/// Reads Claude Code `.jsonl` transcripts incrementally.
///
/// Only complete lines (ending in `\n`) are consumed; a trailing partial line is left for the next call.
/// Lines are decoded with `JSONDecoder` into structs that declare only the needed keys. Benchmarked on a
/// 64 MB real transcript (release build): JSONDecoder 0.040 s, JSONSerialization 0.108 s.
public enum TranscriptParser {
    public static let chunkSize = 4 << 20

    public static func parse(url: URL, from offset: UInt64 = 0) throws -> ParseResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var result = ParseResult(events: [], offset: offset, bytesRead: 0, lineCount: 0, malformedLines: 0)
        var carry = Data()
        let decoder = JSONDecoder()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            result.bytesRead += chunk.count
            var buffer: Data
            if carry.isEmpty { buffer = chunk } else { carry.append(chunk); buffer = carry }
            let consumed = parseLines(buffer, decoder: decoder, into: &result)
            result.offset += UInt64(consumed)
            carry = consumed < buffer.count ? Data(buffer[(buffer.startIndex + consumed)...]) : Data()
            if chunk.count < chunkSize { break }
        }
        return result
    }

    /// Parses complete lines of `data`. Returns the events and the number of bytes consumed.
    public static func parse(data: Data) -> (events: [TranscriptEvent], consumed: Int) {
        var r = ParseResult(events: [], offset: 0, bytesRead: data.count, lineCount: 0, malformedLines: 0)
        let consumed = parseLines(data, decoder: JSONDecoder(), into: &r)
        return (r.events, consumed)
    }

    /// One entry per assistant message: streamed copies (same message id and request id) merged, max usage kept.
    public static func dedupedAssistantMessages(_ events: [TranscriptEvent]) -> [AssistantEntry] {
        var order: [String] = []
        var byKey: [String: AssistantEntry] = [:]
        for case .assistant(let a) in events {
            if var existing = byKey[a.dedupeKey] {
                existing.usage = existing.usage.merged(with: a.usage)
                existing.toolUses += a.toolUses
                if let t = a.text { existing.text = existing.text.map { $0 + "\n" + t } ?? t }
                byKey[a.dedupeKey] = existing
            } else {
                byKey[a.dedupeKey] = a
                order.append(a.dedupeKey)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Lines

    private static func parseLines(_ data: Data, decoder: JSONDecoder, into r: inout ParseResult) -> Int {
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let nl = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start {
                    r.lineCount += 1
                    let line = data[(data.startIndex + start)..<(data.startIndex + end)]
                    if !mayBeRelevant(base + start, end - start) {
                        // attachment, mode, file-history, queue-operation, ...: skipped without decoding.
                    } else if let raw = try? decoder.decode(RawLine.self, from: line) {
                        if let e = event(from: raw) { r.events.append(e) }
                    } else {
                        r.malformedLines += 1
                    }
                }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    /// Unescaped `"type":"<kind>"` byte patterns for the line kinds we read. A nested match only costs a decode;
    /// the decoded top-level `type` still decides, so this filter never drops a relevant line.
    private static let needles: [[UInt8]] = ["user", "assistant", "custom-title", "ai-title", "summary"].map { Array("\"type\":\"\($0)\"".utf8) }

    private static func mayBeRelevant(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        for needle in needles {
            if needle.withUnsafeBytes({ memmem(p, n, $0.baseAddress, $0.count) }) != nil { return true }
        }
        return false
    }

    static func event(from l: RawLine) -> TranscriptEvent? {
        let meta = LineMeta(sessionID: l.sessionId, uuid: l.uuid, timestamp: l.timestamp.flatMap(ISO8601.parse),
                            cwd: l.cwd, gitBranch: l.gitBranch, isSidechain: l.isSidechain ?? false)
        switch l.type {
        case "user":
            guard let m = l.message else { return nil }
            var text: String?
            var results: [ToolResult] = []
            switch m.content {
            case .text(let s): text = s
            case .blocks(let blocks):
                var parts: [String] = []
                for b in blocks {
                    if b.type == "text", let t = b.text { parts.append(t) }
                    if b.type == "tool_result", let id = b.tool_use_id { results.append(ToolResult(toolUseID: id, isError: b.is_error ?? false)) }
                }
                if !parts.isEmpty { text = parts.joined(separator: "\n") }
            case nil: break
            }
            return .user(UserEntry(meta: meta, isMeta: l.isMeta ?? false, text: text, toolResults: results))
        case "assistant":
            guard let m = l.message else { return nil }
            guard let id = m.id ?? l.requestId ?? l.uuid else { return nil }
            var parts: [String] = []
            var tools: [ToolUse] = []
            if case .blocks(let blocks) = m.content {
                for b in blocks {
                    if b.type == "text", let t = b.text, !t.isEmpty { parts.append(t) }
                    if b.type == "tool_use", let tid = b.id { tools.append(ToolUse(id: tid, name: b.name ?? "", filePath: b.input?.file_path ?? b.input?.notebook_path)) }
                }
            } else if case .text(let s) = m.content, !s.isEmpty {
                parts.append(s)
            }
            let u = m.usage
            let usage = TokenUsage(input: u?.input_tokens ?? 0, output: u?.output_tokens ?? 0, cacheCreation: u?.cache_creation_input_tokens ?? 0,
                                   cacheRead: u?.cache_read_input_tokens ?? 0, cacheCreation1h: u?.cache_creation?.ephemeral_1h_input_tokens ?? 0)
            return .assistant(AssistantEntry(meta: meta, messageID: id, requestID: l.requestId, model: m.model ?? "",
                                             usage: usage, text: parts.isEmpty ? nil : parts.joined(separator: "\n"), toolUses: tools))
        case "custom-title":
            guard let t = l.customTitle, !t.isEmpty else { return nil }
            return .title(TitleEntry(kind: .custom, text: t, sessionID: l.sessionId))
        case "ai-title":
            guard let t = l.aiTitle, !t.isEmpty else { return nil }
            return .title(TitleEntry(kind: .ai, text: t, sessionID: l.sessionId))
        case "summary":
            guard let t = l.summary, !t.isEmpty else { return nil }
            return .title(TitleEntry(kind: .summary, text: t, sessionID: l.sessionId))
        default:
            return nil
        }
    }
}

// MARK: - Wire shapes (only the keys we read; everything else is skipped by the decoder)

struct RawLine: Decodable {
    var type: String?
    var sessionId: String?
    var uuid: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var requestId: String?
    var message: RawMessage?
    var customTitle: String?
    var aiTitle: String?
    var summary: String?

    enum CodingKeys: String, CodingKey {
        case type, sessionId, uuid, timestamp, cwd, gitBranch, isSidechain, isMeta, requestId, message, customTitle, aiTitle, summary
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try? c.decodeIfPresent(String.self, forKey: .gitBranch)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        isMeta = try? c.decodeIfPresent(Bool.self, forKey: .isMeta)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        // Only conversation lines need the (large) message object.
        if type == "user" || type == "assistant" { message = try? c.decodeIfPresent(RawMessage.self, forKey: .message) }
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
        aiTitle = try? c.decodeIfPresent(String.self, forKey: .aiTitle)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
    }
}

struct RawMessage: Decodable {
    var id: String?
    var model: String?
    var usage: RawUsage?
    var content: RawContent?

    enum CodingKeys: String, CodingKey { case id, model, usage, content }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        usage = try? c.decodeIfPresent(RawUsage.self, forKey: .usage)
        content = try? c.decodeIfPresent(RawContent.self, forKey: .content)
    }
}

struct RawUsage: Decodable {
    struct Creation: Decodable { var ephemeral_1h_input_tokens: Int? }
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation: Creation?
}

enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        self = .blocks(try c.decode([RawBlock].self))
    }
}

struct RawBlock: Decodable {
    struct Input: Decodable { var file_path: String?; var notebook_path: String? }
    var type: String?
    var text: String?
    var id: String?
    var name: String?
    var tool_use_id: String?
    var is_error: Bool?
    var input: Input?

    enum CodingKeys: String, CodingKey { case type, text, id, name, tool_use_id, is_error, input }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "text":
            text = try? c.decodeIfPresent(String.self, forKey: .text)
        case "tool_use":
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            input = try? c.decodeIfPresent(Input.self, forKey: .input)
        case "tool_result":
            tool_use_id = try? c.decodeIfPresent(String.self, forKey: .tool_use_id)
            is_error = try? c.decodeIfPresent(Bool.self, forKey: .is_error)
        default:
            break
        }
    }
}

// MARK: - Timestamps

enum ISO8601 {
    /// Fast path for `YYYY-MM-DDTHH:MM:SS(.fff)Z`; falls back to Foundation for offsets.
    static func parse(_ s: String) -> Date? {
        var u = Array(s.utf8)
        if let d = fast(&u) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func fast(_ u: inout [UInt8]) -> Date? {
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) { let c = Int(u[i]) - 48; guard c >= 0, c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return nil }
        var frac = 0.0
        if u[19] == 46 {
            var scale = 0.1
            for i in 20..<(u.count - 1) {
                let c = Int(u[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                frac += Double(c) * scale
                scale /= 10
            }
        } else if u.count != 20 {
            return nil
        }
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let secs = Double(days * 86_400 + h * 3600 + mi * 60 + se) + frac
        return Date(timeIntervalSince1970: secs)
    }
}
