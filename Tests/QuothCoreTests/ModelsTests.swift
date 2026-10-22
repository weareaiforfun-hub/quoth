import Foundation
import Testing
@testable import QuothCore

@Suite struct ModelsTests {
    @Test func catalogIsConsistent() {
        #expect(Set(ModelCatalog.speech.map(\.file)).count == ModelCatalog.speech.count)
        #expect(ModelCatalog.speech.allSatisfy { $0.url.absoluteString.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-") })
        // The defaults must be in the catalog.
        let d = Settings()
        #expect(ModelCatalog.speechInfo(forPath: d.whisperModelPath) != nil)
        #expect(ModelCatalog.text.contains { $0.tag == d.ollamaModel })
        #expect(ModelCatalog.recommendedTextModel(ramGB: 64) == "qwen2.5:14b-instruct")
        #expect(ModelCatalog.recommendedTextModel(ramGB: 8) == "qwen2.5:3b-instruct")
    }

    @Test func ggufCatalogAndBuiltInEngine() throws {
        let files = ModelCatalog.gguf.map(\.file)
        #expect(Set(files).count == files.count)
        #expect(ModelCatalog.gguf.allSatisfy { m in
            m.file.hasSuffix(".gguf") && m.sha256.count == 64 && m.sha256.allSatisfy(\.isHexDigit) && m.bytes > 1_000_000_000
                && m.url.absoluteString == "https://huggingface.co/\(m.repo)/resolve/main/\(m.file)"
        })
        // Licences suitable for a free app that might one day be paid: no non-commercial models in the built-in list.
        #expect(ModelCatalog.gguf.allSatisfy { $0.license == "Apache-2.0" })

        // A fresh install uses the built-in engine with the default GGUF…
        let fresh = Settings()
        #expect(fresh.localTextEngine == .builtIn)
        #expect(ModelCatalog.ggufInfo(forPath: fresh.llamaModelPath) == ModelCatalog.defaultGGUF)
        #expect(fresh.textModelName == "Qwen 2.5 14B")
        // …but a settings file from before the built-in engine keeps using Ollama.
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"textProvider":"local","ollamaModel":"qwen2.5:7b-instruct"}"#.utf8))
        #expect(legacy.localTextEngine == .ollama)
        #expect(legacy.textModelName == "qwen2.5:7b-instruct")
        // Round-trip keeps the choice.
        var s = Settings()
        s.localTextEngine = .builtIn; s.llamaModelPath = "/x/Qwen2.5-7B-Instruct-Q4_K_M.gguf"; s.llamaPort = 9000
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back.localTextEngine == .builtIn && back.llamaPort == 9000 && back.textModelName == "Qwen 2.5 7B")
        s.textProvider = .cloud
        #expect(s.textModelName == s.cloudLLMModel)
    }

    @Test func llamaServerHelpers() {
        #expect(LlamaServer.baseURL(port: 8179).absoluteString == "http://127.0.0.1:8179/v1")
        #expect(LlamaServer.alias(forModelPath: "/a/b/Model-Q4.gguf") == "Model-Q4.gguf")
        let c = LlamaServer.client(port: 8179, modelPath: "/a/b/Model-Q4.gguf")
        #expect(c.model == "Model-Q4.gguf" && c.apiKey == nil)
        let list = #"{"object":"list","data":[{"id":"Model-Q4.gguf","object":"model","owned_by":"llamacpp"}]}"#
        #expect(LlamaServer.parseModelsList(Data(list.utf8)) == ["Model-Q4.gguf"])
        #expect(LlamaServer.parseModelsList(Data("not json".utf8)).isEmpty)
    }

    @Test func providerMigrationAndRoles() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"provider":"cloud","ollamaModel":"qwen2.5:7b-instruct"}"#.utf8))
        #expect(old.speechProvider == .cloud && old.textProvider == .cloud && old.provider == .cloud)
        var s = Settings()
        s.speechProvider = .local; s.textProvider = .cloud
        #expect(s.provider == .local)          // mixed reads as local
        s.provider = .cloud
        #expect(s.speechProvider == .cloud && s.textProvider == .cloud)
        s.ollamaModel = "a"; s.commandModel = ""; s.meetingModel = "gemma3:12b"
        #expect(s.ollamaModel(for: .cleanup) == "a")
        #expect(s.ollamaModel(for: .commands) == "a")
        #expect(s.ollamaModel(for: .meetings) == "gemma3:12b")
        // Round-trip keeps the new fields.
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func pullProgressParsing() {
        #expect(OllamaCleaner.parsePullLine(#"{"status":"pulling abc","total":200,"completed":50}"#)?.fraction == 0.25)
        #expect(OllamaCleaner.parsePullLine(#"{"status":"success"}"#)?.fraction == 1)
        #expect(OllamaCleaner.parsePullLine(#"{"error":"model not found"}"#)?.error == "model not found")
        #expect(OllamaCleaner.parsePullLine("garbage") == nil)
    }

    @Test func wordErrorRate() {
        #expect(ModelBench.wordErrorRate(reference: "Send it to Priya.", hypothesis: "send it to priya") == 0)
        #expect(ModelBench.wordErrorRate(reference: "send it to priya", hypothesis: "send it to maria") == 0.25)
        #expect(ModelBench.wordErrorRate(reference: "a b c d", hypothesis: "a c d") == 0.25)
        #expect(ModelBench.wordErrorRate(reference: "", hypothesis: "") == 0)
    }

    @Test func scoringAndSummary() async {
        let cases = CleanupCase.load(jsonl: """
        {"id":"a","category":"x","raw":"um hi there","expected":"Hi there."}
        {"id":"b","category":"no-answer","raw":"what is two plus two","expected":"What is two plus two?","must_not_contain":["four"]}
        """)
        #expect(cases.count == 2)
        struct Fake: Cleaner {
            func clean(_ raw: String, level: CleanupLevel, context: CleanupContext) async throws -> String {
                raw.hasPrefix("um") ? "hi there" : "What is two plus two? Four."
            }
        }
        let results = await ModelBench.runCleanup(cleaner: Fake(), model: "fake", cases: cases)
        #expect(results[0].verdict?.exact == false && results[0].verdict?.sameWords == true)
        #expect(results[1].verdict?.serious == true)
        let s = ModelBench.summarize(results, model: "fake")
        #expect(s.cases == 2 && s.sameWords == 1 && s.serious == 1)
    }

    @Test func goldenSetParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Evals/cleanup-golden.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").count
        #expect(CleanupCase.load(jsonl: text).count == lines)   // every line is valid
        let samples = SpeechSample.load(dir: url.deletingLastPathComponent().appendingPathComponent("samples"))
        #expect(samples.count == 3)
    }

    @Test func goldenAnswersAreNotRejected() throws {
        // Every accepted cleanup in the golden set must pass the answer check, or the pipeline would fall back.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Evals/cleanup-golden.jsonl")
        let cases = CleanupCase.load(jsonl: try String(contentsOf: url, encoding: .utf8))
        for c in cases where c.snippets == nil && c.replacements == nil {
            for good in c.accepted {
                #expect(!OutputSanitizer.looksLikeAnswer(good, raw: c.raw), "\(c.id): \(good)")
            }
        }
    }
}
