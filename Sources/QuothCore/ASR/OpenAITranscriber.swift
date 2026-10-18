import Foundation

/// `/audio/transcriptions` on any OpenAI-compatible API (Groq, OpenAI, …).
public struct OpenAITranscriber: Transcriber {
    public let baseURL: URL
    public let model: String
    public let apiKey: String
    public let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        var form = Multipart()
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: wav)
        form.field("model", model)
        form.field("response_format", "verbose_json")
        form.field("temperature", "0")
        if let language { form.field("language", language) }
        if let prompt, !prompt.isEmpty { form.field("prompt", prompt) }

        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        let (data, resp) = try await session.upload(for: req, from: form.finish())
        try checkHTTP(data, resp)
        guard let json = try? JSONDecoder().decode(TranscriptJSON.self, from: data) else {
            throw QuothError.badResponse(String(decoding: data, as: UTF8.self))
        }
        return TranscriptionResult(text: json.text.trimmingCharacters(in: .whitespacesAndNewlines), language: json.language)
    }
}
