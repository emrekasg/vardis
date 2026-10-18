import Foundation

/// Builds a short excerpt around the first matched term, terms wrapped in `SessionHit.snippetMarkers`.
/// Matching mirrors the index tokenizer closely enough for display: case and diacritic insensitive,
/// whole words, the last term as a prefix.
enum Snippet {
    static func make(_ text: String, terms: [String], words: Int = 12) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return "" }
        let needles = terms.map(fold)
        func matches(_ t: Substring) -> Bool {
            let f = fold(String(t))
            for (i, n) in needles.enumerated() where !n.isEmpty {
                if i == needles.count - 1 ? f.hasPrefix(n) : f == n { return true }
            }
            return false
        }
        let first = tokens.firstIndex { matches($0.word) } ?? 0
        let lo = max(0, first - words / 3)
        let hi = min(tokens.count, lo + words)
        let m = SessionHit.snippetMarkers
        var out = lo > 0 ? "\u{2026}" : ""
        for i in lo..<hi {
            let t = tokens[i]
            out += t.lead
            out += matches(t.word) ? m.open + t.word + m.close : String(t.word)
        }
        if hi < tokens.count { out += "\u{2026}" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Word runs with the separator text before each (newlines collapsed to spaces).
    private static func tokenize(_ text: String) -> [(lead: String, word: Substring)] {
        var out: [(String, Substring)] = []
        var lead = ""
        var i = text.startIndex
        let limit = text.index(text.startIndex, offsetBy: min(text.count, 4_000))
        while i < limit {
            if text[i].isLetter || text[i].isNumber {
                var j = i
                while j < limit, text[j].isLetter || text[j].isNumber { j = text.index(after: j) }
                out.append((lead, text[i..<j]))
                lead = ""
                i = j
            } else {
                let c = text[i]
                lead += c.isNewline || c == "\t" ? " " : String(c)
                if lead.count > 3 { lead = String(lead.suffix(3)) }
                i = text.index(after: i)
            }
        }
        return out
    }
}
