import Foundation

/// USD per million tokens for one model.
public struct ModelPrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    /// 5-minute cache write. Default 1.25 x input.
    public var cacheWrite: Double
    /// 1-hour cache write. Default 2 x input.
    public var cacheWrite1h: Double
    /// Default 0.1 x input; some models are cheaper.
    public var cacheRead: Double
    /// Prompts (input + cache) above this many tokens use `longContext` prices.
    public var longContextThreshold: Int?
    public var longContextInput: Double?
    public var longContextOutput: Double?

    public init(input: Double, output: Double, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil, cacheRead: Double? = nil,
                longContextThreshold: Int? = nil, longContext: (input: Double, output: Double)? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite ?? input * 1.25
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.cacheRead = cacheRead ?? input * 0.1
        self.longContextThreshold = longContextThreshold
        self.longContextInput = longContext?.input
        self.longContextOutput = longContext?.output
    }

    public func cost(_ u: TokenUsage) -> Double {
        var p = self
        if let t = longContextThreshold, u.prompt > t, let li = longContextInput {
            let scale = li / input
            p = ModelPrice(input: li, output: longContextOutput ?? output, cacheWrite: cacheWrite * scale, cacheWrite1h: cacheWrite1h * scale, cacheRead: cacheRead * scale)
        }
        let write5m = max(0, u.cacheCreation - u.cacheCreation1h)
        let sum = Double(u.input) * p.input + Double(u.output) * p.output + Double(write5m) * p.cacheWrite
            + Double(u.cacheCreation1h) * p.cacheWrite1h + Double(u.cacheRead) * p.cacheRead
        return sum / 1_000_000
    }
}

public struct Cost: Sendable, Hashable {
    public enum Match: Sendable, Hashable {
        /// Model id matched a table entry (exactly or as a dated/suffixed variant).
        case exact
        /// Only the family name (opus/sonnet/haiku/fable) matched; the family's current price was used.
        case family
        /// Not priced; `usd` is 0.
        case unknown
    }
    public var usd: Double
    public var match: Match
    public var isPriced: Bool { match != .unknown }
}

public struct Pricing: Sendable {
    /// Keys are model ids. A key also matches ids that extend it (`claude-haiku-4-5` matches `claude-haiku-4-5-20251001`).
    public var table: [String: ModelPrice]
    /// Family fallback, checked by substring when no key matches.
    public var families: [String: ModelPrice]

    public init(table: [String: ModelPrice], families: [String: ModelPrice]) {
        self.table = table
        self.families = families
    }

    public static let bundled = Pricing(table: PriceTable.models, families: PriceTable.families)

    /// Returns the bundled table with `overrides` replacing or adding entries.
    public func overriding(_ overrides: [String: ModelPrice]) -> Pricing {
        var p = self
        p.table.merge(overrides) { _, new in new }
        return p
    }

    public func price(for model: String) -> (ModelPrice?, Cost.Match) {
        let m = model.lowercased()
        if let p = table[m] { return (p, .exact) }
        // Longest key that is a prefix of the id, ending at a separator: handles date and context suffixes.
        var best: (key: String, price: ModelPrice)?
        for (k, p) in table where m.hasPrefix(k) {
            let rest = m.dropFirst(k.count)
            guard rest.isEmpty || rest.first == "-" || rest.first == "@" || rest.first == "[" else { continue }
            if k.count > (best?.key.count ?? 0) { best = (k, p) }
        }
        if let best { return (best.price, .exact) }
        for name in ["fable", "mythos", "opus", "sonnet", "haiku"] where m.contains(name) {
            if let p = families[name] { return (p, .family) }
        }
        return (nil, .unknown)
    }

    public func cost(_ usage: TokenUsage, model: String) -> Cost {
        if model == "<synthetic>" { return Cost(usd: 0, match: .exact) }
        let (p, match) = price(for: model)
        guard let p else { return Cost(usd: 0, match: usage.isZero ? .exact : .unknown) }
        return Cost(usd: p.cost(usage), match: match)
    }
}
