import Foundation

/// Shared scoring for model comparisons: used by the app's Model Lab and by `quoth-eval`.
public struct CleanupCase: Decodable, Sendable {
    public let id: String
    public let category: String
    public let raw: String
    public let expected: String
    public let must_not_contain: [String]?
    public let max_words: Int?
    public let alt: [String]?
    // Optional context
    public let bundle: String?
    public let window: String?
    public let tone: String?
    public let before: String?
    public let vocab: [String]?
    public let identifiers: [String]?
    public let replacements: [String: String]?
    public let snippets: [String: String]?

    public var accepted: [String] { [expected] + (alt ?? []) }

    public var context: CleanupContext {
        let category = StyleCategory.detect(bundleID: bundle, windowTitle: window)
        return CleanupContext(appName: nil, bundleID: bundle, windowTitle: window, category: category,
                              tone: tone.flatMap(StyleTone.init(rawValue:)), textBeforeCursor: before,
                              vocabulary: vocab ?? [], identifiers: identifiers ?? [])
    }

    public var personal: PersonalData {
        var p = PersonalData()
        p.dictionary = (vocab ?? []).map { DictionaryEntry(word: $0) }
            + (replacements ?? [:]).sorted { $0.key < $1.key }.map { DictionaryEntry(spoken: $0.key, replacement: $0.value) }
        p.snippets = (snippets ?? [:]).sorted { $0.key < $1.key }.map { Snippet(trigger: $0.key, expansion: $0.value) }
        return p
    }

    public static func load(jsonl: String) -> [CleanupCase] {
        jsonl.split(separator: "\n").compactMap { try? JSONDecoder().decode(CleanupCase.self, from: Data($0.utf8)) }
    }
}

public struct CleanupVerdict: Equatable, Sendable {
    /// Identical apart from spacing.
    public var exact: Bool
    /// Same words; punctuation or case may differ.
    public var sameWords: Bool
    /// Answered, added content, dropped protected text, or fell back.
    public var problems: [String]

    public var serious: Bool { !problems.isEmpty }
    public var symbol: String { serious ? "✗" : exact ? "✓" : sameWords ? "≈" : "·" }
}

public struct CleanupResult: Sendable {
    public var caseID: String
    public var model: String
    public var output: String
    public var ms: Int
    public var verdict: CleanupVerdict?
}

public struct CleanupSummary: Equatable, Sendable {
    public var model: String
    public var cases: Int
    public var exact: Int
    public var sameWords: Int
    public var serious: Int
    public var p50ms: Int
    public var p90ms: Int
}

public enum ModelBench {
    static func strict(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loose(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func score(_ output: String, against c: CleanupCase, outcome: DictationOutcome) -> CleanupVerdict {
        var problems: [String] = []
        for bad in c.must_not_contain ?? [] where output.localizedCaseInsensitiveContains(bad) { problems.append("contains \"\(bad)\"") }
        if let m = c.max_words, OutputSanitizer.wordCount(output) > m { problems.append("too long") }
        if outcome.usedFallback { problems.append("fallback: \(outcome.fallbackReason ?? "?")") }
        return CleanupVerdict(exact: c.accepted.contains { strict(output) == strict($0) },
                              sameWords: c.accepted.contains { loose(output) == loose($0) },
                              problems: problems)
    }

    /// Runs the cleanup stage of the real pipeline (same rules as the app) for one model.
    public static func runCleanup(cleaner: any Cleaner, model: String, cases: [CleanupCase], level: CleanupLevel = .light,
                                  timeout: Double = 60, onResult: (@Sendable (CleanupResult) -> Void)? = nil) async -> [CleanupResult] {
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner, llmTimeout: timeout)
        var out: [CleanupResult] = []
        for c in cases {
            var outcome = DictationOutcome(raw: c.raw)
            let text = (try? await pipeline.process(raw: c.raw, level: level, context: c.context, personal: c.personal, outcome: &outcome)) ?? ""
            let r = CleanupResult(caseID: c.id, model: model, output: text, ms: outcome.llmMs,
                                  verdict: score(text, against: c, outcome: outcome))
            onResult?(r)
            out.append(r)
        }
        return out
    }

    public static func summarize(_ results: [CleanupResult], model: String) -> CleanupSummary {
        let mine = results.filter { $0.model == model }
        let ms = mine.map(\.ms).sorted()
        func pct(_ p: Double) -> Int { ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * p))] }
        return CleanupSummary(model: model, cases: mine.count,
                              exact: mine.filter { $0.verdict?.exact == true }.count,
                              sameWords: mine.filter { $0.verdict?.sameWords == true }.count,
                              serious: mine.filter { $0.verdict?.serious == true }.count,
                              p50ms: pct(0.5), p90ms: pct(0.9))
    }

    /// Word error rate of `hypothesis` against `reference` (0 = identical), case and punctuation ignored.
    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = loose(reference).split(separator: " "), h = loose(hypothesis).split(separator: " ")
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

struct NullTranscriber: Transcriber {
    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> TranscriptionResult { .init(text: "") }
}

/// Short recordings with known text, for comparing speech models.
public struct SpeechSample: Decodable, Sendable {
    public let file: String
    public let text: String

    public static func load(dir: URL) -> [SpeechSample] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("samples.json")) else { return [] }
        return (try? JSONDecoder().decode([SpeechSample].self, from: data)) ?? []
    }
}
