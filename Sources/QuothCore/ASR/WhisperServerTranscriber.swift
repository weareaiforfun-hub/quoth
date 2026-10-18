import Foundation

/// Talks to a local `whisper-server` (whisper.cpp) that the app keeps warm.
public struct WhisperServerTranscriber: Transcriber, LanguageDetecting {
    public let baseURL: URL
    public let session: URLSession

    public init(port: Int, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        var form = Multipart()
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: wav)
        // verbose_json adds ~0.6 s of word-timestamp work we do not need.
        form.field("response_format", "json")
        form.field("temperature", "0.0")
        form.field("language", language ?? "auto")
        if let prompt, !prompt.isEmpty { form.field("prompt", prompt) }

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await session.upload(for: req, from: form.finish())
        try checkHTTP(data, resp)
        guard let json = try? JSONDecoder().decode(TranscriptJSON.self, from: data) else {
            throw QuothError.badResponse(String(decoding: data, as: UTF8.self))
        }
        return TranscriptionResult(text: json.text.trimmingCharacters(in: .whitespacesAndNewlines), language: json.language)
    }

    /// Language-ID only (no transcription). Returns an ISO 639-1 code.
    public func detectLanguage(wav: Data) async throws -> String? {
        var form = Multipart()
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: wav)
        form.field("response_format", "json")
        form.field("detect_language", "true")
        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let (data, resp) = try await session.upload(for: req, from: form.finish())
        try checkHTTP(data, resp)
        let json = try? JSONDecoder().decode(TranscriptJSON.self, from: data)
        return json?.language.flatMap(Languages.code(forWhisperName:))
    }

    /// True once the server has loaded its model and answers HTTP.
    public func isReady() async -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode != nil
    }
}
