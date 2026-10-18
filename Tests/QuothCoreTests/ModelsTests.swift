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
}
