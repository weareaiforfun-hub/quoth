import Foundation

public protocol Cleaner: Sendable {
    func clean(_ raw: String, level: CleanupLevel, context: CleanupContext) async throws -> String
}

/// A chat model. Cleanup, Command Mode, Transforms and meeting summaries all go through this.
public protocol LLMClient: Sendable {
    /// - Parameters:
    ///   - json: ask the model for a JSON object.
    ///   - contextTokens: context window to request (Ollama defaults to a small one).
    func complete(_ messages: [ChatMessage], json: Bool, maxTokens: Int, contextTokens: Int?) async throws -> String
}

extension LLMClient {
    public func clean(_ raw: String, level: CleanupLevel, context: CleanupContext) async throws -> String {
        try await complete(CleanupPrompt.messages(raw: raw, level: level, context: context),
                           json: false, maxTokens: maxTokens(for: raw), contextTokens: nil)
    }
}

/// Ollama's native `/api/chat`: supports `keep_alive` (model stays loaded) and `think: false`.
public struct OllamaCleaner: Cleaner, LLMClient {
    public let baseURL: URL
    public let model: String
    public let session: URLSession

    public init(baseURL: URL, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    struct Request: Encodable {
        struct Options: Encodable { let temperature: Double; let num_predict: Int; let num_ctx: Int? }
        let model: String
        let messages: [ChatMessage]
        let stream = false
        let keep_alive = "60m"
        let think = false
        let format: String?
        let options: Options
    }

    struct Response: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    public func complete(_ messages: [ChatMessage], json: Bool, maxTokens: Int, contextTokens: Int?) async throws -> String {
        let body = Request(model: model, messages: messages, format: json ? "json" : nil,
                           options: .init(temperature: 0, num_predict: maxTokens, num_ctx: contextTokens))
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 600
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(data, resp)
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            throw QuothError.badResponse(String(decoding: data, as: UTF8.self))
        }
        return r.message.content
    }

    /// Loads the model into memory so the first dictation is not slow.
    public func warmUp() async {
        _ = try? await clean("hello", level: .light, context: .init())
    }
}

/// `/chat/completions` on any OpenAI-compatible API (Groq, OpenAI, OpenRouter, LM Studio…).
public struct ChatCompletionsCleaner: Cleaner, LLMClient {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    struct Request: Encodable {
        struct Format: Encodable { let type = "json_object" }
        let model: String
        let messages: [ChatMessage]
        let temperature = 0.0
        let max_tokens: Int
        let stream = false
        let response_format: Format?
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    public func complete(_ messages: [ChatMessage], json: Bool, maxTokens: Int, contextTokens: Int?) async throws -> String {
        let body = Request(model: model, messages: messages, max_tokens: maxTokens, response_format: json ? .init() : nil)
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        try checkHTTP(data, resp)
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let content = r.choices.first?.message.content else {
            throw QuothError.badResponse(String(decoding: data, as: UTF8.self))
        }
        return content
    }
}

/// llama.cpp's `llama-server` on this Mac: OpenAI-compatible, so `ChatCompletionsCleaner` talks to it.
public enum LlamaServer {
    public static func baseURL(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// The client for the model the server was started with (`--alias` = the GGUF file name).
    public static func client(port: Int, modelPath: String, session: URLSession = .shared) -> ChatCompletionsCleaner {
        ChatCompletionsCleaner(baseURL: baseURL(port: port), model: alias(forModelPath: modelPath), apiKey: nil, session: session)
    }

    public static func alias(forModelPath path: String) -> String { (path as NSString).lastPathComponent }

    /// The alias of the loaded model, once the server has finished loading it (nil while loading or not running).
    public static func loadedModel(port: Int, session: URLSession = .shared) async -> String? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let (data, _) = try? await session.data(from: baseURL(port: port).appendingPathComponent("models")) else { return nil }
        return parseModelsList(data).first
    }

    /// `/v1/models`: {"data":[{"id":"…"}]}.
    public static func parseModelsList(_ data: Data) -> [String] {
        struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
    }
}

/// Cleanup output is never much longer than the input; cap generation so a runaway answer is cut short.
func maxTokens(for raw: String) -> Int {
    let words = raw.split(whereSeparator: \.isWhitespace).count
    return max(64, words * 3 + 32)
}
