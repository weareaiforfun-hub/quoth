import Foundation

/// Scratchpad notes: RTF documents with automatic version history.
public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
}

public final class NotesStore: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()
    /// A new version is kept when the last one is older than this.
    public var versionInterval: TimeInterval = 120
    public var maxVersions = 20

    public init(dir: URL = AppPaths.support.appendingPathComponent("notes", isDirectory: true)) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("versions"), withIntermediateDirectories: true)
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).rtf") }
    private func versionsDir(_ id: String) -> URL { dir.appendingPathComponent("versions/\(id)", isDirectory: true) }

    public func list() -> [Note] {
        lock.withLock { readIndex() }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func create(title: String = "Untitled") -> Note {
        let n = Note(id: UUID().uuidString, title: title, createdAt: Date(), updatedAt: Date())
        lock.withLock {
            var idx = readIndex()
            idx.append(n)
            writeIndex(idx)
            FileManager.default.createFile(atPath: fileURL(n.id).path, contents: Data())
        }
        return n
    }

    public func content(_ id: String) -> Data? { try? Data(contentsOf: fileURL(id)) }

    /// Saves the note; the title becomes the first line of `plainText`.
    public func save(_ id: String, rtf: Data, plainText: String, now: Date = Date()) {
        lock.withLock {
            let url = fileURL(id)
            let old = try? Data(contentsOf: url)
            guard old != rtf else { return }
            try? rtf.write(to: url, options: .atomic)
            try? plainText.write(to: dir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
            snapshotIfDue(id, rtf: rtf, now: now)
            var idx = readIndex()
            if let i = idx.firstIndex(where: { $0.id == id }) {
                let first = plainText.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                idx[i].title = first.isEmpty ? "Untitled" : String(first.prefix(60))
                idx[i].updatedAt = now
                writeIndex(idx)
            }
        }
    }

    public func delete(_ id: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL(id))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).txt"))
            try? FileManager.default.removeItem(at: versionsDir(id))
            writeIndex(readIndex().filter { $0.id != id })
        }
    }

    /// Version timestamps, newest first.
    public func versions(_ id: String) -> [Date] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir(id).path)) ?? []
        return files.compactMap { Double($0.replacingOccurrences(of: ".rtf", with: "")).map { Date(timeIntervalSince1970: $0) } }
            .sorted(by: >)
    }

    public func version(_ id: String, at date: Date) -> Data? {
        try? Data(contentsOf: versionsDir(id).appendingPathComponent(String(format: "%.0f.rtf", date.timeIntervalSince1970)))
    }

    /// Plain text of a note (kept alongside the RTF), for search and the MCP server.
    public func plainText(_ id: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("\(id).txt"), encoding: .utf8)) ?? ""
    }

    private func snapshotIfDue(_ id: String, rtf: Data, now: Date) {
        let vdir = versionsDir(id)
        try? FileManager.default.createDirectory(at: vdir, withIntermediateDirectories: true)
        let existing = versions(id)
        if let last = existing.first, now.timeIntervalSince(last) < versionInterval { return }
        try? rtf.write(to: vdir.appendingPathComponent(String(format: "%.0f.rtf", now.timeIntervalSince1970)))
        for old in existing.dropFirst(maxVersions - 1) {
            try? FileManager.default.removeItem(at: vdir.appendingPathComponent(String(format: "%.0f.rtf", old.timeIntervalSince1970)))
        }
    }

    private func readIndex() -> [Note] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Note].self, from: data)) ?? []
    }

    private func writeIndex(_ notes: [Note]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(notes) { try? data.write(to: indexURL, options: .atomic) }
    }
}
