import Foundation

/// Deterministic spoken-punctuation handling, used for cleanup level None
/// and as the fallback when the LLM is unavailable.
public enum SpokenPunctuation {
    // Longest phrases first so "new paragraph" wins over "new line" style overlaps.
    private static let rules: [(phrase: String, symbol: String)] = [
        ("new paragraph", "\n\n"),
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("question mark", "?"),
        ("line break", "\n"),
        ("next line", "\n"),
        ("new line", "\n"),
        ("full stop", "."),
        ("semicolon", ";"),
        ("period", "."),
        ("comma", ","),
        ("colon", ":"),
    ]

    public static func apply(_ text: String) -> String {
        replace(text, rules: rules)
    }

    /// Converts only the unambiguous line-break commands, before the LLM sees the text.
    /// Small models often leave "new paragraph" in the output; these phrases are almost never meant literally.
    public static func applyLineBreaks(_ text: String) -> String {
        let breaks = rules.filter { $0.symbol.hasPrefix("\n") }
        var s = text
        for (phrase, symbol) in breaks {
            let pattern = "[,.]?\\s*\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[,.]?\\s*"
            s = s.replacingOccurrences(of: pattern, with: symbol, options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, rules: [(phrase: String, symbol: String)]) -> String {
        var s = text
        for (phrase, symbol) in rules {
            // Whisper often decorates the spoken word itself: "Comma." / ", comma," – eat that too.
            let pattern = "[,.]?\\s*\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[,.!?]?"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let replacement = NSRegularExpression.escapedTemplate(for: symbol)
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
        }
        return tidy(s)
    }

    /// Fix spacing around punctuation and capitalise sentence starts.
    static func tidy(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "([,.!?;:])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return capitaliseSentences(s)
    }

    static func capitaliseSentences(_ text: String) -> String {
        var out = ""
        var capNext = true
        for ch in text {
            if capNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capNext = false
                continue
            }
            out.append(ch)
            if ".!?\n".contains(ch) { capNext = true } else if !ch.isWhitespace { capNext = false }
        }
        return out
    }
}
