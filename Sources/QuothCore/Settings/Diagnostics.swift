import Foundation

/// What "Copy diagnostics" collects. Deliberately no dictations, history, dictionary, snippets,
/// notes, API keys or file paths in your home folder: only versions, settings and engine state.
public struct DiagnosticsInput: Sendable {
    public var appVersion: String
    public var macOS: String
    public var hardware: String
    public var ramGB: Int
    public var freeDiskBytes: Int64?
    public var settings: Settings
    public var speechStatus: String
    public var textStatus: String
    public var permissions: [(name: String, granted: Bool)]
    public var downloads: [String]
    /// Engine logs by name; only error and warning lines are kept.
    public var logs: [(name: String, text: String)]

    public init(appVersion: String, macOS: String, hardware: String, ramGB: Int, freeDiskBytes: Int64?, settings: Settings,
                speechStatus: String, textStatus: String, permissions: [(name: String, granted: Bool)],
                downloads: [String], logs: [(name: String, text: String)]) {
        self.appVersion = appVersion; self.macOS = macOS; self.hardware = hardware; self.ramGB = ramGB
        self.freeDiskBytes = freeDiskBytes; self.settings = settings; self.speechStatus = speechStatus
        self.textStatus = textStatus; self.permissions = permissions; self.downloads = downloads; self.logs = logs
    }
}

public enum Diagnostics {
    public static func report(_ d: DiagnosticsInput, home: String = NSHomeDirectory()) -> String {
        let s = d.settings
        var header = "Quoth \(d.appVersion) · macOS \(d.macOS) · \(d.hardware) · \(d.ramGB) GB"
        if let free = d.freeDiskBytes { header += " · \(DownloadError.size(free)) free" }
        let speech = s.speechProvider == .local
            ? "this Mac, \(file(s.whisperModelPath)) (\(d.speechStatus))"
            : "cloud, \(host(s.cloudBaseURL)), \(s.cloudASRModel)"
        let text: String
        switch (s.textProvider, s.localTextEngine) {
        case (.cloud, _): text = "cloud, \(host(s.cloudBaseURL)), \(s.cloudLLMModel)"
        case (.local, .builtIn): text = "this Mac (built in), \(file(s.llamaModelPath)) (\(d.textStatus))"
        case (.local, .ollama): text = "Ollama, \(s.ollamaModel)"
        }
        let missing = s.missingLocalModels.isEmpty ? "none" : s.missingLocalModels.map(file).joined(separator: ", ")
        let languages = s.languages.isEmpty ? "auto" : s.languages.joined(separator: ",")
        let options = "Cleanup: \(s.cleanupLevel.rawValue) · hotkey \(s.hotkey.rawValue) · languages \(languages)"
            + " · variant \(s.languageVariant.rawValue) · context \(s.contextAwareness ? "on" : "off")"
        let permissions = d.permissions.map { "\($0.name) \($0.granted ? "yes" : "NO")" }.joined(separator: ", ")
        var lines: [String] = [header, "", "Speech: " + speech, "Text: " + text, "Missing models: " + missing,
                               options, "Permissions: " + permissions]
        if !d.downloads.isEmpty { lines.append("Downloads: " + d.downloads.joined(separator: "; ")) }
        for log in d.logs {
            let relevant = relevantLines(log.text)
            lines.append("")
            lines.append("\(log.name): " + (relevant.isEmpty ? "no errors" : ""))
            lines += relevant.map { "  " + $0 }
        }
        return redact(lines.joined(separator: "\n"), home: home)
    }

    /// The last error and warning lines of a log (engine logs can otherwise be long).
    public static func relevantLines(_ log: String, limit: Int = 15) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\b(error|fail(ed|ure)?|warn(ing)?|abort|unable|cannot|could not)\\b", options: .caseInsensitive)
        let lines = log.split(separator: "\n").map(String.init).filter {
            pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        return lines.suffix(limit).map { String($0.prefix(300)) }
    }

    /// Your home folder (and so your user name) never appears in the report.
    public static func redact(_ s: String, home: String) -> String {
        home.count > 1 ? s.replacingOccurrences(of: home, with: "~") : s
    }

    static func file(_ path: String) -> String { (path as NSString).lastPathComponent }
    static func host(_ url: String) -> String { URL(string: url)?.host ?? "custom server" }
}
