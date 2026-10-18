import AppKit
import OSLog
import QuothCore

private let log = Logger(subsystem: "app.quoth", category: "meetings")

/// Bot-free meeting notes: records your mic and the computer's audio as two tracks,
/// then transcribes, labels and summarises locally after the meeting.
@MainActor
final class MeetingController: ObservableObject {
    let store = MeetingStore()
    @Published var meetings: [Meeting] = []
    @Published var active: Meeting?
    @Published var progress: [String: String] = [:]

    private let system = SystemAudioRecorder()
    private let mic: AudioRecorder = { let r = AudioRecorder(); r.keepInMemory = false; return r }()
    private weak var dictation: DictationController?
    private let state: AppState
    var onMessage: ((String, Bool) -> Void)?
    var onChange: (() -> Void)?

    static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "Cisco-Systems.Spark": "Webex", "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack",
    ]

    init(state: AppState, dictation: DictationController) {
        self.state = state
        self.dictation = dictation
        reload()
        purgeOldAudio()
        // Meeting detection: suggest notes when a meeting app launches.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, let name = Self.meetingApps[id], id != "com.tinyspeck.slackmacgap" else { return }
            MainActor.assumeIsolated {
                guard let self, self.active == nil else { return }
                self.onMessage?("\(name) opened. Start meeting notes from the menu bar", false)
            }
        }
        // Recover meetings interrupted by a quit or crash.
        for m in meetings where m.status != .ready && m.status != .failed { Task { await process(m.id) } }
    }

    func reload() {
        meetings = store.list()
        onChange?()
    }

    var isRecording: Bool { active != nil }

    func start() async {
        guard active == nil else { return }
        guard SystemAudioRecorder.hasPermission else {
            SystemAudioRecorder.requestPermission()
            onMessage?("Allow Screen & System Audio Recording, then try again", true)
            return
        }
        let frontApp = NSWorkspace.shared.runningApplications.first { Self.meetingApps[$0.bundleIdentifier ?? ""] != nil }
        let appName = frontApp.flatMap { Self.meetingApps[$0.bundleIdentifier ?? ""] }
        var m = Meeting(title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))", app: appName)
        let t0 = SystemAudioRecorder.hostNow()
        do {
            try await system.start(to: store.systemURL(m.id), meetingStart: t0)
            let device = MicrophoneManager.bestDevice(preferred: state.settings.preferredMicUIDs)
            try mic.start(device: device, recordTo: store.micURL(m.id))
            m.micOffset = SystemAudioRecorder.hostNow() - t0
            // Starting system-audio capture (and plugging devices in or out) reconfigures audio,
            // which stops the engine: resume into the same file.
            mic.onDeviceLost = { [weak self] in
                guard let self, self.active != nil else { return }
                let next = MicrophoneManager.bestDevice(preferred: self.state.settings.preferredMicUIDs)
                do {
                    try self.mic.start(device: next, recordTo: nil, keepSamples: true)
                    log.info("meeting mic resumed on \(next?.name ?? "default", privacy: .public)")
                } catch {
                    log.error("meeting mic could not resume: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            await system.stop()
            onMessage?("Couldn't start meeting notes: \(error.localizedDescription)", true)
            return
        }
        system.onError = { [weak self] e in
            Task { @MainActor in self?.onMessage?("System audio stopped: \(e.localizedDescription)", true) }
        }
        store.save(m)
        active = m
        reload()
        onMessage?("Taking meeting notes. Let participants know.", false)
        log.info("meeting started \(m.id, privacy: .public)")
    }

    func stop() async {
        guard var m = active else { return }
        mic.onDeviceLost = nil
        _ = mic.stop()
        await system.stop()
        m.endedAt = Date()
        m.status = .transcribing
        store.save(m)
        active = nil
        reload()
        onMessage?("Meeting saved. Writing notes…", false)
        await process(m.id)
    }

    /// Transcribe both tracks, merge, title and summarise.
    func process(_ id: String) async {
        guard var m = store.meeting(id), let pipeline = dictation?.makePipeline(), let llm = dictation?.makeLLM(role: .meetings) else { return }
        func load(_ url: URL) -> [Float] { FileManager.default.contents(atPath: url.path).flatMap(WAVEncoder.decode) ?? [] }
        do {
            m.status = .transcribing
            store.save(m); reload()
            let lang = state.settings.languages.count == 1 ? state.settings.languages[0] : nil
            let vocab = state.personal.vocabulary().joined(separator: ", ")
            progress[id] = "Transcribing your audio…"
            var mine = try await SpeechRegions.transcribe(samples: load(store.micURL(id)), with: pipeline.transcriber,
                                                          language: lang, vocabulary: vocab.isEmpty ? nil : vocab)
            mine = mine.map { var s = $0; s.start += m.micOffset; s.end += m.micOffset; return s }
            progress[id] = "Transcribing the other participants…"
            let theirs = try await SpeechRegions.transcribe(samples: load(store.systemURL(id)), with: pipeline.transcriber,
                                                            language: lang, vocabulary: vocab.isEmpty ? nil : vocab)
            let merged = MeetingTranscript.merge(me: mine, others: theirs)
            store.saveTranscript(id, merged)
            guard !merged.isEmpty else {
                m.status = .failed; m.error = "No speech was recorded"
                store.save(m); progress[id] = nil; reload(); return
            }
            m.status = .summarizing
            store.save(m); reload()
            progress[id] = "Writing the summary…"
            let text = MeetingTranscript.text(merged)
            if let t = try? await llm.complete(MeetingSummary.titleMessages(text), json: false, maxTokens: 30, contextTokens: 8192) {
                let clean = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"#*")))
                if !clean.isEmpty { m.title = String(clean.prefix(80)) }
            }
            store.saveSummary(id, try await MeetingSummary.summarize(merged, title: m.title, llm: llm))
            m.status = .ready
            m.error = nil
            store.save(m)
            onMessage?("Notes ready: \(m.title)", false)
        } catch {
            m.status = .failed
            m.error = error.localizedDescription
            store.save(m)
            onMessage?("Meeting notes failed. Retry in Quoth → Meetings", true)
        }
        progress[id] = nil
        reload()
    }

    func ask(_ question: String) async -> String {
        let hits = MeetingSearch.rank(question, in: MeetingSearch.passages(store: store))
        guard !hits.isEmpty else { return "I couldn't find anything about that in your meetings." }
        guard let llm = dictation?.makeLLM(role: .meetings) else { return "No model configured." }
        return (try? await llm.complete(MeetingSearch.answerMessages(question: question, passages: hits),
                                        json: false, maxTokens: 500, contextTokens: 8192)) ?? "The model didn't answer."
    }

    func delete(_ id: String) {
        store.delete(id)
        reload()
    }

    /// Audio is kept 14 days for re-processing; notes and transcripts stay until deleted.
    private func purgeOldAudio() {
        for m in meetings where Date().timeIntervalSince(m.startedAt) > 14 * 86_400 {
            try? FileManager.default.removeItem(at: store.micURL(m.id))
            try? FileManager.default.removeItem(at: store.systemURL(m.id))
        }
    }
}
