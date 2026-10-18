import Foundation

/// Bot-free meeting notes: two local recordings (your mic and the
/// computer's audio), transcribed after the meeting, labelled "Me" / "Others", then summarised.
public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, transcribing, summarizing, ready, failed }

    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var app: String?
    public var status: Status
    public var error: String?
    /// Seconds between the meeting start and the first mic sample (aligns the two tracks).
    public var micOffset: Double = 0

    public init(id: String = UUID().uuidString, title: String, startedAt: Date = Date(), app: String? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.app = app; self.status = .recording
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

public struct Segment: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

/// Transcribers that return timed segments (needed for meetings).
public protocol SegmentTranscriber: Sendable {
    func transcribeSegments(wav: URL, language: String?) async throws -> [Segment]
}

struct VerboseJSON: Decodable {
    struct Seg: Decodable { let start: Double; let end: Double; let text: String }
    let segments: [Seg]?
    let text: String?
}

extension WhisperServerTranscriber: SegmentTranscriber {
    public func transcribeSegments(wav: URL, language: String?) async throws -> [Segment] {
        var form = Multipart()
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: try Data(contentsOf: wav))
        form.field("response_format", "verbose_json")
        form.field("temperature", "0.0")
        form.field("language", language ?? "auto")
        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 4 * 3600
        let (data, resp) = try await session.upload(for: req, from: form.finish())
        try checkHTTP(data, resp)
        let v = try JSONDecoder().decode(VerboseJSON.self, from: data)
        return (v.segments ?? []).map { Segment(speaker: "", start: $0.start, end: $0.end, text: TranscriptFilter.clean($0.text)) }
            .filter { !$0.text.isEmpty }
    }
}

extension OpenAITranscriber: SegmentTranscriber {
    public func transcribeSegments(wav: URL, language: String?) async throws -> [Segment] {
        var form = Multipart()
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: try Data(contentsOf: wav))
        form.field("model", model)
        form.field("response_format", "verbose_json")
        if let language { form.field("language", language) }
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3600
        let (data, resp) = try await session.upload(for: req, from: form.finish())
        try checkHTTP(data, resp)
        let v = try JSONDecoder().decode(VerboseJSON.self, from: data)
        return (v.segments ?? []).map { Segment(speaker: "", start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Energy-based voice activity detection. Each meeting track has one speaker side, so finding
/// speech regions and transcribing them one by one gives exact timestamps (whisper's own
/// timestamps drift across long silences).
public enum SpeechRegions {
    public static func detect(_ samples: [Float], sampleRate: Int = WAVEncoder.sampleRate,
                              frameMs: Int = 30, minGap: Double = 0.8, pad: Double = 0.2, minSpeech: Double = 0.3) -> [(start: Double, end: Double)] {
        let frame = sampleRate * frameMs / 1000
        guard samples.count >= frame else { return [] }
        let energies = stride(from: 0, to: samples.count - frame + 1, by: frame).map { AudioLevel.rms(samples[$0..<($0 + frame)]) }
        // Adaptive threshold: well above the noise floor (10th percentile), never below an absolute minimum.
        let floor = energies.sorted()[energies.count / 10]
        let threshold = max(0.004, floor * 4)
        var regions: [(Double, Double)] = []
        var start: Int?
        var lastSpeech = 0
        let gapFrames = Int(minGap * 1000) / frameMs
        for (i, e) in energies.enumerated() {
            if e >= threshold {
                if start == nil { start = i }
                lastSpeech = i
            } else if let s = start, i - lastSpeech > gapFrames {
                regions.append((Double(s), Double(lastSpeech + 1)))
                start = nil
            }
        }
        if let s = start { regions.append((Double(s), Double(lastSpeech + 1))) }
        let total = Double(samples.count) / Double(sampleRate)
        let f = Double(frameMs) / 1000
        return regions.map { (max(0, $0.0 * f - pad), min(total, $0.1 * f + pad)) }
            .filter { $0.1 - $0.0 >= minSpeech + 2 * pad - 0.01 }
            .map { (start: $0.0, end: $0.1) }
    }

    /// Transcribes each speech region of one track.
    public static func transcribe(samples: [Float], with asr: any Transcriber, language: String?, vocabulary: String? = nil,
                                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Segment] {
        let regions = detect(samples)
        var out: [Segment] = []
        for (i, r) in regions.enumerated() {
            let a = Int(r.start * Double(WAVEncoder.sampleRate)), b = min(samples.count, Int(r.end * Double(WAVEncoder.sampleRate)))
            let clip = AudioGain.normalise(Array(samples[a..<b]))
            let text = TranscriptFilter.clean(try await asr.transcribe(wav: WAVEncoder.encode(clip), language: language, prompt: vocabulary).text,
                                              likelySilence: AudioLevel.rms(clip) < 0.004)
            if !text.isEmpty { out.append(Segment(speaker: "", start: r.start, end: r.end, text: text)) }
            progress?(Double(i + 1) / Double(regions.count))
        }
        return out
    }
}

public enum MeetingTranscript {
    /// Merges the two channels by time. Without headphones the mic also hears the other side,
    /// so "Me" segments that duplicate an overlapping "Others" segment are dropped (echo).
    public static func merge(me: [Segment], others: [Segment]) -> [Segment] {
        let mine = me.map { var s = $0; s.speaker = "Me"; return s }
        let theirs = others.map { var s = $0; s.speaker = "Others"; return s }
        let deduped = mine.filter { m in
            !theirs.contains { o in
                o.start < m.end + 1 && m.start < o.end + 1
                    && AutoLearn.similarity(normal(m.text), normal(o.text)) > 0.6
            }
        }
        var merged: [Segment] = []
        for s in (deduped + theirs).sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, last.speaker == s.speaker, s.start - last.end < 2 {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    static func normal(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: "", options: .regularExpression)
    }

    public static func timestamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    public static func text(_ segments: [Segment]) -> String {
        segments.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Splits a transcript into chunks of roughly `words` words, on segment boundaries.
    public static func chunks(_ segments: [Segment], words: Int) -> [[Segment]] {
        var out: [[Segment]] = []
        var cur: [Segment] = []
        var n = 0
        for s in segments {
            let w = OutputSanitizer.wordCount(s.text)
            if n + w > words, !cur.isEmpty { out.append(cur); cur = []; n = 0 }
            cur.append(s)
            n += w
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

public enum MeetingSummary {
    /// Notes for one part of a long meeting (map step).
    public static func chunkMessages(_ transcript: String, part: Int, of total: Int) -> [ChatMessage] {
        [ChatMessage(role: "system", content: """
            You take notes on part \(part) of \(total) of a meeting transcript ("Me" is the user, "Others" are the other participants). \
            Write terse bullet notes of what was discussed, every decision, and every action item with its owner and due date if stated. \
            Keep timestamps like [12:34] for important moments. Only use facts from the transcript.
            """),
         ChatMessage(role: "user", content: transcript)]
    }

    /// The final summary (reduce step). `material` is the full transcript or the per-part notes.
    public static func finalMessages(_ material: String, title: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: """
            Write meeting notes in Markdown for "\(title)". "Me" is the user; "Others" are the other participants.
            Use exactly these sections:
            ## Summary
            2–4 sentences.
            ## Topics
            One "### topic" heading per topic with short bullets.
            ## Decisions
            Bullets. Write "None recorded." if there were none.
            ## Action items
            "- [ ] Owner: task (due date if mentioned)". Write "None recorded." if there were none.
            ## Follow-up draft
            A short follow-up message the user could send to the participants.
            Only use facts from the material. Cite important moments with their [mm:ss] timestamps.
            """),
         ChatMessage(role: "user", content: material)]
    }

    public static func titleMessages(_ transcriptStart: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: "Give this meeting a short, specific title (3–7 words). Output only the title, no quotes."),
         ChatMessage(role: "user", content: String(transcriptStart.prefix(3000)))]
    }

    /// Summarises a transcript, splitting long meetings into parts first.
    public static func summarize(_ segments: [Segment], title: String, llm: any LLMClient,
                                 chunkWords: Int = 2500) async throws -> String {
        let parts = MeetingTranscript.chunks(segments, words: chunkWords)
        let material: String
        if parts.count <= 1 {
            material = MeetingTranscript.text(segments)
        } else {
            var notes: [String] = []
            for (i, p) in parts.enumerated() {
                notes.append(try await llm.complete(chunkMessages(MeetingTranscript.text(p), part: i + 1, of: parts.count),
                                                    json: false, maxTokens: 900, contextTokens: 8192))
            }
            material = notes.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        }
        return try await llm.complete(finalMessages(material, title: title), json: false, maxTokens: 1500, contextTokens: 16384)
    }
}

/// Stored meetings: support/meetings/<id>/{meta.json, me.wav, others.wav, transcript.json, summary.md}
public final class MeetingStore: @unchecked Sendable {
    public let dir: URL

    public init(dir: URL = AppPaths.support.appendingPathComponent("meetings", isDirectory: true)) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func folder(_ id: String) -> URL {
        let f = dir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    public func micURL(_ id: String) -> URL { folder(id).appendingPathComponent("me.wav") }
    public func systemURL(_ id: String) -> URL { folder(id).appendingPathComponent("others.wav") }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func save(_ m: Meeting) {
        try? Self.enc.encode(m).write(to: folder(m.id).appendingPathComponent("meta.json"), options: .atomic)
    }

    public func list() -> [Meeting] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.compactMap { id in
            (try? Data(contentsOf: dir.appendingPathComponent("\(id)/meta.json"))).flatMap { try? Self.dec.decode(Meeting.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func meeting(_ id: String) -> Meeting? { list().first { $0.id == id } }

    public func saveTranscript(_ id: String, _ segments: [Segment]) {
        try? Self.enc.encode(segments).write(to: folder(id).appendingPathComponent("transcript.json"), options: .atomic)
    }

    public func transcript(_ id: String) -> [Segment] {
        (try? Data(contentsOf: dir.appendingPathComponent("\(id)/transcript.json"))).flatMap { try? Self.dec.decode([Segment].self, from: $0) } ?? []
    }

    public func saveSummary(_ id: String, _ md: String) {
        try? md.write(to: folder(id).appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    public func summary(_ id: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("\(id)/summary.md"), encoding: .utf8)
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
    }
}

/// Cross-meeting Q&A (spec: "Q&A with citations"): keyword retrieval over transcript passages, then the LLM answers.
public enum MeetingSearch {
    public struct Passage: Equatable, Sendable {
        public var meetingID: String
        public var title: String
        public var date: Date
        public var start: Double
        public var text: String
    }

    public static func passages(store: MeetingStore, wordsPerPassage: Int = 120) -> [Passage] {
        store.list().flatMap { m in
            MeetingTranscript.chunks(store.transcript(m.id), words: wordsPerPassage).map {
                Passage(meetingID: m.id, title: m.title, date: m.startedAt, start: $0.first?.start ?? 0,
                        text: $0.map { "\($0.speaker): \($0.text)" }.joined(separator: " "))
            }
        }
    }

    static func terms(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 2 && !VoiceProfile.stopwords.contains($0) }
    }

    /// BM25-style ranking.
    public static func rank(_ query: String, in passages: [Passage], limit: Int = 8) -> [Passage] {
        let q = Set(terms(query))
        guard !q.isEmpty, !passages.isEmpty else { return [] }
        let docs = passages.map { terms($0.text) }
        let avg = Double(docs.map(\.count).reduce(0, +)) / Double(docs.count)
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        let scored = zip(passages, docs).map { p, d -> (Passage, Double) in
            var tf: [String: Int] = [:]
            for t in d where q.contains(t) { tf[t, default: 0] += 1 }
            let score = tf.reduce(0.0) { acc, kv in
                let idf = log(1 + (n - Double(df[kv.key]!) + 0.5) / (Double(df[kv.key]!) + 0.5))
                let f = Double(kv.value)
                return acc + idf * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * Double(d.count) / avg))
            }
            return (p, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    public static func answerMessages(question: String, passages: [Passage]) -> [ChatMessage] {
        let ctx = passages.map {
            "[\($0.title) @ \(MeetingTranscript.timestamp($0.start)), \($0.date.formatted(date: .abbreviated, time: .omitted))] \($0.text)"
        }.joined(separator: "\n\n")
        return [ChatMessage(role: "system", content: """
            Answer the user's question using only these meeting excerpts. Cite each fact with its bracketed source, \
            e.g. [Weekly sync @ 12:34]. If the excerpts don't contain the answer, say so.
            """),
                ChatMessage(role: "user", content: "Excerpts:\n\(ctx)\n\nQuestion: \(question)")]
    }
}
