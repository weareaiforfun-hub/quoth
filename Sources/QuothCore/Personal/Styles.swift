import Foundation

public enum StyleCategory: String, Codable, CaseIterable, Sendable {
    case personal, work, email, other

    public var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Everything else"
        }
    }

    public var allowedTones: [StyleTone] {
        switch self {
        case .personal: [.formal, .casual, .veryCasual, .excited]
        case .work, .email: [.formal, .casual, .excited]
        case .other: [.formal, .casual]
        }
    }

    var isMessaging: Bool { self == .personal || self == .work }

    private static let bundles: [String: StyleCategory] = [
        "com.apple.MobileSMS": .personal, "net.whatsapp.WhatsApp": .personal, "ru.keepcoder.Telegram": .personal,
        "org.telegram.desktop": .personal, "com.hnc.Discord": .personal, "org.whispersystems.signal-desktop": .personal,
        "com.facebook.archon": .personal, "com.facebook.archon.developerID": .personal,
        "com.tinyspeck.slackmacgap": .work, "com.microsoft.teams2": .work, "com.microsoft.teams": .work,
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.superhuman.electron": .email,
        "com.readdle.smartemail-Mac": .email, "it.bloop.airmail2": .email,
    ]

    private static let browserTitles: [(String, StyleCategory)] = [
        ("gmail", .email), ("outlook", .email), ("inbox", .email), ("superhuman", .email),
        ("slack", .work), ("linkedin", .work), ("teams", .work),
        ("whatsapp", .personal), ("messenger", .personal), ("instagram", .personal),
        ("discord", .personal), ("telegram", .personal),
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Picks the category from the app, or for browsers from the window title.
    public static func detect(bundleID: String?, windowTitle: String?) -> StyleCategory {
        if let b = bundleID, let c = bundles[b] { return c }
        if let b = bundleID, browsers.contains(b), let t = windowTitle?.lowercased() {
            for (key, c) in browserTitles where t.contains(key) { return c }
        }
        return .other
    }
}

public enum StyleTone: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual, excited

    public var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited"
        }
    }

    public var example: String {
        switch self {
        case .formal: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        case .excited: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!"
        }
    }
}

public struct StylePrefs: Codable, Equatable, Sendable {
    public var personal: StyleTone? = .casual
    public var work: StyleTone? = .casual
    public var email: StyleTone? = .formal
    public var other: StyleTone? = .formal
    public init() {}

    public subscript(_ c: StyleCategory) -> StyleTone? {
        get {
            switch c { case .personal: personal; case .work: work; case .email: email; case .other: other }
        }
        set {
            switch c { case .personal: personal = newValue; case .work: work = newValue; case .email: email = newValue; case .other: other = newValue }
        }
    }
}

/// Style = capitalisation, punctuation and spacing only, never word choice.
/// Done deterministically because LLMs follow these rules with low precision.
public enum StyleRules {
    public static func apply(_ text: String, tone: StyleTone?, category: StyleCategory, hasSelection: Bool,
                             protectedWords: [String] = [], rawTarget: Bool = false) -> String {
        guard !hasSelection, !text.isEmpty else { return text }
        var s = text
        // Formal prose always ends with punctuation (models and ASR sometimes drop the final period).
        if (tone == .formal || (tone == nil && !category.isMessaging)) && !rawTarget,
           let last = s.last, last.isLetter || last.isNumber, s.split(separator: " ").count >= 3, !s.contains("\n") {
            s += "."
        }
        let sentences = sentenceCount(s)
        let isMultiline = s.contains("\n")

        if tone == .veryCasual {
            s = lowercaseSentenceStarts(s, protected: protectedWords)
        }
        let stripLimit: Int? = switch tone {
        case .formal: 0
        case .casual: 10
        case .veryCasual: Int.max
        case .excited, nil: category.isMessaging ? 2 : 0
        }
        if let limit = stripLimit, limit > 0, sentences <= limit, !isMultiline {
            s = stripTrailingPeriod(s)
        }
        return s
    }

    static func sentenceCount(_ s: String) -> Int {
        max(1, s.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
    }

    /// Removes a final "." or "…"/"...", keeping "!" and "?".
    static func stripTrailingPeriod(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("...") { t.removeLast(3) } else if t.hasSuffix("…") || t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// "Very casual": no capitals at sentence starts, except "I", acronyms and dictionary words.
    static func lowercaseSentenceStarts(_ s: String, protected: [String], firstOnly: Bool = false) -> String {
        let keep = Set(protected)
        var out = ""
        var atStart = true
        var word = ""
        func flush() {
            if !word.isEmpty {
                if atStart {
                    let isAcronym = word.count > 1 && word == word.uppercased() && word.contains(where: \.isLetter)
                    let isI = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
                    if !isAcronym && !isI && !keep.contains(word) {
                        word = word.prefix(1).lowercased() + word.dropFirst()
                    }
                }
                out += word
                atStart = false
                word = ""
            }
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
                if ".!?\n".contains(ch) && !firstOnly { atStart = true }
            }
        }
        flush()
        return out
    }
}
