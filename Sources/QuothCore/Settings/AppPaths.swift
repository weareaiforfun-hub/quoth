import Foundation

public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Quoth", isDirectory: true))
    }

    public static var audio: URL { ensure(support.appendingPathComponent("audio", isDirectory: true)) }
    public static var models: URL { ensure(support.appendingPathComponent("models", isDirectory: true)) }
    public static var historyDB: URL { support.appendingPathComponent("history.sqlite") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
