import CryptoKit
import Foundation
import Testing
@testable import QuothCore

/// A fake server for `ResumableDownloader`: honours Range, and can drop the connection,
/// ignore ranges, or answer with an error status.
final class FakeModelServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    /// Drop the connection after sending this many bytes, once.
    nonisolated(unsafe) static var dropAfter: Int?
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var ranges: [String?] = []

    static func reset(_ data: Data) {
        body = data; status = 200; dropAfter = nil; ignoreRange = false; ranges = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.ranges.append(range)
        let url = request.url!
        guard Self.status == 200 else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var start = 0
        if let range, !Self.ignoreRange, let n = Int(range.dropFirst("bytes=".count).dropLast()) { start = n }
        let code = start > 0 ? 206 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        var chunk = Self.body.subdata(in: start..<Self.body.count)
        if let drop = Self.dropAfter, drop < chunk.count {
            Self.dropAfter = nil
            chunk = chunk.prefix(drop)
            client?.urlProtocol(self, didLoad: chunk)
            // Like a real connection: the bytes arrive, then the line goes dead.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: chunk)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct DownloadTests {
    let dir: URL
    let data: Data
    let item: DownloadItem

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("quoth-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        item = DownloadItem(file: "model.gguf", url: URL(string: "https://example.invalid/model.gguf")!, bytes: Int64(data.count), sha256: hash)
        FakeModelServer.reset(data)
    }

    func downloader() -> ResumableDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeModelServer.self]
        return ResumableDownloader(configuration: config, retryDelay: { _ in 0.01 })
    }

    var dest: URL { dir.appendingPathComponent(item.file) }
    var part: URL { ResumableDownloader.partURL(for: item, in: dir) }

    @Test func downloadsAndVerifies() async throws {
        let r = try await downloader().download(item, into: dir) { _ in }
        #expect(r.resumedFrom == 0 && !r.alreadyInstalled)
        #expect(try Data(contentsOf: dest) == data)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        // Second time: nothing to do.
        let again = try await downloader().download(item, into: dir) { _ in }
        #expect(again.alreadyInstalled)
    }

    @Test func retriesADroppedConnectionFromWhereItStopped() async throws {
        FakeModelServer.dropAfter = 100_000
        let events = EventLog()
        _ = try await downloader().download(item, into: dir) { events.add($0) }
        #expect(try Data(contentsOf: dest) == data)
        #expect(FakeModelServer.ranges == [nil, "bytes=100000-"])
        #expect(events.retries == 1 && events.verified)
    }

    @Test func resumesAPartialFileFromAnEarlierRun() async throws {
        try data.prefix(120_000).write(to: part)
        let r = try await downloader().download(item, into: dir) { _ in }
        #expect(r.resumedFrom == 120_000)
        #expect(FakeModelServer.ranges == ["bytes=120000-"])
        #expect(try Data(contentsOf: dest) == data)
    }

    @Test func startsOverWhenTheServerIgnoresTheRange() async throws {
        try data.prefix(50_000).write(to: part)
        FakeModelServer.ignoreRange = true
        _ = try await downloader().download(item, into: dir) { _ in }
        #expect(try Data(contentsOf: dest) == data)
    }

    @Test func corruptDownloadIsRejectedAndDeleted() async throws {
        var bad = data
        bad[1234] ^= 0xFF
        FakeModelServer.body = bad
        await #expect(throws: DownloadError.checksumMismatch(file: "model.gguf")) {
            try await downloader().download(item, into: dir) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func missingFileFailsWithoutRetrying() async throws {
        FakeModelServer.status = 404
        await #expect(throws: DownloadError.http(404)) {
            try await downloader().download(item, into: dir) { _ in }
        }
        #expect(FakeModelServer.ranges.count == 1)
        #expect(DownloadError.http(404).localizedDescription.contains("wasn't found"))
    }

    @Test func helpers() throws {
        #expect(ResumableDownloader.isRetryable(URLError(.networkConnectionLost)))
        #expect(ResumableDownloader.isRetryable(DownloadError.http(503)))
        #expect(!ResumableDownloader.isRetryable(DownloadError.http(403)))
        #expect(!ResumableDownloader.isRetryable(DownloadError.checksumMismatch(file: "x")))
        try data.write(to: dest)
        #expect(try ResumableDownloader.sha256(of: dest) == item.sha256)
        #expect((ResumableDownloader.freeSpace(dir) ?? 0) > 0)
        #expect(DownloadError.notEnoughSpace(needed: 9_000_000_000, free: 1_000_000_000).localizedDescription.contains("9 GB"))
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []
    func add(_ e: DownloadEvent) { lock.withLock { events.append(e) } }
    var retries: Int { lock.withLock { events.filter { if case .retrying = $0 { true } else { false } }.count } }
    var verified: Bool { lock.withLock { events.contains { if case .verifying = $0 { true } else { false } } } }
}

@Suite struct BundleTests {
    @Test func recommendationsFollowMemory() {
        #expect(ModelBundle.recommended(ramGB: 8) == .lite)
        #expect(ModelBundle.recommended(ramGB: 4) == .lite)
        #expect(ModelBundle.recommended(ramGB: 16) == .standard)
        #expect(ModelBundle.recommended(ramGB: 24) == .standard)
        #expect(ModelBundle.recommended(ramGB: 32) == .best)
        #expect(ModelBundle.recommended(ramGB: 128) == .best)
        #expect(ModelBundle.thisMacRAMGB > 0)
        #expect(ModelBundle.ramGB(bytes: 8 << 30) == 8)
        #expect(ModelBundle.ramGB(bytes: (8 << 30) - 300_000_000) == 8)   // a VM reporting a bit less
        #expect(ModelBundle.ramGB(bytes: 64 << 30) == 64)
    }

    @Test func bundlesMatchThePlan() {
        // Lite ~3 GB, Standard ~5.3 GB, Best ~9.6 GB (see docs/distribution.md).
        #expect((2.8...3.2).contains(Double(ModelBundle.lite.bytes) / 1e9))
        #expect((5.1...5.5).contains(Double(ModelBundle.standard.bytes) / 1e9))
        #expect((9.4...9.8).contains(Double(ModelBundle.best.bytes) / 1e9))
        for b in ModelBundle.allCases {
            #expect(b.downloads.count == 2 && b.downloads.allSatisfy { $0.sha256.count == 64 })
        }
        // Every speech model in the catalog carries a hash too.
        #expect(ModelCatalog.speech.allSatisfy { $0.sha256.count == 64 && $0.bytes > 10_000_000 })
    }

    @Test func usingABundleAndCheckingWhatIsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quoth-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = Settings()
        s.textProvider = .cloud
        s.use(.standard, in: dir)
        #expect(s.textProvider == .local && s.localTextEngine == .builtIn)
        #expect(ModelBundle.matching(s) == .standard)
        #expect(s.missingLocalModels.count == 2)
        FileManager.default.createFile(atPath: s.whisperModelPath, contents: Data())
        #expect(s.missingLocalModels == [s.llamaModelPath])
        FileManager.default.createFile(atPath: s.llamaModelPath, contents: Data())
        #expect(s.missingLocalModels.isEmpty)
        // Cloud and Ollama need no files from Quoth.
        var c = Settings()
        c.whisperModelPath = "/nonexistent.bin"; c.llamaModelPath = "/nonexistent.gguf"
        c.provider = .cloud
        #expect(c.missingLocalModels.isEmpty)
        c.provider = .local; c.localTextEngine = .ollama
        #expect(c.missingLocalModels == ["/nonexistent.bin"])
        #expect(ModelBundle.matching(c) == nil)
    }
}
