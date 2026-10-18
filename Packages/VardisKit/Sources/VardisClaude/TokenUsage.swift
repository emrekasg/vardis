import Foundation

/// Token counts as Claude Code records them in `message.usage`.
public struct TokenUsage: Sendable, Hashable, Codable {
    public var input: Int
    public var output: Int
    /// All cache writes (`cache_creation_input_tokens`).
    public var cacheCreation: Int
    public var cacheRead: Int
    /// The part of `cacheCreation` written with the 1-hour TTL (priced higher). Included in `cacheCreation`.
    public var cacheCreation1h: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, cacheCreation1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreation1h = cacheCreation1h
    }

    public static let zero = TokenUsage()

    public var total: Int { input + output + cacheCreation + cacheRead }
    /// Everything sent to the model in one request (for long-context price tiers).
    public var prompt: Int { input + cacheCreation + cacheRead }
    public var isZero: Bool { total == 0 }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheCreation: a.cacheCreation + b.cacheCreation,
                   cacheRead: a.cacheRead + b.cacheRead, cacheCreation1h: a.cacheCreation1h + b.cacheCreation1h)
    }

    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }

    /// Field-wise maximum. Streamed copies of one message only grow, so the max is the final count.
    public func merged(with o: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(input, o.input), output: max(output, o.output), cacheCreation: max(cacheCreation, o.cacheCreation),
                   cacheRead: max(cacheRead, o.cacheRead), cacheCreation1h: max(cacheCreation1h, o.cacheCreation1h))
    }
}
