import Foundation

/// Deterministic dictionary replacements and snippet expansion.
/// These run after the LLM so the model can never rewrite them.
public enum TextRules {
    // Not a letter, digit, underscore or apostrophe-joined word part.
    private static let left = "(?<![\\p{L}\\p{N}_])"
    // Allow a possessive "'s" after the match, but never touch "n't"-style contractions.
    private static let right = "(?=(?:['’]s)?(?![\\p{L}\\p{N}_])(?!['’](?:t|ve|re|ll|d|m)\\b))"

    private static func phrasePattern(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s-]+")
    }

    /// Applies replacement entries (longest phrase first) and fixes the casing of word entries.
    /// Returns the new text and the IDs of entries that fired (for usage ranking).
    public static func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> (String, [UUID]) {
        var s = text
        var fired: [UUID] = []
        var protected: [String] = []

        let ordered = entries
            .filter { $0.kind == .replacement || $0.phrase.contains(where: \.isUppercase) }
            .sorted { $0.phrase.count > $1.phrase.count }
        for e in ordered {
            let pattern = left + phrasePattern(e.phrase) + right
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            guard re.firstMatch(in: s, range: range) != nil else { continue }
            if e.kind == .word, re.matches(in: s, range: range).allSatisfy({ (s as NSString).substring(with: $0.range) == e.phrase }) {
                continue  // already spelled right
            }
            // Swap in a placeholder so shorter phrases can't match inside this output.
            let token = "\u{E000}\(protected.count)\u{E001}"
            protected.append(e.output)
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: token))
            fired.append(e.id)
        }
        for (i, value) in protected.enumerated() {
            s = s.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: value)
        }
        return (s, fired)
    }

    /// Replaces snippet triggers with numbered tokens so the LLM can't paraphrase them.
    /// Returns the protected text and the expansions keyed by token.
    public static func protectSnippets(_ text: String, snippets: [Snippet]) -> (String, [(token: String, snippet: Snippet)]) {
        var out = text
        var tokens: [(String, Snippet)] = []
        for sn in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let pattern = "(?<![\\p{L}\\p{N}_])" + phrasePattern(sn.trigger) + "(?![\\p{L}\\p{N}_])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) != nil else { continue }
            let token = "[[S\(tokens.count + 1)]]"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: token))
            tokens.append((token, sn))
        }
        return (out, tokens)
    }

    /// Normalises for "spoken alone" comparison: case, punctuation and trailing period ignored.
    static func normalised(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// If the whole dictation is one snippet trigger, returns its exact expansion.
    public static func snippetSpokenAlone(_ text: String, snippets: [Snippet]) -> Snippet? {
        let n = normalised(text)
        guard !n.isEmpty else { return nil }
        return snippets.filter { normalised($0.trigger) == n }.max { $0.trigger.count < $1.trigger.count }
    }

    /// Expands snippet triggers inside a sentence. Longest trigger wins; triggers can't touch
    /// letters, digits or underscores; adjacent punctuation is fine.
    public static func expandSnippets(_ text: String, snippets: [Snippet]) -> (String, [UUID]) {
        if let s = snippetSpokenAlone(text, snippets: snippets) { return (s.expansion, [s.id]) }
        var out = text
        var fired: [UUID] = []
        var protected: [String] = []
        for sn in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let pattern = "(?<![\\p{L}\\p{N}_])" + phrasePattern(sn.trigger) + "(?![\\p{L}\\p{N}_])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: range) != nil else { continue }
            let token = "\u{E002}\(protected.count)\u{E003}"
            protected.append(sn.expansion)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: token))
            fired.append(sn.id)
        }
        for (i, value) in protected.enumerated() {
            out = out.replacingOccurrences(of: "\u{E002}\(i)\u{E003}", with: value)
        }
        return (out, fired)
    }
}
