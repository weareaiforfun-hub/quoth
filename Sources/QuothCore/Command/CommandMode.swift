import Foundation

/// Command Mode: a spoken instruction that edits, drafts, answers or searches.
public struct CommandResult: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        /// Replace the selection (or the whole short field) with `text`.
        case replace
        /// Insert `text` at the cursor (drafts, replies).
        case insert
        /// Show `text` as an answer; type nothing.
        case answer
        /// Open a web search for `text`.
        case search
    }

    public var action: Action
    public var text: String

    public init(action: Action, text: String) {
        self.action = action
        self.text = text
    }
}

public enum CommandMode {
    public static func messages(instruction: String, selection: String?, field: String?, appName: String?) -> [ChatMessage] {
        let system = """
        You are a voice command assistant inside a text editor. The user spoke an INSTRUCTION. You also get the \
        SELECTED text (may be empty) and the text of the FIELD the cursor is in (may be empty or truncated).

        Decide what the user wants and respond with a JSON object {"action": "...", "text": "..."}:
        - "replace": the user wants the SELECTED text changed (rewrite, shorten, translate, fix, reformat, turn into bullets…). \
        "text" is the complete replacement for the selection, nothing else.
        - "insert": the user wants new text written at the cursor (a draft, a reply, a sentence, a list). Use the FIELD as \
        context (e.g. the email thread you are replying to). "text" is only the new text.
        - "answer": the user asks a question (about the selection, the field, or anything). "text" is a short, direct answer.
        - "search": the user explicitly wants to search the web or look something up online. "text" is the search query.

        Always use exactly these two keys, e.g. {"action": "answer", "text": "A leap year has 366 days."}

        Rules: if there is no SELECTED text, never use "replace" unless the instruction clearly targets the whole field \
        ("rewrite this", "fix the grammar of this message"); then "text" replaces the whole FIELD. \
        Write in the language of the selection/field unless asked to translate. No markdown fences, no commentary, \
        no quotes around "text". Plain text with line breaks is fine.
        """
        var user = "INSTRUCTION: \(instruction)\n\nSELECTED:\n\(selection ?? "")\n\nFIELD:\n\((field ?? "").suffix(4000))"
        if let appName { user += "\n\nAPP: \(appName)" }
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }

    /// Parses the model's JSON; tolerates fences and missing fields.
    public static func parse(_ output: String, hasSelection: Bool) -> CommandResult? {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        }
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") { s = String(s[start...end]) }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var action = (obj["action"] as? String).flatMap { CommandResult.Action(rawValue: $0.lowercased()) }
        var text = obj["text"] as? String
        // Models sometimes answer {"answer": "..."} / {"insert": "..."} instead of {"action", "text"}.
        if text == nil {
            for a in CommandResult.Action.allCases { if let v = obj[a.rawValue] as? String { action = a; text = v; break } }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CommandResult(action: action ?? (hasSelection ? .replace : .insert), text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Deterministic shortcut for explicit web searches ("search for…", "google…", "look up…").
    public static func explicitSearch(_ instruction: String) -> String? {
        let pattern = "(?i)^\\s*(?:please\\s+)?(?:search(?:\\s+the\\s+web)?(?:\\s+for)?|google|look\\s+up|perplexity)\\s+(.+?)[.?!]?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
              let r = Range(m.range(at: 1), in: instruction) else { return nil }
        return String(instruction[r])
    }

    public static func searchURL(_ query: String) -> URL? {
        var c = URLComponents(string: "https://www.perplexity.ai/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}

/// Transforms: hotkey rewrites of selected text.
public enum Transforms {
    public static let polishID = "polish"
    public static let promptEngineerID = "prompt"

    public static func polishMessages(_ text: String, rules: PolishRules) -> [ChatMessage] {
        var r: [String] = []
        if rules.concise { r.append("Make it more concise: cut redundancy and filler.") }
        if rules.clarity { r.append("Reword for clarity where sentences are awkward or ambiguous.") }
        if rules.reorder { r.append("Reorder sentences so the text reads in a logical order.") }
        if rules.structure { r.append("Add structure (short paragraphs or a list) where it helps.") }
        if rules.maintainTone { r.append("Keep the author's tone and voice.") }
        if rules.clarifyMainPoint { r.append("Make the main point clear up front.") }
        if rules.impact { r.append("Refine phrasing for impact.") }
        r += rules.custom.filter { !$0.isEmpty }
        let system = """
        You polish a piece of writing. Apply these rules:
        \(r.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        Never add facts or change the meaning. Keep the same language. Output only the polished text, no preamble.
        """
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: text)]
    }

    public static func promptEngineerMessages(_ text: String) -> [ChatMessage] {
        let system = """
        Turn the user's rambling, spoken-style request into a clear, well-structured prompt for an AI assistant.
        - Keep every requirement, constraint and detail they mention.
        - NEVER add requirements, file types, edge cases, examples or features they did not mention. Each bullet must come from their words.
        - Format: one sentence stating the goal, then a "Requirements:" bulleted list. Add a "Context:" section only if they gave background.
        - Write in the user's voice ("Write a…", "I want…"). Output only the prompt.
        """
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: text)]
    }

    public static func customMessages(_ text: String, transform: TransformPrompt) -> [ChatMessage] {
        var system = """
        Rewrite the user's text following this instruction: \(transform.instruction)
        Keep the meaning and the language. Output only the rewritten text, no preamble.
        """
        let samples = transform.samples.filter { !$0.isEmpty }.prefix(5)
        if !samples.isEmpty {
            system += "\n\nMatch the voice and style of these writing samples:\n"
                + samples.enumerated().map { "--- Sample \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n")
        }
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: text)]
    }

    /// Spec: transforms accept 1–1,000 words.
    public static func validInput(_ text: String) -> Bool {
        let n = OutputSanitizer.wordCount(text)
        return n >= 1 && n <= 1000
    }
}

/// Word-level diff for "View Diff".
public enum WordDiff {
    public enum Part: Equatable, Sendable {
        case same(String), removed(String), added(String)
    }

    public static func diff(_ a: String, _ b: String) -> [Part] {
        let x = tokens(a), y = tokens(b)
        let xk = x.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let yk = y.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // LCS table (inputs are ≤1,000 words, so O(n·m) is fine).
        var lcs = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = xk[i] == yk[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var parts: [Part] = []
        func push(_ p: Part) {
            switch (parts.last, p) {
            case (.same(let s)?, .same(let t)): parts[parts.count - 1] = .same(s + t)
            case (.removed(let s)?, .removed(let t)): parts[parts.count - 1] = .removed(s + t)
            case (.added(let s)?, .added(let t)): parts[parts.count - 1] = .added(s + t)
            default: parts.append(p)
            }
        }
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, xk[i] == yk[j] { push(.same(y[j])); i += 1; j += 1 }
            else if j < y.count, i == x.count || lcs[i][j + 1] >= lcs[i + 1][j] { push(.added(y[j])); j += 1 }
            else { push(.removed(x[i])); i += 1 }
        }
        return parts
    }

    /// Words with their trailing whitespace, so joining parts reproduces the text.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace { inSpace = true; cur.append(ch) }
            else {
                if inSpace { out.append(cur); cur = ""; inSpace = false }
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
