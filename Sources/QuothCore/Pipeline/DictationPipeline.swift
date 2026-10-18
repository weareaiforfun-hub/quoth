import Foundation

public struct DictationOutcome: Sendable, Equatable {
    /// What the ASR heard (after removing non-speech tags).
    public var raw: String
    /// The text that should be pasted.
    public var final: String
    public var language: String?
    public var asrMs: Int
    public var llmMs: Int
    /// True when cleanup was skipped, failed, timed out or was rejected.
    public var usedFallback: Bool
    public var fallbackReason: String?
    /// Dictionary entries and snippets that fired (for usage ranking).
    public var firedEntries: [UUID] = []
    public var firedSnippets: [UUID] = []
    /// Set when the detected language was outside the user's pinned set.
    public var detectedOutsideSet: String?

    public init(raw: String, final: String = "", language: String? = nil, asrMs: Int = 0, llmMs: Int = 0,
                usedFallback: Bool = false, fallbackReason: String? = nil) {
        self.raw = raw; self.final = final; self.language = language; self.asrMs = asrMs; self.llmMs = llmMs
        self.usedFallback = usedFallback; self.fallbackReason = fallbackReason
    }
}

/// audio → ASR → cleanup LLM → deterministic post-processing → final string.
public struct DictationPipeline: Sendable {
    public let transcriber: any Transcriber
    public let cleaner: (any Cleaner)?
    /// Base cleanup timeout (seconds); the effective timeout grows with dictation length.
    public let llmTimeout: Double
    /// Extra seconds allowed per word: the LLM must write every word back out, so a 250-word
    /// dictation legitimately takes ~12 s on a local 14B model.
    public let llmSecondsPerWord: Double

    public init(transcriber: any Transcriber, cleaner: (any Cleaner)?, llmTimeout: Double, llmSecondsPerWord: Double = 0.08) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.llmTimeout = llmTimeout
        self.llmSecondsPerWord = llmSecondsPerWord
    }

    public func effectiveTimeout(for raw: String) -> Double {
        llmTimeout + Double(OutputSanitizer.wordCount(raw)) * llmSecondsPerWord
    }

    public func run(samples: [Float], level: CleanupLevel, languages: [String], context: CleanupContext,
                    personal: PersonalData = PersonalData()) async throws -> DictationOutcome {
        let t0 = Date()
        let quiet = AudioLevel.rms(samples) < 0.004
        // Whisper mode: bring quiet speech up to a normal level before ASR.
        let wav = WAVEncoder.encode(AudioGain.normalise(samples))
        // One language per dictation: pinned, or detected and constrained to the user's set.
        var language = languages.count == 1 ? languages[0] : nil
        var outside: String?
        if languages.count > 1, let detector = transcriber as? LanguageDetecting {
            let detected = try? await detector.detectLanguage(wav: wav)
            if let detected, languages.contains(detected) {
                language = detected
            } else {
                language = languages[0]
                outside = detected
            }
        }
        let bias = (context.vocabulary + context.identifiers.prefix(40)).joined(separator: ", ")
        let result = try await transcriber.transcribe(wav: wav, language: language,
                                                      prompt: bias.isEmpty ? nil : String(bias.prefix(800)))
        let asrMs = ms(since: t0)
        let raw = TranscriptFilter.clean(result.text, likelySilence: quiet)
        var outcome = DictationOutcome(raw: raw, language: language ?? result.language, asrMs: asrMs)
        outcome.detectedOutsideSet = outside
        guard !raw.isEmpty else { return outcome }
        var ctx = context
        ctx.language = outcome.language
        outcome.final = try await process(raw: raw, level: level, context: ctx, personal: personal, outcome: &outcome)
        return outcome
    }

    /// Everything after ASR: cleanup + deterministic rules. Also used by retry and evals.
    public func process(raw: String, level: CleanupLevel, context: CleanupContext, personal: PersonalData,
                        outcome: inout DictationOutcome) async throws -> String {
        // A snippet spoken on its own is pasted verbatim; no LLM needed.
        if let sn = TextRules.snippetSpokenAlone(raw, snippets: personal.snippets) {
            outcome.firedSnippets = [sn.id]
            return sn.expansion
        }
        var input = raw
        if context.isCodeEditor {
            input = DevFormatting.spokenFilenames(input)
            input = DevFormatting.applyIdentifiers(input, identifiers: context.identifiers)
        }
        // Apply replacements before the LLM too, so it sees (and keeps) the right spelling.
        let (preReplaced, preEntries) = TextRules.applyDictionary(input, entries: personal.dictionary)
        input = preReplaced
        // Shield snippet triggers from the LLM with tokens.
        let (shielded, tokens) = TextRules.protectSnippets(input, snippets: personal.snippets)
        var text = try await cleanup(raw: shielded, level: level, context: context, outcome: &outcome)
        var firedSnippets: [UUID] = []
        if !tokens.isEmpty {
            if tokens.allSatisfy({ text.contains($0.token) }) {
                // Expanded at the very end (after style rules), so park them on private-use markers.
                for (i, t) in tokens.enumerated() { text = text.replacingOccurrences(of: t.token, with: "\u{E010}\(i)\u{E011}") }
            } else {
                // The LLM mangled a token: fall back to deterministic cleanup of the unshielded text.
                text = SpokenPunctuation.apply(input)
                outcome.usedFallback = true
                outcome.fallbackReason = "cleanup dropped a snippet"
            }
        }

        let (replaced, entries) = TextRules.applyDictionary(text, entries: personal.dictionary)
        text = replaced
        outcome.firedEntries = Array(Set(preEntries + entries))
        if context.isCodeEditor {
            text = DevFormatting.applyIdentifiers(text, identifiers: context.identifiers)
        }
        let protectedWords = personal.dictionary.map(\.output)
        text = StyleRules.apply(text, tone: context.tone, category: context.category,
                                hasSelection: context.hasSelection, protectedWords: protectedWords,
                                rawTarget: context.preferRawFormatting || context.isCodeEditor)
        text = Continuation.apply(text, before: context.textBeforeCursor, after: context.textAfterCursor,
                                  protectedWords: protectedWords)
        text = LanguageRules.apply(text, language: context.language, variant: context.variant, isCodeEditor: context.isCodeEditor)
        for (i, t) in tokens.enumerated() where text.contains("\u{E010}\(i)\u{E011}") {
            text = text.replacingOccurrences(of: "\u{E010}\(i)\u{E011}", with: t.snippet.expansion)
            firedSnippets.append(t.snippet.id)
        }
        let (expanded, snippets) = TextRules.expandSnippets(text, snippets: personal.snippets)
        text = expanded
        outcome.firedSnippets = firedSnippets + snippets
        // Spec: any dictionary or snippet substitution disables file tagging for this dictation.
        if context.isFileTaggingEditor && outcome.firedEntries.isEmpty && outcome.firedSnippets.isEmpty {
            text = DevFormatting.tagFiles(text)
        }
        return text
    }

    /// LLM cleanup with timeout and safety fallbacks.
    public func cleanup(raw: String, level: CleanupLevel, context: CleanupContext,
                        outcome: inout DictationOutcome) async throws -> String {
        let fallback = SpokenPunctuation.apply(raw)
        guard level != .none, let cleaner else {
            outcome.usedFallback = level != .none
            outcome.fallbackReason = level == .none ? nil : "no cleaner configured"
            return fallback
        }
        let t1 = Date()
        do {
            let out = try await withTimeout(effectiveTimeout(for: raw)) {
                try await cleaner.clean(SpokenPunctuation.applyLineBreaks(raw), level: level, context: context)
            }
            outcome.llmMs = ms(since: t1)
            var cleaned = ListDetector.restoreLeadIn(ListDetector.repairNumbering(OutputSanitizer.sanitize(out, raw: raw)), raw: raw)
            let askedForLines = SpokenPunctuation.applyLineBreaks(raw).contains("\n") || ListDetector.isEnumeration(raw)
            if context.category != .email { cleaned = Greeting.joinOutsideEmail(cleaned) }
            if !askedForLines && context.category != .email && cleaned.contains("\n") {
                cleaned = ListDetector.flattenUnrequested(cleaned)
            }
            if cleaned.isEmpty || OutputSanitizer.looksLikeAnswer(cleaned, raw: raw) {
                outcome.usedFallback = true
                outcome.fallbackReason = cleaned.isEmpty ? "empty cleanup" : "cleanup added content"
                return fallback
            }
            return cleaned
        } catch {
            outcome.llmMs = ms(since: t1)
            outcome.usedFallback = true
            outcome.fallbackReason = error.localizedDescription
            return fallback
        }
    }
}


/// Email layout only belongs in email: "Hey Sam,\n\nI was…" → "Hey Sam, I was…".
public enum Greeting {
    public static func joinOutsideEmail(_ input: String) -> String {
        var text = input
        let joined = text.replacingOccurrences(of: "^((?:hi|hey|hello|dear|yo|hiya|morning|good morning)\\b[^\\n]{0,30},)\\n+(?=\\S)",
                                               with: "$1 ", options: [.regularExpression, .caseInsensitive])
        if joined != text, let comma = joined.firstIndex(of: ",") {
            // "Hey Sam, Are you free?" → "Hey Sam, are you free?" for ordinary sentence openers.
            let rest = joined[joined.index(after: comma)...].drop(while: { $0 == " " })
            let firstWord = rest.prefix(while: { $0.isLetter || $0 == "'" })
            let openers: Set<String> = ["are", "is", "can", "could", "would", "will", "do", "did", "does", "have", "has",
                                        "how", "what", "when", "where", "why", "just", "thanks", "thank", "so", "quick",
                                        "hope", "let's", "we", "you", "it", "the", "this", "that", "sorry", "great", "good"]
            if openers.contains(firstWord.lowercased()) {
                text = String(joined[...comma]) + " " + firstWord.lowercased() + rest.dropFirst(firstWord.count)
            } else {
                text = joined
            }
        }
            return text
    }
}

/// Deterministic language variants.
public enum LanguageRules {
    public static func apply(_ text: String, language: String?, variant: LanguageVariant, isCodeEditor: Bool) -> String {
        var s = text
        if variant == .deCH { s = s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS") }
        if language == "fr" && !isCodeEditor {
            // French typography: narrow no-break space before ; : ! ? and inside « ».
            s = s.replacingOccurrences(of: "\\s*([;:!?»])", with: "\u{202F}$1", options: .regularExpression)
                 .replacingOccurrences(of: "«\\s*", with: "«\u{202F}", options: .regularExpression)
            // …but not inside URLs/times like "https://" or "12:30".
            s = s.replacingOccurrences(of: "(\\w)\u{202F}(:)(?=//|\\d)", with: "$1$2", options: .regularExpression)
        }
        return s
    }
}

/// Makes the dictation fit where the cursor is: mid-sentence continuation
/// starts lowercase, and spacing joins cleanly with the surrounding text.
public enum Continuation {
    public static func apply(_ text: String, before: String?, after: String?, protectedWords: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        if let before, !before.isEmpty {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let midSentence = trimmed.last.map { !".!?:\n".contains($0) } ?? false
            if midSentence && !s.contains("\n") {
                s = StyleRules.lowercaseSentenceStarts(s, protected: protectedWords, firstOnly: true)
            }
            if let b = before.last, !b.isWhitespace, !"(\"'“‘/".contains(b), let f = s.first, f.isLetter || f.isNumber {
                s = " " + s
            }
        }
        if let after, let a = after.first, a.isLetter || a.isNumber, let l = s.last, !l.isWhitespace {
            s += " "
        }
        return s
    }
}

func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

public func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw QuothError.timeout
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

public enum AudioLevel {
    public static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
