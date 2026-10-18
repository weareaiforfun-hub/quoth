import Foundation
import SQLite3

public struct DictationRecord: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case ok, failed, empty }

    public var id: String
    public var createdAt: Date
    public var raw: String
    public var final: String
    public var appName: String?
    public var appBundleID: String?
    public var duration: Double
    public var words: Int
    public var status: Status
    public var error: String?
    public var audioPath: String?
    public var asrMs: Int
    public var llmMs: Int

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), raw: String = "", final: String = "",
                appName: String? = nil, appBundleID: String? = nil, duration: Double = 0, words: Int = 0,
                status: Status = .ok, error: String? = nil, audioPath: String? = nil, asrMs: Int = 0, llmMs: Int = 0) {
        self.id = id; self.createdAt = createdAt; self.raw = raw; self.final = final
        self.appName = appName; self.appBundleID = appBundleID; self.duration = duration; self.words = words
        self.status = status; self.error = error; self.audioPath = audioPath; self.asrMs = asrMs; self.llmMs = llmMs
    }
}

/// Per-device dictation history in SQLite (system libsqlite3, no dependencies).
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = AppPaths.historyDB) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw QuothError.badResponse("cannot open \(url.path)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS dictations (
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, raw TEXT NOT NULL, final TEXT NOT NULL,
              app_name TEXT, app_bundle TEXT, duration REAL NOT NULL, words INTEGER NOT NULL,
              status TEXT NOT NULL, error TEXT, audio_path TEXT, asr_ms INTEGER NOT NULL, llm_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at DESC);
            CREATE TABLE IF NOT EXISTS stats_daily (day TEXT PRIMARY KEY, words INTEGER NOT NULL, seconds REAL NOT NULL, dictations INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS stats_apps (app TEXT PRIMARY KEY, words INTEGER NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    public func upsert(_ r: DictationRecord) {
        lock.withLock {
            let sql = """
                INSERT OR REPLACE INTO dictations
                (id, created_at, raw, final, app_name, app_bundle, duration, words, status, error, audio_path, asr_ms, llm_ms)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            bind(st, 1, r.id); sqlite3_bind_double(st, 2, r.createdAt.timeIntervalSince1970)
            bind(st, 3, r.raw); bind(st, 4, r.final); bind(st, 5, r.appName); bind(st, 6, r.appBundleID)
            sqlite3_bind_double(st, 7, r.duration); sqlite3_bind_int64(st, 8, Int64(r.words))
            bind(st, 9, r.status.rawValue); bind(st, 10, r.error); bind(st, 11, r.audioPath)
            sqlite3_bind_int64(st, 12, Int64(r.asrMs)); sqlite3_bind_int64(st, 13, Int64(r.llmMs))
            sqlite3_step(st)
        }
    }

    /// Adds a dictation to the insights aggregates. Only counts are kept (no text), and they
    /// survive history deletion so streaks and totals stay meaningful.
    public func recordStats(words: Int, seconds: Double, app: String?, at date: Date = Date()) {
        lock.withLock {
            let day = Insights.dayKey(date)
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                INSERT INTO stats_daily (day, words, seconds, dictations) VALUES (?, ?, ?, 1)
                ON CONFLICT(day) DO UPDATE SET words = words + excluded.words, seconds = seconds + excluded.seconds, dictations = dictations + 1
                """, -1, &st, nil) == SQLITE_OK {
                bind(st, 1, day); sqlite3_bind_int64(st, 2, Int64(words)); sqlite3_bind_double(st, 3, seconds)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            guard let app, !app.isEmpty else { return }
            if sqlite3_prepare_v2(db, "INSERT INTO stats_apps (app, words) VALUES (?, ?) ON CONFLICT(app) DO UPDATE SET words = words + excluded.words",
                                  -1, &st, nil) == SQLITE_OK {
                bind(st, 1, app); sqlite3_bind_int64(st, 2, Int64(words))
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
        }
    }

    public func insights(today: Date = Date()) -> Insights {
        lock.withLock {
            var days: [DayStats] = []
            var apps: [(String, Int)] = []
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT day, words, seconds, dictations FROM stats_daily", -1, &st, nil) == SQLITE_OK {
                while sqlite3_step(st) == SQLITE_ROW {
                    days.append(DayStats(day: text(st, 0) ?? "", words: Int(sqlite3_column_int64(st, 1)),
                                         seconds: sqlite3_column_double(st, 2), dictations: Int(sqlite3_column_int64(st, 3))))
                }
            }
            sqlite3_finalize(st)
            if sqlite3_prepare_v2(db, "SELECT app, words FROM stats_apps", -1, &st, nil) == SQLITE_OK {
                while sqlite3_step(st) == SQLITE_ROW { apps.append((text(st, 0) ?? "", Int(sqlite3_column_int64(st, 1)))) }
            }
            sqlite3_finalize(st)
            return Insights.compute(days: days, apps: apps, today: today)
        }
    }

    public func recent(limit: Int = 200) -> [DictationRecord] {
        lock.withLock {
            var st: OpaquePointer?
            let sql = "SELECT id, created_at, raw, final, app_name, app_bundle, duration, words, status, error, audio_path, asr_ms, llm_ms FROM dictations ORDER BY created_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, Int64(limit))
            var out: [DictationRecord] = []
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(DictationRecord(
                    id: text(st, 0) ?? "", createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                    raw: text(st, 2) ?? "", final: text(st, 3) ?? "", appName: text(st, 4), appBundleID: text(st, 5),
                    duration: sqlite3_column_double(st, 6), words: Int(sqlite3_column_int64(st, 7)),
                    status: DictationRecord.Status(rawValue: text(st, 8) ?? "") ?? .ok, error: text(st, 9),
                    audioPath: text(st, 10), asrMs: Int(sqlite3_column_int64(st, 11)), llmMs: Int(sqlite3_column_int64(st, 12))))
            }
            return out
        }
    }

    public func delete(id: String) {
        if let r = recent(limit: 10_000).first(where: { $0.id == id }) { removeAudio(r.audioPath) }
        run("DELETE FROM dictations WHERE id = ?", id)
    }

    public func deleteAll() {
        for r in recent(limit: 100_000) { removeAudio(r.audioPath) }
        run("DELETE FROM dictations", nil)
    }

    /// Applies the retention policy: audio older than `audioMaxAge` is deleted;
    /// rows older than `rowMaxAge` (if set) are deleted with their audio.
    public func purge(audioMaxAge: TimeInterval, rowMaxAge: TimeInterval?, now: Date = Date()) {
        for r in recent(limit: 100_000) {
            let age = now.timeIntervalSince(r.createdAt)
            if let rowMaxAge, age > rowMaxAge {
                delete(id: r.id)
            } else if age > audioMaxAge, r.audioPath != nil {
                removeAudio(r.audioPath)
                var copy = r
                copy.audioPath = nil
                upsert(copy)
            }
        }
    }

    private func removeAudio(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func run(_ sql: String, _ arg: String?) {
        lock.withLock {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            if let arg { bind(st, 1, arg) }
            sqlite3_step(st)
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw QuothError.badResponse(msg)
        }
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(st, i, v, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }
}
