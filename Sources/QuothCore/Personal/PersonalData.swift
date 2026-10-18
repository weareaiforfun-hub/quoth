import Foundation

/// Dictionary entry: a spelling hint ("Kubernetes") or a replacement ("cube control" → "kubectl").
public struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case word, replacement }

    public var id = UUID()
    public var kind: Kind
    /// The word itself, or the spoken phrase for a replacement.
    public var phrase: String
    /// Output for a replacement entry.
    public var replacement: String?
    public var starred = false
    public var uses = 0
    public var autoLearned = false
    public var createdAt = Date()

    public init(word: String, starred: Bool = false, autoLearned: Bool = false) {
        kind = .word; phrase = word; self.starred = starred; self.autoLearned = autoLearned
    }

    public init(spoken: String, replacement: String) {
        kind = .replacement; phrase = spoken; self.replacement = replacement
    }

    /// The text this entry produces (what ASR/LLM should spell).
    public var output: String { kind == .word ? phrase : (replacement ?? phrase) }
}

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var trigger: String
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger; self.expansion = expansion
    }
}

/// A user-defined Transform prompt.
public struct TransformPrompt: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var instruction: String
    /// Up to 5 writing samples whose voice the output should match.
    public var samples: [String] = []

    public init(name: String, instruction: String, samples: [String] = []) {
        self.name = name; self.instruction = instruction; self.samples = samples
    }
}

public struct PolishRules: Codable, Equatable, Sendable {
    public var concise = true
    public var clarity = true
    public var reorder = false
    public var structure = false
    public var maintainTone = true
    public var clarifyMainPoint = false
    public var impact = false
    /// Up to 5 custom instructions (≤50 words each).
    public var custom: [String] = []
    public init() {}
}

/// Everything personal: dictionary, snippets, styles and transforms. Stored as one JSON file.
public struct PersonalData: Codable, Equatable, Sendable {
    public var dictionary: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    /// Words the user deleted; auto-learn never re-adds them.
    public var deletedWords: [String] = []
    public var styles = StylePrefs()
    public var polish = PolishRules()
    public var transforms: [TransformPrompt] = []
    /// Transform run on every dictation before paste: "polish", "prompt", or a custom transform UUID.
    public var autoApplyTransform: String?
    public var autoLearn = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PersonalData()
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? d.dictionary
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        deletedWords = try c.decodeIfPresent([String].self, forKey: .deletedWords) ?? d.deletedWords
        styles = try c.decodeIfPresent(StylePrefs.self, forKey: .styles) ?? d.styles
        polish = try c.decodeIfPresent(PolishRules.self, forKey: .polish) ?? d.polish
        transforms = try c.decodeIfPresent([TransformPrompt].self, forKey: .transforms) ?? d.transforms
        autoApplyTransform = try c.decodeIfPresent(String.self, forKey: .autoApplyTransform)
        autoLearn = try c.decodeIfPresent(Bool.self, forKey: .autoLearn) ?? d.autoLearn
    }

    /// Words to bias ASR toward: starred first, then most used, within a character budget.
    public func vocabulary(budget: Int = 600) -> [String] {
        let sorted = dictionary.sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.uses > $1.uses
        }
        var out: [String] = []
        var used = 0
        for e in sorted {
            let w = e.output
            if used + w.count + 2 > budget { break }
            if !out.contains(w) { out.append(w); used += w.count + 2 }
        }
        return out
    }

    public enum ValidationError: LocalizedError, Equatable {
        case empty, tooLong, symbolsOnly, duplicate
        public var errorDescription: String? {
            switch self {
            case .empty: "Can't be empty"
            case .tooLong: "60 characters at most"
            case .symbolsOnly: "Needs at least one letter or digit"
            case .duplicate: "Already in your dictionary"
            }
        }
    }

    /// Spec 2.3: ≤60 chars per field; reject empty, whitespace-only, symbol-only and duplicates.
    public func validate(_ entry: DictionaryEntry) -> ValidationError? {
        for field in [entry.phrase, entry.replacement].compactMap({ $0 }) {
            let t = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return .empty }
            if t.count > 60 { return .tooLong }
            if t.rangeOfCharacter(from: .alphanumerics) == nil { return .symbolsOnly }
        }
        if entry.kind == .replacement && (entry.replacement ?? "").isEmpty { return .empty }
        let key = entry.phrase.lowercased().trimmingCharacters(in: .whitespaces)
        if dictionary.contains(where: { $0.id != entry.id && $0.kind == entry.kind && $0.phrase.lowercased() == key }) {
            return .duplicate
        }
        return nil
    }
}

public enum PersonalStore {
    public static var url: URL { AppPaths.support.appendingPathComponent("personal.json") }

    public static func load(from url: URL = url) -> PersonalData {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(PersonalData.self, from: data) else { return PersonalData() }
        return p
    }

    public static func save(_ p: PersonalData, to url: URL = url) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
