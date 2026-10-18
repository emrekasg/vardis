import Foundation

/// Bundled Anthropic API list prices, USD per million tokens.
///
/// THESE VALUES MUST BE CHECKED AGAINST https://www.anthropic.com/pricing BEFORE EACH RELEASE.
/// Last checked: 2026-10-18 (cached model table dated 2026-10-06).
///
/// Defaults unless an entry says otherwise: 5-minute cache write = 1.25 x input, 1-hour cache write = 2 x input,
/// cache read = 0.1 x input. Subscription (Pro/Max) users do not pay these prices; the number is what the same
/// usage would cost on the API.
enum PriceTable {
    static let models: [String: ModelPrice] = [
        // Fable / Mythos
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        "claude-mythos-5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        // Opus
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25),
        "claude-opus-4-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-1": ModelPrice(input: 15, output: 75),
        "claude-opus-4": ModelPrice(input: 15, output: 75),
        // Sonnet
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4-5": ModelPrice(input: 3, output: 15),
        "claude-sonnet-4": ModelPrice(input: 3, output: 15),
        "claude-3-7-sonnet": ModelPrice(input: 3, output: 15),
        // Haiku
        "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50, longContextThreshold: 100_000, longContext: (input: 0.50, output: 2.50)),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5),
        "claude-3-5-haiku": ModelPrice(input: 0.80, output: 4),
    ]

    /// Used when only the family name is recognised: the family's current model.
    static let families: [String: ModelPrice] = [
        "fable": models["claude-fable-5-1"]!,
        "mythos": models["claude-mythos-5-1"]!,
        "opus": models["claude-opus-5-5"]!,
        "sonnet": models["claude-sonnet-5-5"]!,
        "haiku": models["claude-haiku-5-5"]!,
    ]
}
