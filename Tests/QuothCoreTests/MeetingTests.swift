import Foundation
import Testing
@testable import QuothCore

@Suite struct MeetingTests {
    @Test func mergeLabelsOrdersAndDropsEcho() {
        let me = [Segment(speaker: "", start: 0, end: 3, text: "Hi everyone, quick update."),
                  Segment(speaker: "", start: 10.2, end: 13, text: "We should ship on Friday"),          // echo of Others
                  Segment(speaker: "", start: 20, end: 24, text: "Agreed, I'll write the release notes.")]
        let others = [Segment(speaker: "", start: 4, end: 9, text: "Thanks. Where are we on the launch?"),
                      Segment(speaker: "", start: 10, end: 13, text: "We should ship on Friday."),
                      Segment(speaker: "", start: 13.5, end: 16, text: "Does that work?")]
        let merged = MeetingTranscript.merge(me: me, others: others)
        #expect(merged.map(\.speaker) == ["Me", "Others", "Me"])
        #expect(merged[1].text == "Thanks. Where are we on the launch? We should ship on Friday. Does that work?")
        #expect(!merged.contains { $0.speaker == "Me" && $0.text.contains("ship on Friday") })
    }

    @Test func speechRegions() {
        let sr = 16_000
        func tone(_ secs: Double) -> [Float] { (0..<Int(secs * Double(sr))).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
        func silence(_ secs: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(secs * Double(sr))) }
        let audio = silence(2) + tone(1.5) + silence(0.4) + tone(1) + silence(3) + tone(2) + silence(1) + tone(0.1) + silence(1)
        let r = SpeechRegions.detect(audio)
        // 0.4 s gap is merged; the 0.1 s blip is dropped.
        #expect(r.count == 2)
        #expect(abs(r[0].start - 1.8) < 0.1 && abs(r[0].end - 5.1) < 0.1)
        #expect(abs(r[1].start - 7.7) < 0.1 && abs(r[1].end - 10.1) < 0.1)
        #expect(SpeechRegions.detect(silence(5)).isEmpty)
    }

    @Test func wavWriterPadsGaps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let w = try WAVFileWriter(url: url)
        w.append([Float](repeating: 0.5, count: 16_000), at: 0)      // 0–1 s
        w.append([Float](repeating: 0.5, count: 8_000), at: 3)       // 3–3.5 s: 2 s of silence before
        w.append([Float](repeating: 0.5, count: 100), at: 3.5001)    // jitter: no padding
        w.finish()
        let samples = WAVEncoder.decode(try Data(contentsOf: url))!
        #expect(samples.count == 16_000 + 32_000 + 8_000 + 100)
        #expect(abs(samples[20_000]) < 0.001 && abs(samples[50_000] - 0.5) < 0.01)
        #expect(abs(w.duration - 3.50625) < 0.001)
    }

    @Test func textAndChunks() {
        let segs = (0..<10).map { Segment(speaker: "Me", start: Double($0 * 70), end: Double($0 * 70 + 5), text: "one two three four five") }
        #expect(MeetingTranscript.text(Array(segs.prefix(1))) == "[00:00] Me: one two three four five")
        #expect(MeetingTranscript.timestamp(3725) == "1:02:05")
        let chunks = MeetingTranscript.chunks(segs, words: 12)
        #expect(chunks.count == 5 && chunks.allSatisfy { $0.count == 2 })
    }

    @Test func storeRoundTrip() {
        let store = MeetingStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var m = Meeting(title: "Weekly sync", app: "zoom.us")
        m.status = .ready
        store.save(m)
        store.saveTranscript(m.id, [Segment(speaker: "Me", start: 1, end: 2, text: "Hello")])
        store.saveSummary(m.id, "## Summary\nShort.")
        #expect(store.list().map(\.title) == ["Weekly sync"])
        #expect(store.transcript(m.id).first?.text == "Hello")
        #expect(store.summary(m.id)?.hasPrefix("## Summary") == true)
        store.delete(m.id)
        #expect(store.list().isEmpty)
    }

    @Test func searchRanksRelevantPassages() {
        let store = MeetingStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = Meeting(title: "Pricing review")
        let b = Meeting(title: "Hiring sync")
        store.save(a); store.save(b)
        store.saveTranscript(a.id, [Segment(speaker: "Others", start: 65, end: 70, text: "We agreed the pro plan price will be twelve dollars per month.")])
        store.saveTranscript(b.id, [Segment(speaker: "Me", start: 5, end: 9, text: "We need to hire two backend engineers this quarter.")])
        let ps = MeetingSearch.passages(store: store)
        let top = MeetingSearch.rank("what price did we agree for the pro plan?", in: ps)
        #expect(top.first?.title == "Pricing review")
        #expect(top.count == 1)
        let msgs = MeetingSearch.answerMessages(question: "price?", passages: top)
        #expect(msgs[1].content.contains("[Pricing review @ 01:05"))
    }

    @Test func summarizeUsesMapReduceForLongMeetings() async throws {
        actor Calls { var n = 0; func inc() { n += 1 } }
        struct FakeLLM: LLMClient {
            let calls: Calls
            func complete(_ m: [ChatMessage], json: Bool, maxTokens: Int, contextTokens: Int?) async throws -> String {
                await calls.inc()
                return m[0].content.hasPrefix("You take notes on part") ? "- notes" : "## Summary\nDone."
            }
        }
        let calls = Calls()
        let segs = (0..<6).map { Segment(speaker: "Me", start: Double($0), end: Double($0) + 1, text: String(repeating: "word ", count: 100)) }
        let md = try await MeetingSummary.summarize(segs, title: "T", llm: FakeLLM(calls: calls), chunkWords: 250)
        #expect(md.contains("## Summary"))
        #expect(await calls.n == 4)   // 3 parts + 1 final
    }
}
