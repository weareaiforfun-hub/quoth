import Foundation

/// Usage insights, computed from daily aggregates that survive history retention.
public struct DayStats: Equatable, Sendable {
    public var day: String          // yyyy-MM-dd (local)
    public var words: Int
    public var seconds: Double
    public var dictations: Int
    public init(day: String, words: Int, seconds: Double, dictations: Int) {
        self.day = day; self.words = words; self.seconds = seconds; self.dictations = dictations
    }
}

public struct Insights: Equatable, Sendable {
    public var totalWords = 0
    public var totalSeconds = 0.0
    public var dictations = 0
    public var currentStreak = 0
    public var longestStreak = 0
    public var topApps: [(app: String, words: Int)] = []
    public var days: [String: Int] = [:]

    public init() {}

    public static func == (a: Insights, b: Insights) -> Bool {
        a.totalWords == b.totalWords && a.totalSeconds == b.totalSeconds && a.dictations == b.dictations
            && a.currentStreak == b.currentStreak && a.longestStreak == b.longestStreak && a.days == b.days
            && a.topApps.map(\.app) == b.topApps.map(\.app) && a.topApps.map(\.words) == b.topApps.map(\.words)
    }

    /// Words per minute of speaking.
    public var wpm: Int { totalSeconds > 0 ? Int((Double(totalWords) / (totalSeconds / 60)).rounded()) : 0 }

    /// Minutes saved versus typing at 40 WPM.
    public var minutesSaved: Int { max(0, Int((Double(totalWords) / 40 - totalSeconds / 60).rounded())) }

    /// The "Your Voice" profile unlocks at 2,000 words.
    public var voiceUnlocked: Bool { totalWords >= 2000 }

    public static func compute(days: [DayStats], apps: [(String, Int)], today: Date = Date(), calendar: Calendar = .current) -> Insights {
        var i = Insights()
        for d in days {
            i.totalWords += d.words
            i.totalSeconds += d.seconds
            i.dictations += d.dictations
            if d.words > 0 { i.days[d.day] = d.words }
        }
        i.topApps = apps.sorted { $0.1 > $1.1 }.prefix(6).map { (app: $0.0, words: $0.1) }

        // Streaks: consecutive days with at least one dictation.
        let active = Set(i.days.keys)
        var cursor = calendar.startOfDay(for: today)
        // A streak is still "current" if today has no dictation yet but yesterday did.
        if !active.contains(dayKey(cursor, calendar)) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        while active.contains(dayKey(cursor, calendar)) {
            i.currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        let sorted = active.compactMap { dayDate($0, calendar) }.sorted()
        var run = 0
        var prev: Date?
        for d in sorted {
            if let p = prev, calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            i.longestStreak = max(i.longestStreak, run)
            prev = d
        }
        return i
    }

    public static func dayKey(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dayDate(_ key: String, _ calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// Deterministic parts of the "Your Voice" profile.
public struct VoiceProfile: Equatable, Sendable {
    public var averageWordsPerDictation: Int
    public var averageSentenceLength: Int
    public var questionShare: Int      // % of sentences that are questions
    public var exclamationShare: Int
    public var topWords: [String]

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are", "was", "were", "be",
        "it", "this", "that", "i", "you", "we", "they", "he", "she", "my", "your", "our", "at", "as", "so", "if", "do",
        "can", "will", "just", "have", "has", "not", "me", "us", "them", "from", "by", "about", "what", "there", "would",
        "could", "should", "i'm", "it's", "let's", "that's", "don't", "all", "get", "like", "then", "also", "some",
    ]

    public static func compute(_ texts: [String]) -> VoiceProfile {
        let all = texts.joined(separator: " ")
        let sentences = all.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let words = all.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        var counts: [String: Int] = [:]
        for w in words where w.count > 2 && !stopwords.contains(w) { counts[w, default: 0] += 1 }
        let q = all.filter { $0 == "?" }.count
        let e = all.filter { $0 == "!" }.count
        return VoiceProfile(
            averageWordsPerDictation: texts.isEmpty ? 0 : words.count / texts.count,
            averageSentenceLength: sentences.isEmpty ? 0 : words.count / sentences.count,
            questionShare: sentences.isEmpty ? 0 : q * 100 / sentences.count,
            exclamationShare: sentences.isEmpty ? 0 : e * 100 / sentences.count,
            topWords: counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10).map(\.key))
    }

    public static func llmMessages(samples: [String]) -> [ChatMessage] {
        [ChatMessage(role: "system", content: """
            You describe how a person communicates, based on samples of what they dictated. Write 4–6 short bullet points \
            about their tone, formality, sentence style, recurring topics and habits, addressed to them ("You…"). \
            Be specific and kind. No preamble.
            """),
         ChatMessage(role: "user", content: samples.prefix(60).map { "- \($0)" }.joined(separator: "\n"))]
    }
}
