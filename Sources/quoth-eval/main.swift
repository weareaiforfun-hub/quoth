// Runs the cleanup stage over Evals/cleanup-golden.jsonl and scores it.
//
//   swift run quoth-eval                       # local Ollama, model from settings
//   swift run quoth-eval --builtin             # the app's built-in llama-server (must be running)
//   swift run quoth-eval --model gemma3:12b
//   swift run quoth-eval --cloud               # cloud provider from settings + keychain key
//   swift run quoth-eval --verbose --only no-answer
//   swift run quoth-eval --audio clip.wav       # full pipeline (needs whisper-server running)
import Foundation
import QuothCore

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}

let settings = SettingsStore.load()
let cloud = flag("--cloud")
let builtin = flag("--builtin")
let verbose = flag("--verbose")
let only = option("--only")
let level = option("--level").flatMap(CleanupLevel.init(rawValue:)) ?? .light
let file = option("--file") ?? "Evals/cleanup-golden.jsonl"

let cleaner: any Cleaner
let label: String
if cloud {
    guard let key = Keychain.apiKey() ?? ProcessInfo.processInfo.environment["QUOTH_API_KEY"] else {
        print("No API key: set one in the app's Settings or export QUOTH_API_KEY"); exit(1)
    }
    let model = option("--model") ?? settings.cloudLLMModel
    cleaner = ChatCompletionsCleaner(baseURL: URL(string: settings.cloudBaseURL)!, model: model, apiKey: key)
    label = "cloud \(model)"
} else if builtin {
    let c = LlamaServer.client(port: settings.llamaPort, modelPath: settings.llamaModelPath)
    guard await LlamaServer.loadedModel(port: settings.llamaPort) == c.model else {
        print("llama-server isn't serving \(c.model) on port \(settings.llamaPort): start Quoth with the built-in engine first"); exit(1)
    }
    cleaner = c
    label = "built-in \(c.model)"
} else {
    let model = option("--model") ?? settings.ollamaModel
    let c = OllamaCleaner(baseURL: URL(string: settings.ollamaBaseURL)!, model: model)
    await c.warmUp()
    cleaner = c
    label = "ollama \(model)"
}

if let audio = option("--audio") {
    // End-to-end: WAV → ASR → cleanup, with per-stage timings.
    guard let data = FileManager.default.contents(atPath: audio), let samples = WAVEncoder.decode(data) else {
        print("cannot read 16 kHz mono 16-bit WAV at \(audio)"); exit(1)
    }
    let transcriber: any Transcriber = cloud
        ? OpenAITranscriber(baseURL: URL(string: settings.cloudBaseURL)!, model: settings.cloudASRModel,
                            apiKey: Keychain.apiKey() ?? ProcessInfo.processInfo.environment["QUOTH_API_KEY"] ?? "")
        : WhisperServerTranscriber(port: settings.whisperPort)
    let p = DictationPipeline(transcriber: transcriber, cleaner: cleaner, llmTimeout: settings.llmTimeout)
    let langs = option("--languages").map { $0.components(separatedBy: ",") } ?? option("--language").map { [$0] } ?? settings.languages
    for run in 1...2 {
        let o = try await p.run(samples: samples, level: level, languages: langs, context: .init())
        print("run \(run): ASR \(o.asrMs) ms, LLM \(o.llmMs) ms\(o.usedFallback ? " (fallback: \(o.fallbackReason ?? ""))" : "")")
        if run == 2 { print("lang:  \(o.language ?? "?")\(o.detectedOutsideSet.map { " (detected outside set: \($0))" } ?? "")\nraw:   \(o.raw)\nfinal: \(o.final)") }
    }
    exit(0)
}

if flag("--commands") {
    // Command Mode: action routing and output sanity, with the LLM used for commands.
    struct CmdCase: Decodable {
        let id: String; let instruction: String; let selection: String?; let field: String?
        let action: String; let must_contain: [String]?; let must_not_contain: [String]?; let max_words: Int?
    }
    guard let llm = cleaner as? any LLMClient else { print("cleaner is not an LLM client"); exit(1) }
    let lines = (try? String(contentsOfFile: "Evals/command-golden.jsonl", encoding: .utf8)) ?? ""
    var pass = 0, total = 0
    for line in lines.split(separator: "\n") {
        guard let c = try? JSONDecoder().decode(CmdCase.self, from: Data(line.utf8)) else { continue }
        total += 1
        let t = Date()
        var result: CommandResult?
        if let q = CommandMode.explicitSearch(c.instruction) {
            result = CommandResult(action: .search, text: q)
        } else {
            let out = try? await llm.complete(CommandMode.messages(instruction: c.instruction, selection: c.selection, field: c.field, appName: nil),
                                              json: true, maxTokens: 800, contextTokens: 8192)
            result = out.flatMap { CommandMode.parse($0, hasSelection: !(c.selection ?? "").isEmpty) }
        }
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        var problems: [String] = []
        if result?.action.rawValue != c.action { problems.append("action \(result?.action.rawValue ?? "nil") ≠ \(c.action)") }
        let text = result?.text ?? ""
        for m in c.must_contain ?? [] where !text.localizedCaseInsensitiveContains(m) { problems.append("missing \(m.debugDescription)") }
        for m in c.must_not_contain ?? [] where text.localizedCaseInsensitiveContains(m) { problems.append("contains \(m.debugDescription)") }
        if let mw = c.max_words, OutputSanitizer.wordCount(text) > mw { problems.append("too long") }
        if problems.isEmpty { pass += 1 }
        print("\(problems.isEmpty ? "✓" : "✗") \(c.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%5d", ms)) ms  \(problems.joined(separator: ", "))")
        if verbose || !problems.isEmpty { print("    → \(text.replacingOccurrences(of: "\n", with: "⏎"))") }
    }
    print("\n\(pass)/\(total) passed")
    exit(pass == total ? 0 : 1)
}

if let me = option("--meeting") {
    // Meeting pipeline: --meeting me.wav others.wav → transcript, summary, a question.
    let others = args.removeFirst()
    guard let llm = cleaner as? any LLMClient else { exit(1) }
    let asr = WhisperServerTranscriber(port: settings.whisperPort)
    let t0 = Date()
    func load(_ p: String) -> [Float] { WAVEncoder.decode(FileManager.default.contents(atPath: p)!)! }
    let mine = try await SpeechRegions.transcribe(samples: load(me), with: asr, language: "en")
    let theirs = try await SpeechRegions.transcribe(samples: load(others), with: asr, language: "en")
    let merged = MeetingTranscript.merge(me: mine, others: theirs)
    print("== transcript (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)\n\(MeetingTranscript.text(merged))\n")
    let t1 = Date()
    let title = (try? await llm.complete(MeetingSummary.titleMessages(MeetingTranscript.text(merged)), json: false, maxTokens: 30, contextTokens: 8192)) ?? "?"
    let md = try await MeetingSummary.summarize(merged, title: title, llm: llm)
    print("== \(title) (\(Int(Date().timeIntervalSince(t1) * 1000)) ms)\n\(md)\n")
    let store = MeetingStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var m = Meeting(title: title); m.status = .ready
    store.save(m); store.saveTranscript(m.id, merged)
    let q = option("--ask") ?? "Who is writing the release notes?"
    let hits = MeetingSearch.rank(q, in: MeetingSearch.passages(store: store))
    let answer = try await llm.complete(MeetingSearch.answerMessages(question: q, passages: hits), json: false, maxTokens: 300, contextTokens: 8192)
    print("== Q: \(q)\n\(answer)")
    exit(0)
}

if flag("--transforms") {
    guard let llm = cleaner as? any LLMClient else { exit(1) }
    let rambling = "so um basically I want you to like write me a python script that goes through a folder and finds all the images and then resizes them to like 800 pixels wide but keep the aspect ratio and oh it should skip files that are already small enough and save them into a new folder called resized"
    let messy = "I wanted to let you know that, as I mentioned before, the launch which we had planned is going to be delayed, and the reason it is delayed is because the vendor was late with the parts, so we will now launch in March instead."
    for (name, msgs) in [("polish", Transforms.polishMessages(messy, rules: PolishRules())),
                         ("prompt engineer", Transforms.promptEngineerMessages(rambling)),
                         ("custom: tweet", Transforms.customMessages(messy, transform: TransformPrompt(name: "Tweet", instruction: "Rewrite as a single tweet under 280 characters")))] {
        let t = Date()
        let out = (try? await llm.complete(msgs, json: false, maxTokens: 800, contextTokens: 8192)) ?? "(error)"
        print("== \(name) (\(Int(Date().timeIntervalSince(t) * 1000)) ms)\n\(out)\n")
    }
    exit(0)
}

guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { print("cannot read \(file)"); exit(1) }
let cases = CleanupCase.load(jsonl: text).filter { only == nil || $0.category == only || $0.id == only }

print("Evaluating \(cases.count) cases with \(label), level \(level.rawValue)\n")
let results = await ModelBench.runCleanup(cleaner: cleaner, model: label, cases: cases, level: level) { r in
    guard let v = r.verdict, let c = cases.first(where: { $0.id == r.caseID }) else { return }
    print("\(v.symbol) \(r.caseID.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%5d", r.ms)) ms  \(v.problems.joined(separator: ", "))")
    if verbose || !v.sameWords || v.serious {
        print("    raw:      \(c.raw.replacingOccurrences(of: "\n", with: "⏎"))")
        print("    expected: \(c.expected.replacingOccurrences(of: "\n", with: "⏎"))")
        print("    got:      \(r.output.replacingOccurrences(of: "\n", with: "⏎"))")
    }
}
let sum = ModelBench.summarize(results, model: label)
var byCategory: [String: (Int, Int)] = [:]
for r in results {
    guard let c = cases.first(where: { $0.id == r.caseID }), let v = r.verdict else { continue }
    var e = byCategory[c.category] ?? (0, 0)
    e.1 += 1
    if v.sameWords && !v.serious { e.0 += 1 }
    byCategory[c.category] = e
}
print("""

Legend: ✓ exact  ≈ same words (punctuation/case differ)  · different  ✗ hard failure

Exact:       \(sum.exact)/\(sum.cases)
Same words:  \(sum.sameWords)/\(sum.cases)
Hard fails:  \(sum.serious)   (answered, added content, or fell back)
Latency:     p50 \(sum.p50ms) ms   p90 \(sum.p90ms) ms   max \(results.map(\.ms).max() ?? 0) ms

By category (same words, no hard failure):
""")
for (k, v) in byCategory.sorted(by: { $0.key < $1.key }) { print("  \(k.padding(toLength: 20, withPad: " ", startingAt: 0)) \(v.0)/\(v.1)") }
exit(sum.serious == 0 ? 0 : 1)
