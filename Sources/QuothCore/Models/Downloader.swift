import CryptoKit
import Foundation

/// A model file to download: where from, how big, and its SHA-256 (as published by Hugging Face).
public struct DownloadItem: Equatable, Hashable, Sendable {
    public let file: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String

    public init(file: String, url: URL, bytes: Int64, sha256: String) {
        self.file = file
        self.url = url
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public enum DownloadEvent: Sendable {
    case progress(done: Int64, total: Int64)
    /// A connection dropped; trying again from where it stopped.
    case retrying(attempt: Int, reason: String)
    /// Downloaded; checking the SHA-256.
    case verifying
}

public struct DownloadResult: Sendable {
    public let url: URL
    /// Bytes already on disk from an earlier, interrupted attempt (0 for a fresh download).
    public let resumedFrom: Int64
    /// The file was already installed; nothing was downloaded.
    public let alreadyInstalled: Bool
}

public enum DownloadError: LocalizedError, Equatable, Sendable {
    case notEnoughSpace(needed: Int64, free: Int64)
    case checksumMismatch(file: String)
    case http(Int)
    case incomplete
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let free):
            "Not enough disk space: needs \(Self.size(needed)), \(Self.size(free)) free."
        case .checksumMismatch(let file): "\(file) was damaged in transit and has been deleted. Try again."
        case .http(let code): code == 404 ? "The model file wasn't found on the server (HTTP 404)." : "The server answered HTTP \(code)."
        case .incomplete: "The connection closed before the file was complete."
        case .cancelled: "Paused."
        }
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Downloads a large file into `<file>.part`, resuming after interruptions (HTTP Range), retrying dropped
/// connections, and checking its SHA-256 before it takes the real name. An interrupted download, even across
/// app restarts, continues where it stopped. One instance downloads one file at a time.
public final class ResumableDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private var cancelled = false
    private var lastReport = Date.distantPast
    private var onEvent: (@Sendable (DownloadEvent) -> Void)?
    private let configuration: URLSessionConfiguration
    /// Seconds to wait before retry number n (1, 2, …).
    private let retryDelay: @Sendable (Int) -> Double

    public init(configuration: URLSessionConfiguration = .default,
                retryDelay: @escaping @Sendable (Int) -> Double = { min(30, Double(1 << $0)) }) {
        self.configuration = configuration
        self.retryDelay = retryDelay
    }

    /// Extra free space to leave on the disk beyond the file itself.
    public static let spaceMargin: Int64 = 500_000_000

    public static func partURL(for item: DownloadItem, in dir: URL) -> URL {
        dir.appendingPathComponent(item.file + ".part")
    }

    public func download(_ item: DownloadItem, into dir: URL, retries: Int = 6,
                         onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> DownloadResult {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.file)
        if Self.fileSize(dest) == item.bytes {
            return DownloadResult(url: dest, resumedFrom: 0, alreadyInstalled: true)
        }
        let part = Self.partURL(for: item, in: dir)
        var offset = Self.fileSize(part) ?? 0
        if offset > item.bytes { try? fm.removeItem(at: part); offset = 0 }
        let resumedFrom = offset

        if let free = Self.freeSpace(dir), free < item.bytes - offset + Self.spaceMargin {
            throw DownloadError.notEnoughSpace(needed: item.bytes - offset, free: free)
        }

        lock.withLock { cancelled = false; self.onEvent = onEvent; total = item.bytes }
        var attempt = 0
        while offset < item.bytes {
            do {
                try await withTaskCancellationHandler {
                    try await fetch(item, to: part, from: offset)
                } onCancel: { self.cancel() }
                offset = Self.fileSize(part) ?? 0
                if offset < item.bytes { throw DownloadError.incomplete }
            } catch {
                if lock.withLock({ cancelled }) || Task.isCancelled { throw DownloadError.cancelled }
                attempt += 1
                guard attempt <= retries, Self.isRetryable(error) else { throw error }
                onEvent(.retrying(attempt: attempt, reason: error.localizedDescription))
                try? await Task.sleep(nanoseconds: UInt64(retryDelay(attempt) * 1_000_000_000))
                if lock.withLock({ cancelled }) || Task.isCancelled { throw DownloadError.cancelled }
                offset = Self.fileSize(part) ?? 0
            }
        }

        onEvent(.verifying)
        guard Self.fileSize(part) == item.bytes, try Self.sha256(of: part) == item.sha256.lowercased() else {
            try? fm.removeItem(at: part)
            throw DownloadError.checksumMismatch(file: item.file)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        return DownloadResult(url: dest, resumedFrom: resumedFrom, alreadyInstalled: false)
    }

    /// Stops the download, keeping what has arrived so it can resume later.
    public func cancel() {
        let t = lock.withLock { () -> URLSessionDataTask? in cancelled = true; return task }
        t?.cancel()
    }

    // MARK: one connection

    private func fetch(_ item: DownloadItem, to part: URL, from offset: Int64) async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: part)
        try h.truncate(atOffset: UInt64(offset))
        try h.seekToEnd()
        var req = URLRequest(url: item.url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        req.timeoutInterval = 60   // idle time without data, not the whole download
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let t = session.dataTask(with: req)
            let alreadyCancelled = lock.withLock { () -> Bool in
                continuation = c; handle = h; received = offset; failure = nil; task = t
                return cancelled
            }
            if alreadyCancelled { t.cancel() }
            t.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server ignored the range: start over.
            lock.withLock {
                try? handle?.truncate(atOffset: 0)
                received = 0
            }
            completionHandler(.allow)
        default:
            lock.withLock { failure = DownloadError.http(status) }
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (Int64, Int64, (@Sendable (DownloadEvent) -> Void)?)? = lock.withLock {
            do { try handle?.write(contentsOf: data) } catch {
                failure = error
                dataTask.cancel()
                return nil
            }
            received += Int64(data.count)
            guard Date().timeIntervalSince(lastReport) > 0.2 else { return nil }
            lastReport = Date()
            return (received, total, onEvent)
        }
        if let (done, total, onEvent) = report { onEvent?(.progress(done: done, total: total)) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, result, done, size, report) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?, Int64, Int64, (@Sendable (DownloadEvent) -> Void)?) in
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            self.task = nil
            let c = continuation
            continuation = nil
            return (c, failure ?? error, received, self.total, self.onEvent)
        }
        session.finishTasksAndInvalidate()   // the session holds its delegate (self) until invalidated
        report?(.progress(done: done, total: size))
        if let result { c?.resume(throwing: result) } else { c?.resume() }
    }

    // MARK: helpers

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case DownloadError.http(let code): code == 408 || code == 429 || code >= 500
        case DownloadError.incomplete: true
        case is DownloadError: false
        case let e as URLError: e.code != .cancelled
        default: false
        }
    }

    public static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    public static func freeSpace(_ dir: URL) -> Int64? {
        try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 16 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
