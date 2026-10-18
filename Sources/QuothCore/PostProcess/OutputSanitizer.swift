import Foundation

public enum OutputSanitizer {
    /// Strips artefacts small LLMs add around the cleaned text.
    public static func sanitize(_ output: String, raw: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "</?transcript>", with: "", options: .regularExpression)
        // Drop a preamble line such as "Here is the cleaned text:".
        if let first = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           first.range(of: "^(here('s| is)|sure|cleaned( text| transcript)?|output)\\b.*:\\s*$",
                       options: [.regularExpression, .caseInsensitive]) != nil {
            s = String(s.dropFirst(first.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap quotes the speaker did not dictate.
        for (o, c) in [("\"", "\""), ("“", "”"), ("'", "'")] where s.count > 2 && s.hasPrefix(o) && s.hasSuffix(c) {
            let inner = s.dropFirst().dropLast()
            if !inner.contains(o) && !raw.lowercased().contains("quote") { s = String(inner) }
        }
        // Spec: never insert em dashes automatically.
        if !raw.lowercased().contains("dash") {
            s = s.replacingOccurrences(of: "\\s*—\\s*", with: ", ", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic for "the model answered or embellished instead of cleaning".
    /// Cleanup only removes or rearranges words, so a much longer output is suspicious.
    public static func looksLikeAnswer(_ output: String, raw: String) -> Bool {
        let rawWords = wordCount(raw)
        let outWords = wordCount(output)
        return outWords > Int(Double(rawWords) * 1.4) + 6
    }

    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}

public enum TranscriptFilter {
    /// Removes whisper's non-speech tags, and (for near-silent audio) its stock hallucinations.
    public static func clean(_ text: String, likelySilence: Bool = false) -> String {
        var s = text.replacingOccurrences(of: "\\[[^\\]]*\\]|\\((?:music|silence|applause|laughs?|inaudible|blank_audio)[^)]*\\)",
                                          with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hallucinations: Set<String> = ["thank you.", "thanks for watching!", "thank you for watching.", "you", "."]
        if likelySilence && hallucinations.contains(s.lowercased()) { return "" }
        return s
    }
}
