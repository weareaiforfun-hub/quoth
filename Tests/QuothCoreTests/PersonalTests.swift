import Foundation
import Testing
@testable import QuothCore

@Suite struct DictionaryTests {
    let entries = [
        DictionaryEntry(spoken: "cube control", replacement: "kubectl"),
        DictionaryEntry(spoken: "control", replacement: "CONTROL"),
        DictionaryEntry(word: "Kubernetes"),
        DictionaryEntry(spoken: "can", replacement: "CAN-bus"),
    ]

    @Test func replacementKeepsSavedCapitalisation() {
        #expect(TextRules.applyDictionary("I love cube control.", entries: entries).0 == "I love kubectl.")
        #expect(TextRules.applyDictionary("CUBE CONTROL rocks", entries: entries).0 == "kubectl rocks")
    }

    @Test func longestPhraseWins() {
        // "control" must not fire inside the already-replaced "cube control"
        #expect(TextRules.applyDictionary("cube control and control", entries: entries).0 == "kubectl and CONTROL")
    }

    @Test func wholeWordsOnly() {
        #expect(TextRules.applyDictionary("remote controls", entries: entries).0 == "remote controls")
    }

    @Test func possessivesMatchContractionsDont() {
        #expect(TextRules.applyDictionary("cube control's output", entries: entries).0 == "kubectl's output")
        #expect(TextRules.applyDictionary("I can't go", entries: entries).0 == "I can't go")
    }

    @Test func wordEntriesFixCasing() {
        let (out, fired) = TextRules.applyDictionary("deploy to kubernetes today", entries: entries)
        #expect(out == "deploy to Kubernetes today")
        #expect(fired.count == 1)
        #expect(TextRules.applyDictionary("Kubernetes ok", entries: entries).1.isEmpty)
    }

    @Test func validation() {
        var p = PersonalData()
        p.dictionary = [DictionaryEntry(word: "Alex")]
        #expect(p.validate(DictionaryEntry(word: "  ")) == .empty)
        #expect(p.validate(DictionaryEntry(word: "!!!")) == .symbolsOnly)
        #expect(p.validate(DictionaryEntry(word: String(repeating: "a", count: 61))) == .tooLong)
        #expect(p.validate(DictionaryEntry(word: "alex")) == .duplicate)
        #expect(p.validate(DictionaryEntry(word: "Quoth")) == nil)
    }

    @Test func vocabularyPrefersStarredAndUsed() {
        var p = PersonalData()
        var a = DictionaryEntry(word: "Alpha"); a.uses = 1
        var b = DictionaryEntry(word: "Beta"); b.uses = 9
        let c = DictionaryEntry(word: "Gamma", starred: true)
        p.dictionary = [a, b, c]
        #expect(p.vocabulary() == ["Gamma", "Beta", "Alpha"])
        #expect(p.vocabulary(budget: 14) == ["Gamma", "Beta"])
    }

    @Test func persistsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var p = PersonalData()
        p.dictionary = [DictionaryEntry(word: "Alex")]
        p.snippets = [Snippet(trigger: "my email", expansion: "a@b.c")]
        p.styles[.email] = .casual
        PersonalStore.save(p, to: url)
        #expect(PersonalStore.load(from: url) == p)
    }
}

@Suite struct SnippetTests {
    let snippets = [
        Snippet(trigger: "my calendar", expansion: "https://cal.com/alex"),
        Snippet(trigger: "my calendar link", expansion: "LINK"),
        Snippet(trigger: "sig", expansion: "Best,\nAlex"),
    ]

    @Test func spokenAloneIgnoresCaseAndPunctuation() {
        #expect(TextRules.expandSnippets("My calendar.", snippets: snippets).0 == "https://cal.com/alex")
        #expect(TextRules.snippetSpokenAlone("MY CALENDAR LINK!", snippets: snippets)?.expansion == "LINK")
    }

    @Test func insideSentence() {
        #expect(TextRules.expandSnippets("Here is my calendar link, enjoy.", snippets: snippets).0 == "Here is LINK, enjoy.")
        #expect(TextRules.expandSnippets("Book via my calendar.", snippets: snippets).0 == "Book via https://cal.com/alex.")
    }

    @Test func cannotTouchLetters() {
        #expect(TextRules.expandSnippets("design signals", snippets: snippets).0 == "design signals")
    }
}

@Suite struct StyleTests {
    @Test func categories() {
        #expect(StyleCategory.detect(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .work)
        #expect(StyleCategory.detect(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - Gmail") == .email)
        #expect(StyleCategory.detect(bundleID: "com.google.Chrome", windowTitle: "Hacker News") == .other)
        #expect(StyleCategory.detect(bundleID: "com.apple.MobileSMS", windowTitle: nil) == .personal)
    }

    @Test func formalAddsMissingPeriod() {
        #expect(StyleRules.apply("Send it to Alex", tone: .formal, category: .other, hasSelection: false) == "Send it to Alex.")
        #expect(StyleRules.apply("Send it to Alex", tone: .formal, category: .other, hasSelection: false, rawTarget: true) == "Send it to Alex")
        #expect(StyleRules.apply("Ok", tone: .formal, category: .other, hasSelection: false) == "Ok")
        #expect(StyleRules.apply("1. A\n2. B", tone: .formal, category: .other, hasSelection: false) == "1. A\n2. B")
    }

    @Test func formalKeepsPeriods() {
        #expect(StyleRules.apply("See you soon.", tone: .formal, category: .personal, hasSelection: false) == "See you soon.")
    }

    @Test func casualStripsFinalPeriod() {
        #expect(StyleRules.apply("See you soon. Bring snacks.", tone: .casual, category: .work, hasSelection: false) == "See you soon. Bring snacks")
        #expect(StyleRules.apply("Really?", tone: .casual, category: .work, hasSelection: false) == "Really?")
        #expect(StyleRules.apply("Wait...", tone: .casual, category: .work, hasSelection: false) == "Wait")
    }

    @Test func veryCasualLowercases() {
        let out = StyleRules.apply("Hey Sam. I think NASA is cool. Alex agrees.", tone: .veryCasual, category: .personal,
                                   hasSelection: false, protectedWords: ["Alex"])
        #expect(out == "hey Sam. I think NASA is cool. Alex agrees")
    }

    @Test func excitedOnlyStripsShortMessages() {
        #expect(StyleRules.apply("On my way.", tone: .excited, category: .personal, hasSelection: false) == "On my way")
        #expect(StyleRules.apply("On my way.", tone: .excited, category: .email, hasSelection: false) == "On my way.")
        #expect(StyleRules.apply("A. B. C.", tone: nil, category: .work, hasSelection: false) == "A. B. C.")
    }

    @Test func neverWhenSelectionOrMultiline() {
        #expect(StyleRules.apply("Done.", tone: .casual, category: .work, hasSelection: true) == "Done.")
        #expect(StyleRules.apply("1. A\n2. B.", tone: .casual, category: .work, hasSelection: false) == "1. A\n2. B.")
    }
}

@Suite struct ContinuationTests {
    @Test func midSentenceLowercasesAndSpaces() {
        #expect(Continuation.apply("Then we ship.", before: "First we test,", after: nil) == " then we ship.")
        #expect(Continuation.apply("Then we ship.", before: "Done. ", after: nil) == "Then we ship.")
        #expect(Continuation.apply("I agree.", before: "and", after: nil) == " I agree.")
        #expect(Continuation.apply("hello", before: nil, after: "world") == "hello ")
    }
}

@Suite struct AutoLearnTests {
    let common: (String) -> Bool = { ["the", "deploy", "to", "today", "apple", "with", "call", "cube", "or", "nettis"].contains($0) }

    @Test func learnsCorrectedName() {
        let c = AutoLearn.candidates(pasted: "Call with Aleks today.", before: "Notes: Call with Aleks today.",
                                     after: "Notes: Call with Alex today.", isCommonWord: common, known: [], deleted: [])
        #expect(c == ["Alex"])
    }

    @Test func multiWordToOne() {
        let c = AutoLearn.candidates(pasted: "deploy to cube or nettis", before: "deploy to cube or nettis",
                                     after: "deploy to Kubernetes", isCommonWord: common, known: [], deleted: [])
        #expect(c == ["Kubernetes"])
    }

    @Test func skipsRewritesCommonWordsAndDeleted() {
        // Unrelated rewrite (low similarity)
        #expect(AutoLearn.candidates(pasted: "call Aleks", before: "call Aleks", after: "call Bob",
                                     isCommonWord: common, known: [], deleted: []).isEmpty)
        // Common word
        #expect(AutoLearn.candidates(pasted: "an aple", before: "an aple", after: "an apple",
                                     isCommonWord: common, known: [], deleted: []).isEmpty)
        // Previously deleted
        #expect(AutoLearn.candidates(pasted: "Aleks", before: "Aleks", after: "Alex",
                                     isCommonWord: common, known: [], deleted: ["alex"]).isEmpty)
        // Edits outside the pasted text
        #expect(AutoLearn.candidates(pasted: "hello", before: "Aleks hello", after: "Alex hello",
                                     isCommonWord: common, known: [], deleted: []).isEmpty)
        // URLs, numbers, acronyms
        #expect(!AutoLearn.isLearnable("https://x.com", isCommonWord: common))
        #expect(!AutoLearn.isLearnable("12:30", isCommonWord: common))
        #expect(!AutoLearn.isLearnable("PDF", isCommonWord: common))
        #expect(AutoLearn.isLearnable("iPhone", isCommonWord: { _ in true }))
    }

    @Test func gainBoostsQuietAudioOnly() {
        let quiet: [Float] = [0.1, -0.1, 0.02]
        #expect(abs(AudioGain.normalise(quiet)[0] - 0.7) < 0.001)
        #expect(abs(AudioGain.normalise([0.01, 0])[0] - 0.1) < 0.001)  // gain capped at 10x
        let loud: [Float] = [0.6, -0.5]
        #expect(AudioGain.normalise(loud) == loud)
    }
}

@Suite struct DevFormattingTests {
    @Test func filenames() {
        #expect(DevFormatting.spokenFilenames("check index dot ts please") == "check index.ts please")
        #expect(DevFormatting.spokenFilenames("open the dot env file") == "open the .env file")
    }

    @Test func tagging() {
        #expect(DevFormatting.tagFiles("Check index.ts for bugs.") == "Check @index.ts for bugs.")
        #expect(DevFormatting.tagFiles("Look at main.py and tag utils.ts.") == "Look @main.py and @utils.ts.")
        #expect(DevFormatting.tagFiles("Tag my python script", candidates: ["my_python_script.py"]) == "@my_python_script.py")
        #expect(DevFormatting.tagFiles("Already @index.ts") == "Already @index.ts")
    }

    @Test func identifiers() {
        let ids = DevFormatting.identifiers(in: "let userId = fetch_user(); class HttpClient {} normal words")
        #expect(ids == ["userId", "fetch_user", "HttpClient"])
        #expect(DevFormatting.applyIdentifiers("pass the user ID to fetch user", identifiers: ids) == "pass the userId to fetch_user")
    }
}

@Suite struct ProcessTests {
    struct Echo: Cleaner {
        func clean(_ raw: String, level: CleanupLevel, context: CleanupContext) async throws -> String { raw }
    }

    @Test func fullDeterministicChain() async throws {
        var p = PersonalData()
        p.dictionary = [DictionaryEntry(spoken: "cube control", replacement: "kubectl")]
        p.snippets = [Snippet(trigger: "my link", expansion: "https://x.y")]
        let pipe = DictationPipeline(transcriber: StubTranscriber(text: ""), cleaner: Echo(), llmTimeout: 1)
        var o = DictationOutcome(raw: "")
        let ctx = CleanupContext(category: .work, tone: .casual)
        let out = try await pipe.process(raw: "I use cube control, see my link.", level: .light, context: ctx, personal: p, outcome: &o)
        #expect(out == "I use kubectl, see https://x.y")
        #expect(o.firedEntries.count == 1 && o.firedSnippets.count == 1)
    }

    /// Simulates an LLM that paraphrases everything except placeholder tokens.
    struct Paraphraser: Cleaner {
        func clean(_ raw: String, level: CleanupLevel, context: CleanupContext) async throws -> String {
            raw.replacingOccurrences(of: "you can book", with: "Feel free to book")
        }
    }

    @Test func snippetTriggersAreShieldedFromLLM() async throws {
        var p = PersonalData()
        p.snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.com/a")]
        let pipe = DictationPipeline(transcriber: StubTranscriber(text: ""), cleaner: Paraphraser(), llmTimeout: 1)
        var o = DictationOutcome(raw: "")
        let out = try await pipe.process(raw: "you can book here my calendar link", level: .light, context: .init(), personal: p, outcome: &o)
        #expect(out == "Feel free to book here https://cal.com/a")
        #expect(o.firedSnippets == [p.snippets[0].id])
    }

    @Test func droppedTokenFallsBack() async throws {
        var p = PersonalData()
        p.snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.com/a")]
        let pipe = DictationPipeline(transcriber: StubTranscriber(text: ""), cleaner: StubCleaner(output: "Book here."), llmTimeout: 1)
        var o = DictationOutcome(raw: "")
        let out = try await pipe.process(raw: "book here my calendar link", level: .light, context: .init(), personal: p, outcome: &o)
        #expect(out == "Book here https://cal.com/a.")
        #expect(o.fallbackReason == "cleanup dropped a snippet")
    }

    @Test func greetingJoinedOutsideEmail() async throws {
        let pipe = DictationPipeline(transcriber: StubTranscriber(text: ""), cleaner: StubCleaner(output: "Hey Sam,\n\nAre you free?"), llmTimeout: 1)
        var o = DictationOutcome(raw: "")
        #expect(try await pipe.process(raw: "hey sam are you free", level: .light, context: .init(category: .personal), personal: .init(), outcome: &o) == "Hey Sam, are you free?")
        #expect(try await pipe.process(raw: "hey sam are you free", level: .light, context: .init(category: .email), personal: .init(), outcome: &o) == "Hey Sam,\n\nAre you free?")
    }

    @Test func snippetAloneSkipsLLM() async throws {
        var p = PersonalData()
        p.snippets = [Snippet(trigger: "sig", expansion: "Best,\nAlex")]
        let pipe = DictationPipeline(transcriber: StubTranscriber(text: ""), cleaner: StubCleaner(output: "WRONG"), llmTimeout: 1)
        var o = DictationOutcome(raw: "")
        #expect(try await pipe.process(raw: "Sig.", level: .light, context: .init(), personal: p, outcome: &o) == "Best,\nAlex")
    }
}

@Suite struct LanguageTests {
    struct Detecting: Transcriber, LanguageDetecting {
        let detected: String?
        func detectLanguage(wav: Data) async throws -> String? { detected }
        func transcribe(wav: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
            TranscriptionResult(text: "lang=\(language ?? "auto")")
        }
    }
    let speech = [Float](repeating: 0.1, count: 1600)

    @Test func pinnedSetConstrainsDetection() async throws {
        let p1 = DictationPipeline(transcriber: Detecting(detected: "de"), cleaner: nil, llmTimeout: 1)
        let o1 = try await p1.run(samples: speech, level: .none, languages: ["en", "de"], context: .init())
        #expect(o1.raw == "lang=de" && o1.detectedOutsideSet == nil)
        let p2 = DictationPipeline(transcriber: Detecting(detected: "uk"), cleaner: nil, llmTimeout: 1)
        let o2 = try await p2.run(samples: speech, level: .none, languages: ["en", "ru"], context: .init())
        #expect(o2.raw == "lang=en" && o2.detectedOutsideSet == "uk")
        let o3 = try await p2.run(samples: speech, level: .none, languages: ["fr"], context: .init())
        #expect(o3.raw == "lang=fr")
        let o4 = try await p2.run(samples: speech, level: .none, languages: [], context: .init())
        #expect(o4.raw == "lang=auto")
    }

    @Test func variants() {
        #expect(LanguageRules.apply("Straße groß", language: "de", variant: .deCH, isCodeEditor: false) == "Strasse gross")
        #expect(LanguageRules.apply("Vraiment ? Oui !", language: "fr", variant: .none, isCodeEditor: false) == "Vraiment\u{202F}? Oui\u{202F}!")
        #expect(LanguageRules.apply("Voir https://x.fr à 12:30 !", language: "fr", variant: .none, isCodeEditor: false) == "Voir https://x.fr à 12:30\u{202F}!")
        #expect(LanguageRules.apply("a ? b", language: "fr", variant: .none, isCodeEditor: true) == "a ? b")
        #expect(Languages.code(forWhisperName: "english") == "en")
        #expect(Languages.code(forWhisperName: "castilian") == "es")
    }

    @Test func legacySettingsMigrate() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"language":"de"}"#.utf8))
        #expect(s.languages == ["de"])
    }
}
