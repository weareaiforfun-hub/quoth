import Foundation

/// Learns words from the user's edits to a just-pasted dictation.
public enum AutoLearn {
    /// Everyday acronyms that are never worth learning.
    static let everydayAcronyms: Set<String> = [
        "PDF", "CEO", "CTO", "CFO", "USA", "UK", "EU", "OK", "FAQ", "URL", "API", "AI", "TV", "PM", "AM",
        "ASAP", "FYI", "ETA", "HR", "IT", "PR", "UI", "UX", "ID", "VIP", "DIY", "NYC", "LA", "SF",
    ]

    /// - Parameters:
    ///   - before: the field's text right after our paste.
    ///   - after: the field's text a few seconds later.
    ///   - pasted: what we pasted (edits elsewhere in the field are ignored).
    ///   - isCommonWord: true for ordinary dictionary words (lowercased).
    /// - Returns: words to add to the dictionary.
    public static func candidates(pasted: String, before: String, after: String,
                                  isCommonWord: (String) -> Bool,
                                  known: Set<String>, deleted: Set<String>) -> [String] {
        let b = words(before), a = words(after)
        guard b != a else { return [] }
        // Isolate the changed region by trimming the common prefix and suffix.
        var p = 0
        while p < b.count, p < a.count, b[p] == a[p] { p += 1 }
        var sfx = 0
        while sfx < b.count - p, sfx < a.count - p, b[b.count - 1 - sfx] == a[a.count - 1 - sfx] { sfx += 1 }
        let old = Array(b[p..<(b.count - sfx)])
        let new = Array(a[p..<(a.count - sfx)])
        // A small, local correction, not a rewrite.
        guard !old.isEmpty, !new.isEmpty, old.count <= 4, new.count <= 4 else { return [] }
        let pastedWords = Set(words(pasted).map { $0.lowercased() })
        guard old.allSatisfy({ pastedWords.contains($0.lowercased()) }) else { return [] }

        var pairs: [(String, String)] = []
        if old.count == new.count {
            pairs = zip(old, new).filter { $0 != $1 }.map { ($0, $1) }
        } else if new.count == 1 {
            pairs = [(old.joined(separator: " "), new[0])]
        } else {
            pairs = [(old.joined(separator: " "), new.joined(separator: " "))]
        }

        let knownLower = Set(known.map { $0.lowercased() })
        let deletedLower = Set(deleted.map { $0.lowercased() })
        var out: [String] = []
        for (o, n) in pairs {
            guard similarity(o.lowercased(), n.lowercased()) >= 0.4 else { continue }
            guard isLearnable(n, isCommonWord: isCommonWord) else { continue }
            let key = n.lowercased()
            if knownLower.contains(key) || deletedLower.contains(key) || out.contains(n) { continue }
            out.append(n)
        }
        return out
    }

    static func isLearnable(_ w: String, isCommonWord: (String) -> Bool) -> Bool {
        guard w.count >= 3, w.count <= 60, w.contains(where: \.isLetter) else { return false }
        if w.contains("://") || w.hasPrefix("www.") || w.contains("/") || w.contains("\\") || w.contains("@") { return false }
        if w.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return false }
        if w.allSatisfy({ $0.isNumber || ":-./".contains($0) }) { return false }
        if everydayAcronyms.contains(w) { return false }
        // Proper noun or jargon: has a capital, or isn't an ordinary word.
        let parts = w.split(separator: " ").map(String.init)
        let hasCapital = w.contains(where: \.isUppercase)
        let allCommon = parts.allSatisfy { isCommonWord($0.lowercased()) }
        if allCommon && !hasInternalCapital(w) && (!hasCapital || parts.count == 1 && isCommonWord(w.lowercased())) {
            // "Apple" → common word "apple", capitalised only at sentence start: skip.
            return false
        }
        return true
    }

    static func hasInternalCapital(_ w: String) -> Bool {
        w.dropFirst().contains(where: \.isUppercase)
    }

    /// Word tokens with surrounding punctuation removed.
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_"))) }
            .filter { !$0.isEmpty }
    }

    /// 1 − normalised Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}

public enum AudioGain {
    /// Whisper mode: boost quiet recordings so whispered speech reaches the model at a normal level.
    public static func normalise(_ samples: [Float], targetPeak: Float = 0.7, maxGain: Float = 10) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0.001, peak < targetPeak / 2 else { return samples }
        let gain = min(maxGain, targetPeak / peak)
        return samples.map { $0 * gain }
    }
}
