import Foundation

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

/// Transcribers that can identify the spoken language without transcribing (for pinned language sets).
public protocol LanguageDetecting: Sendable {
    func detectLanguage(wav: Data) async throws -> String?
}

public protocol Transcriber: Sendable {
    /// - Parameters:
    ///   - wav: 16 kHz mono 16-bit PCM WAV.
    ///   - language: ISO 639-1 code, or nil to auto-detect.
    ///   - prompt: optional vocabulary hint (dictionary words).
    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> TranscriptionResult
}

public enum QuothError: LocalizedError, Sendable {
    case http(Int, String)
    case badResponse(String)
    case timeout
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .badResponse(let s): "Unexpected response: \(s.prefix(200))"
        case .timeout: "Timed out"
        case .notConfigured(let s): s
        }
    }
}

/// Minimal multipart/form-data builder for audio uploads.
struct Multipart {
    let boundary = "quoth-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    mutating func finish() -> Data {
        body.append("--\(boundary)--\r\n")
        return body
    }
}

extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

func checkHTTP(_ data: Data, _ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw QuothError.badResponse("no HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
        throw QuothError.http(http.statusCode, String(decoding: data, as: UTF8.self))
    }
}

public enum Languages {
    /// ISO 639-1 codes and names for the language picker (whisper supports ~100).
    public static let all: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("fa", "Persian"), ("ar", "Arabic"), ("hi", "Hindi"),
        ("ur", "Urdu"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("tr", "Turkish"), ("pl", "Polish"), ("sv", "Swedish"), ("da", "Danish"),
        ("no", "Norwegian"), ("fi", "Finnish"), ("cs", "Czech"), ("el", "Greek"), ("he", "Hebrew"),
        ("id", "Indonesian"), ("ms", "Malay"), ("th", "Thai"), ("vi", "Vietnamese"), ("ro", "Romanian"),
        ("hu", "Hungarian"), ("bn", "Bengali"), ("ta", "Tamil"), ("tl", "Tagalog"), ("ca", "Catalan"),
        ("yue", "Cantonese"),
    ]

    public static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code }

    public static func code(forWhisperName name: String) -> String? {
        let n = name.lowercased()
        if n.count <= 3 { return n }
        let aliases = ["castilian": "es", "valencian": "ca", "moldavian": "ro", "flemish": "nl", "mandarin": "zh"]
        if let c = aliases[n] { return c }
        return all.first { $0.name.lowercased() == n }?.code
    }
}

struct TranscriptJSON: Decodable {
    let text: String
    let language: String?
}
