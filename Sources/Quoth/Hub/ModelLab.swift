import Foundation
import QuothCore

/// Runs side-by-side model comparisons for the Models tab.
@MainActor
final class ModelLab: ObservableObject {
    struct SpeechResult: Identifiable {
        let id = UUID()
        let sample: String
        let model: String
        let text: String
        let ms: Int
        /// Word error rate vs the known text (bundled samples) or vs the first model (your recordings).
        let wer: Double?
    }

    @Published var running = false
    @Published var status = ""
    @Published var cleanup: [CleanupResult] = []
    @Published var cleanupModels: [String] = []
    @Published var cleanupInputs: [(id: String, raw: String)] = []
    @Published var speech: [SpeechResult] = []
    @Published var speechModels: [String] = []

    private let state: AppState
    init(state: AppState) { self.state = state }

    static var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }

    // MARK: cleanup

    /// - Parameters:
    ///   - models: Ollama tags, "builtin" for the model the built-in engine has loaded, or "cloud" for the configured cloud model.
    ///   - quick: 12 representative test sentences instead of all of them.
    func runCleanup(models: [String], quick: Bool, includeRecent: Bool) async {
        guard !running, !models.isEmpty else { return }
        running = true
        defer { running = false; status = "" }
        cleanup = []
        cleanupModels = models
        var cases = Self.goldenCases()
        if quick { cases = Self.quickSubset(cases) }
        if includeRecent {
            // Your own recent raw transcripts: no expected answer, compare outputs by eye.
            let recent = state.history.filter { $0.status == .ok && !$0.raw.isEmpty }.prefix(5)
            for r in recent {
                let json = #"{"id":"recent-\#(r.id.prefix(6))","category":"yours","raw":\#(Self.jsonString(r.raw)),"expected":""}"#
                if let c = CleanupCase.load(jsonl: json).first { cases.append(c) }
            }
        }
        cleanupInputs = cases.map { ($0.id, $0.raw) }
        for (i, m) in models.enumerated() {
            guard let cleaner = cleanerFor(m) else { continue }
            status = "Model \(i + 1) of \(models.count): \(m) (loading…)"
            if let o = cleaner as? OllamaCleaner { await o.warmUp() }
            var done = 0
            let results = await ModelBench.runCleanup(cleaner: cleaner, model: m, cases: cases)
            for r in results {
                done += 1
                var r = r
                if r.caseID.hasPrefix("recent-") { r.verdict = nil }
                cleanup.append(r)
            }
            status = "Model \(i + 1) of \(models.count): \(m), \(done) sentences done"
        }
    }

    func summary(_ model: String) -> CleanupSummary {
        ModelBench.summarize(cleanup.filter { $0.verdict != nil }, model: model)
    }

    private func cleanerFor(_ model: String) -> (any Cleaner)? {
        let s = state.settings
        if model == "builtin" {
            return LlamaServer.client(port: s.llamaPort, modelPath: s.llamaModelPath)
        }
        if model == "cloud" {
            guard let key = Keychain.apiKey(), let url = URL(string: s.cloudBaseURL) else { return nil }
            return ChatCompletionsCleaner(baseURL: url, model: s.cloudLLMModel, apiKey: key)
        }
        return OllamaCleaner(baseURL: URL(string: s.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!, model: model)
    }

    static func goldenCases() -> [CleanupCase] {
        let url = resources.appendingPathComponent("cleanup-golden.jsonl")
        return CleanupCase.load(jsonl: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// One or two cases from each category, so a quick run still covers every behaviour.
    static func quickSubset(_ all: [CleanupCase]) -> [CleanupCase] {
        var perCategory: [String: Int] = [:]
        return all.filter { c in
            let n = perCategory[c.category, default: 0]
            perCategory[c.category] = n + 1
            return n < 1 || (n < 2 && ["backtrack", "no-answer", "lists"].contains(c.category))
        }
    }

    static func jsonString(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    // MARK: speech

    /// - Parameter models: whisper.cpp model files (in the models folder).
    func runSpeech(models: [String], useRecordings: Bool) async {
        guard !running, !models.isEmpty else { return }
        running = true
        defer { running = false; status = "" }
        speech = []
        speechModels = models
        var inputs: [(name: String, samples: [Float], text: String?)] = []
        let dir = Self.resources.appendingPathComponent("Samples")
        for s in SpeechSample.load(dir: dir) {
            if let data = FileManager.default.contents(atPath: dir.appendingPathComponent(s.file).path), let f = WAVEncoder.decode(data) {
                inputs.append((s.file.replacingOccurrences(of: ".wav", with: ""), f, s.text))
            }
        }
        if useRecordings {
            for r in state.history.filter({ $0.audioPath != nil && $0.duration <= 30 && $0.status == .ok }).prefix(3) {
                if let p = r.audioPath, let data = FileManager.default.contents(atPath: p), let f = WAVEncoder.decode(data) {
                    inputs.append(("Your dictation \(r.createdAt.formatted(date: .omitted, time: .shortened))", f, nil))
                }
            }
        }
        let main = state.settings.whisperModelPath
        var firstOutputs: [String: String] = [:]
        for (i, file) in models.enumerated() {
            let path = AppPaths.models.appendingPathComponent(file).path
            status = "Model \(i + 1) of \(models.count): \(file) (loading…)"
            var temp: Process?
            var port = state.settings.whisperPort
            if path != main {
                port = 8179
                temp = Self.startTempServer(modelPath: path, port: port)
                guard await Self.waitReady(port: port) else {
                    temp?.terminate()
                    status = "Couldn't start \(file)"
                    continue
                }
            }
            let asr = WhisperServerTranscriber(port: port)
            _ = try? await asr.transcribe(wav: WAVEncoder.encode([Float](repeating: 0, count: 16_000)), language: "en", prompt: nil)
            let lang = state.settings.languages.count == 1 ? state.settings.languages[0] : nil
            for inp in inputs {
                status = "Model \(i + 1) of \(models.count): \(file), \(inp.name)"
                let t = Date()
                let text = (try? await asr.transcribe(wav: WAVEncoder.encode(inp.samples), language: lang, prompt: nil).text) ?? "(failed)"
                let ms = Int(Date().timeIntervalSince(t) * 1000)
                let reference = inp.text ?? firstOutputs[inp.name]
                if inp.text == nil && firstOutputs[inp.name] == nil { firstOutputs[inp.name] = text }
                speech.append(SpeechResult(sample: inp.name, model: file, text: text, ms: ms,
                                           wer: reference.map { ModelBench.wordErrorRate(reference: $0, hypothesis: text) }))
            }
            temp?.terminate()
            if temp != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
    }

    static func startTempServer(modelPath: String, port: Int) -> Process? {
        guard let bin = EngineProcess.findBinary("whisper-server") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelPath, "--host", "127.0.0.1", "--port", "\(port)", "-t", "6"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p.isRunning ? p : nil
    }

    static func waitReady(port: Int) async -> Bool {
        let c = WhisperServerTranscriber(port: port)
        for _ in 0..<120 {
            if await c.isReady() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
