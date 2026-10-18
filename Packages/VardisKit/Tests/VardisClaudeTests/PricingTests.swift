import Foundation
import Testing
@testable import VardisClaude

@Suite struct PricingTests {
    @Test func costMath() {
        let p = Pricing.bundled
        // Opus 5.5: $4 in, $20 out, 5m write 1.25x = $5, 1h write 2x = $8, read $0.20.
        let u = TokenUsage(input: 1_000_000, output: 1_000_000, cacheCreation: 2_000_000, cacheRead: 1_000_000, cacheCreation1h: 1_000_000)
        let c = p.cost(u, model: "claude-opus-5-5")
        #expect(c.match == .exact)
        #expect(abs(c.usd - (4 + 20 + 5 + 8 + 0.20)) < 1e-9)
        // Sonnet 5.5 with the default 0.1x read.
        let s = p.cost(TokenUsage(input: 0, output: 0, cacheCreation: 0, cacheRead: 1_000_000), model: "claude-sonnet-5-5")
        #expect(abs(s.usd - 0.20) < 1e-9)
    }

    @Test func modelMatching() {
        let p = Pricing.bundled
        #expect(p.price(for: "claude-haiku-4-5-20251001").1 == .exact)
        #expect(p.price(for: "claude-haiku-4-5-20251001").0?.input == 1)
        #expect(p.price(for: "claude-opus-5").0?.input == 5)        // not confused with opus-5-5
        #expect(p.price(for: "claude-opus-5-5[1m]").0?.input == 4)
        #expect(p.price(for: "claude-fable-5-1").0?.output == 50)
        #expect(p.price(for: "us.anthropic.claude-sonnet-9").1 == .family)
        #expect(p.price(for: "gpt-x").1 == .unknown)
        #expect(p.cost(TokenUsage(input: 5), model: "gpt-x") == Cost(usd: 0, match: .unknown))
        #expect(p.cost(.zero, model: "<synthetic>").isPriced)
    }

    @Test func haikuLongContextTier() {
        let p = Pricing.bundled
        let small = p.cost(TokenUsage(input: 100_000, output: 0), model: "claude-haiku-5-5").usd
        let big = p.cost(TokenUsage(input: 100_001, output: 0), model: "claude-haiku-5-5").usd
        #expect(abs(small - 0.01) < 1e-9)
        #expect(abs(big - 100_001 * 0.50 / 1_000_000) < 1e-9)
    }

    @Test func tokenUsageArithmetic() {
        let a = TokenUsage(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        #expect((a + a).total == 20)
        #expect(a.merged(with: TokenUsage(input: 5)).input == 5)
        #expect(a.merged(with: TokenUsage(input: 5)).output == 2)
    }
}
