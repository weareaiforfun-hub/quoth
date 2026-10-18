import Foundation

/// Developer features: spoken identifiers and @file tagging in AI IDEs.
public enum DevFormatting {
    public static let codeEditors: Set<String> = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",         // Windsurf
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "dev.zed.Zed", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.apple.dt.Xcode",
    ]
    /// IDEs whose chat attaches files via "@name".
    public static let fileTaggingEditors: Set<String> = ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

    static let extensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "go", "rs", "swift", "kt", "java", "c", "h", "cpp", "hpp",
        "cs", "php", "md", "mdx", "json", "yaml", "yml", "toml", "html", "css", "scss", "sql", "sh", "txt",
        "env", "lock", "xml", "vue", "svelte", "ipynb",
    ]

    /// "index dot ts" → "index.ts"; "dot env" → ".env". Applies to raw ASR text before cleanup in code editors.
    public static func spokenFilenames(_ text: String) -> String {
        var s = text
        // "dot env" (no base name) → ".env"
        s = s.replacingOccurrences(of: "(?i)\\bdot\\s+env\\b", with: ".env", options: .regularExpression)
        let exts = extensions.joined(separator: "|")
        s = s.replacingOccurrences(of: "(?i)\\b([A-Za-z0-9_-]+)\\s+dot\\s+(\(exts))\\b", with: "$1.$2", options: .regularExpression)
        return s
    }

    /// In Cursor/Windsurf chat, filenames become "@name.ext" so the IDE's autocomplete attaches them.
    /// A leading "tag", "at" or "@" is consumed. `candidates` (open files) map multi-word names.
    public static func tagFiles(_ text: String, candidates: [String] = []) -> String {
        var s = text
        // Multi-word names that match a known file: "my python script" → "@my_python_script.py"
        for file in candidates.sorted(by: { $0.count > $1.count }) {
            let base = (file as NSString).deletingPathExtension
            let spoken = base.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "[_.-]+", with: " ", options: .regularExpression)
            guard spoken.contains(" ") else { continue }
            let pattern = "(?i)\\b(?:(?:tag|at)\\s+)?" + NSRegularExpression.escapedPattern(for: spoken).replacingOccurrences(of: " ", with: "\\s+") + "\\b"
            s = s.replacingOccurrences(of: pattern, with: "@" + NSRegularExpression.escapedTemplate(for: file), options: .regularExpression)
        }
        let exts = extensions.joined(separator: "|")
        s = s.replacingOccurrences(of: "(?i)(?:\\b(?:tag|at)\\s+|@)?(?<![@\\w./])((?:[A-Za-z0-9_-]+)?\\.(?:\(exts)))\\b", with: "@$1", options: .regularExpression)
        return s
    }

    /// Identifiers visible in the editor: camelCase, PascalCase with a lowercase run, snake_case.
    public static func identifiers(in text: String, limit: Int = 300) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\b(?:[a-z]+(?:[A-Z][a-z0-9]*)+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\\b")
        var seen: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let w = (text as NSString).substring(with: m.range)
            if !seen.contains(w) { seen.append(w) }
            if seen.count >= limit { break }
        }
        return seen
    }

    /// "user id" → "userId" when `userId` is a visible identifier.
    public static func applyIdentifiers(_ text: String, identifiers: [String]) -> String {
        var s = text
        for id in identifiers.sorted(by: { $0.count > $1.count }) {
            let parts = id.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
            guard parts.count >= 2 else { continue }
            let pattern = "(?i)(?<![\\w])" + parts.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s-]+") + "(?![\\w])"
            s = s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: id), options: .regularExpression)
        }
        return s
    }
}
