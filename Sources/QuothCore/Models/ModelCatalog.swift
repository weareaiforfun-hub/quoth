import Foundation

/// Quoth uses two kinds of model for two different jobs:
/// - **Speech recognition** turns audio into text (Whisper models, run by whisper.cpp, or a cloud API).
/// - **Language models** turn text into better text: cleanup, commands, transforms, meeting notes
///   (Qwen, Llama, Gemma… run by Ollama, or a cloud API).
/// They aren't interchangeable: a chat model like Qwen 2.5 can't hear audio, and Whisper can't rewrite text.
public enum ModelRole: String, CaseIterable, Codable, Sendable {
    case speech, cleanup, commands, meetings

    public var title: String {
        switch self {
        case .speech: "Speech recognition"
        case .cleanup: "Dictation cleanup"
        case .commands: "Command Mode & Transforms"
        case .meetings: "Meeting notes"
        }
    }

    public var explanation: String {
        switch self {
        case .speech: "Turns your voice into raw text. Bigger models are more accurate with names, accents and noise, but slower."
        case .cleanup: "Removes fillers, applies corrections, formats lists. Runs on every dictation, so speed matters most here."
        case .commands: "Follows spoken instructions and rewrites selected text. Benefits from a smarter model; speed matters less."
        case .meetings: "Summarises meetings and answers questions about them. Runs after the meeting, so a larger model is fine."
        }
    }
}

public struct SpeechModelInfo: Identifiable, Equatable, Sendable {
    public var id: String { file }
    public let file: String
    public let name: String
    public let sizeMB: Int
    public let notes: String
    public let englishOnly: Bool

    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
}

public struct TextModelInfo: Identifiable, Equatable, Sendable {
    public var id: String { tag }
    /// Ollama tag.
    public let tag: String
    public let name: String
    public let sizeGB: Double
    /// Approximate memory while loaded.
    public let ramGB: Int
    public let license: String
    public let notes: String
}

public enum ModelCatalog {
    /// whisper.cpp models from huggingface.co/ggerganov/whisper.cpp (all MIT-licensed OpenAI Whisper weights).
    public static let speech: [SpeechModelInfo] = [
        .init(file: "ggml-tiny.bin", name: "Whisper Tiny", sizeMB: 77,
              notes: "Fastest, least accurate. Fine for quick English notes on older Macs.", englishOnly: false),
        .init(file: "ggml-base.bin", name: "Whisper Base", sizeMB: 147,
              notes: "Very fast; misses names and noisy speech more often.", englishOnly: false),
        .init(file: "ggml-small.bin", name: "Whisper Small", sizeMB: 487,
              notes: "Good balance on 8 GB Macs.", englishOnly: false),
        .init(file: "ggml-small.en.bin", name: "Whisper Small (English)", sizeMB: 487,
              notes: "English only, slightly better than Small for English.", englishOnly: true),
        .init(file: "ggml-medium-q5_0.bin", name: "Whisper Medium", sizeMB: 539,
              notes: "More accurate, noticeably slower than Large v3 Turbo.", englishOnly: false),
        .init(file: "ggml-large-v3-turbo-q5_0.bin", name: "Whisper Large v3 Turbo (default)", sizeMB: 574,
              notes: "Recommended: near-best accuracy at high speed, 100 languages.", englishOnly: false),
        .init(file: "ggml-large-v3-turbo.bin", name: "Whisper Large v3 Turbo (full precision)", sizeMB: 1624,
              notes: "Same model without quantisation; marginally more accurate, 3× the size.", englishOnly: false),
        .init(file: "ggml-large-v3-q5_0.bin", name: "Whisper Large v3", sizeMB: 1081,
              notes: "Most accurate; about 3× slower than Turbo.", englishOnly: false),
    ]

    /// Curated Ollama models. Any other Ollama tag can be typed in too.
    public static let text: [TextModelInfo] = [
        .init(tag: "qwen2.5:14b-instruct", name: "Qwen 2.5 14B (default)", sizeGB: 9.0, ramGB: 12, license: "Apache-2.0",
              notes: "Best tested accuracy: 0 serious failures on Quoth's 66-case test set, ~0.8 s per sentence on an M1 Max."),
        .init(tag: "qwen2.5:7b-instruct", name: "Qwen 2.5 7B", sizeGB: 4.7, ramGB: 7, license: "Apache-2.0",
              notes: "About twice as fast; sometimes answers questions or garbles corrections. Good for 16 GB Macs."),
        .init(tag: "qwen2.5:3b-instruct", name: "Qwen 2.5 3B", sizeGB: 1.9, ramGB: 4, license: "Qwen Research (non-commercial)",
              notes: "Small and fast for 8 GB Macs; noticeably weaker cleanup."),
        .init(tag: "qwen3:8b", name: "Qwen 3 8B", sizeGB: 5.2, ramGB: 8, license: "Apache-2.0",
              notes: "Newer generation; run with thinking off (Quoth does this automatically)."),
        .init(tag: "llama3.2:3b", name: "Llama 3.2 3B", sizeGB: 2.0, ramGB: 4, license: "Llama 3.2 Community",
              notes: "Meta's small model; quick, English-focused."),
        .init(tag: "gemma3:12b", name: "Gemma 3 12B", sizeGB: 8.1, ramGB: 11, license: "Gemma Terms of Use",
              notes: "Accurate on corrections in our tests but ~7 s per sentence (can't reuse the prompt cache). Better for meetings than dictation."),
        .init(tag: "mistral-small", name: "Mistral Small 24B", sizeGB: 14, ramGB: 18, license: "Apache-2.0",
              notes: "Strong writer for Commands, Transforms and meeting notes on 32 GB+ Macs."),
    ]

    public static func speechInfo(forPath path: String) -> SpeechModelInfo? {
        speech.first { $0.file == (path as NSString).lastPathComponent }
    }

    public static func isInstalled(_ m: SpeechModelInfo, in dir: URL = AppPaths.models) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(m.file).path)
    }

    /// Recommended defaults by memory, used by onboarding and the docs.
    public static func recommendedTextModel(ramGB: Int) -> String {
        ramGB >= 32 ? "qwen2.5:14b-instruct" : ramGB >= 16 ? "qwen2.5:7b-instruct" : "qwen2.5:3b-instruct"
    }
}

/// Downloads a model file with progress, via a temporary file so a failed download never leaves a broken model.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!
    private var progress: (@Sendable (Double) -> Void)?

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        self.destination = destination
        self.progress = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw QuothError.http(http.statusCode, "download failed")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

extension OllamaCleaner {
    /// Installed model tags.
    public func listTags() async throws -> [String] {
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let (data, resp) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        try checkHTTP(data, resp)
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    /// Downloads a model through Ollama, reporting progress 0…1.
    public func pull(_ tag: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": tag, "stream": true])
        req.timeoutInterval = 3600
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QuothError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "pull failed")
        }
        for try await line in bytes.lines {
            guard let p = Self.parsePullLine(line) else { continue }
            if let err = p.error { throw QuothError.badResponse(err) }
            progress(p.fraction, p.status)
        }
    }

    /// One NDJSON line of `/api/pull`: {"status":"pulling…","total":N,"completed":M} or {"error":"…"}.
    public static func parsePullLine(_ line: String) -> (fraction: Double, status: String, error: String?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let total = (obj["total"] as? NSNumber)?.doubleValue ?? 0
        let done = (obj["completed"] as? NSNumber)?.doubleValue ?? 0
        let status = obj["status"] as? String ?? ""
        let fraction = status == "success" ? 1 : total > 0 ? done / total : 0
        return (fraction, status, obj["error"] as? String)
    }
}
