import Foundation

/// Quoth uses two kinds of model for two different jobs:
/// - **Speech recognition** turns audio into text (Whisper models, run by whisper.cpp, or a cloud API).
/// - **Language models** turn text into better text: cleanup, commands, transforms, meeting notes
///   (Qwen, Llama, Gemma… run by the built-in llama.cpp engine, Ollama, or a cloud API).
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
    public let bytes: Int64
    public let sha256: String
    public let notes: String
    public let englishOnly: Bool

    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
    public var sizeMB: Int { Int(bytes / 1_000_000) }
    public var download: DownloadItem { DownloadItem(file: file, url: url, bytes: bytes, sha256: sha256) }
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

/// A GGUF language model file for the built-in llama.cpp engine.
public struct GGUFModelInfo: Identifiable, Equatable, Sendable {
    public var id: String { file }
    public let file: String
    /// Hugging Face repository the file comes from.
    public let repo: String
    public let name: String
    public let bytes: Int64
    public let sha256: String
    /// Approximate memory while loaded, including the context cache.
    public let ramGB: Int
    public let license: String
    public let notes: String

    public var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    public var sizeGB: Double { Double(bytes) / 1_000_000_000 }
    public var download: DownloadItem { DownloadItem(file: file, url: url, bytes: bytes, sha256: sha256) }
}

public enum ModelCatalog {
    /// whisper.cpp models from huggingface.co/ggerganov/whisper.cpp (all MIT-licensed OpenAI Whisper weights).
    public static let speech: [SpeechModelInfo] = [
        .init(file: "ggml-tiny.bin", name: "Whisper Tiny", bytes: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
              notes: "Fastest, least accurate. Fine for quick English notes on older Macs.", englishOnly: false),
        .init(file: "ggml-base.bin", name: "Whisper Base", bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
              notes: "Very fast; misses names and noisy speech more often.", englishOnly: false),
        .init(file: "ggml-small.bin", name: "Whisper Small", bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
              notes: "Good balance on 8 GB Macs.", englishOnly: false),
        .init(file: "ggml-small.en.bin", name: "Whisper Small (English)", bytes: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
              notes: "English only, slightly better than Small for English.", englishOnly: true),
        .init(file: "ggml-medium-q5_0.bin", name: "Whisper Medium", bytes: 539_212_467, sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
              notes: "More accurate, noticeably slower than Large v3 Turbo.", englishOnly: false),
        .init(file: "ggml-large-v3-turbo-q5_0.bin", name: "Whisper Large v3 Turbo (default)", bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
              notes: "Recommended: near-best accuracy at high speed, 100 languages.", englishOnly: false),
        .init(file: "ggml-large-v3-turbo.bin", name: "Whisper Large v3 Turbo (full precision)", bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
              notes: "Same model without quantisation; marginally more accurate, 3× the size.", englishOnly: false),
        .init(file: "ggml-large-v3-q5_0.bin", name: "Whisper Large v3", bytes: 1_081_140_203, sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
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

    /// Curated GGUF files for the built-in engine (Q4_K_M quantisation, as Ollama uses).
    public static let gguf: [GGUFModelInfo] = [
        .init(file: "Qwen2.5-14B-Instruct-Q4_K_M.gguf", repo: "bartowski/Qwen2.5-14B-Instruct-GGUF", name: "Qwen 2.5 14B",
              bytes: 8_988_110_976, sha256: "e47ad95dad6ff848b431053b375adb5d39321290ea2c638682577dafca87c008",
              ramGB: 13, license: "Apache-2.0",
              notes: "Best tested accuracy. For Macs with 32 GB or more."),
        .init(file: "Qwen2.5-7B-Instruct-Q4_K_M.gguf", repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", name: "Qwen 2.5 7B",
              bytes: 4_683_074_240, sha256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
              ramGB: 6, license: "Apache-2.0",
              notes: "About twice as fast; sometimes answers questions or garbles corrections. Good for 16 GB Macs."),
        .init(file: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf", repo: "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF", name: "Qwen 3 4B",
              bytes: 2_497_280_736, sha256: "2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e",
              ramGB: 4, license: "Apache-2.0",
              notes: "Small and quick for 8 GB Macs; weaker cleanup than the larger models."),
    ]

    public static var defaultGGUF: GGUFModelInfo { gguf[0] }

    public static func ggufInfo(forPath path: String) -> GGUFModelInfo? {
        gguf.first { $0.file == (path as NSString).lastPathComponent }
    }

    public static func isInstalled(_ m: GGUFModelInfo, in dir: URL = AppPaths.models) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(m.file).path)
    }

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
