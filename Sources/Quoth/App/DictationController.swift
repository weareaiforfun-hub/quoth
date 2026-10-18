import AppKit
import OSLog
import QuothCore

private let log = Logger(subsystem: "app.quoth", category: "dictation")

/// The push-to-talk state machine: hotkey → record → pipeline → paste → history.
@MainActor
final class DictationController {
    private let state: AppState
    private let hotkeys: HotkeyMonitor
    private let recorder = AudioRecorder()
    private let earshot: EarshotController
    let history: HistoryStore?

    private enum Mode { case idle, holding, awaitingSecondTap, handsFree, processing }
    private var mode: Mode = .idle {
        didSet { hotkeys.isActive = mode != .idle && mode != .processing }
    }
    private var pressedAt = Date()
    private var startedAt = Date()
    private var captured = CapturedContext()
    /// This dictation is a Command Mode instruction (trigger + Control).
    private var isCommand = false
    private var lastTransform: (original: String, result: String, name: String)?
    private var lastAutoTransform = Date.distantPast
    var onScratchpad: (() -> Void)?
    private let learner = AutoLearner()
    private var audioURL: URL?
    private var tapTimer: Task<Void, Never>?
    private var capTimer: Task<Void, Never>?
    private var silenceCheck: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var failedDevices: Set<String> = []

    private static let doubleTapWindow = 0.5
    /// Shorter than this counts as a tap, not a hold.
    private static let tapThreshold = 0.3
    /// Pressing another key within this window after the trigger cancels (Fn+Arrow etc.).
    private static let shortcutGrace = 1.0
    private static let maxSession: Double = 20 * 60

    init(state: AppState, hotkeys: HotkeyMonitor, earshot: EarshotController) {
        self.state = state
        self.hotkeys = hotkeys
        self.earshot = earshot
        history = try? HistoryStore()
        hotkeys.onEvent = { [weak self] in self?.handle($0) }
        recorder.onLevel = { [weak self] in self?.state.pushLevel($0) }
        recorder.onDeviceLost = { [weak self] in self?.deviceLost() }
        earshot.onStop = { [weak self] in self?.finish() }
        earshot.onCancel = { [weak self] in self?.cancel(reason: nil) }
        reloadHistory()
        recoverInterruptedRecordings()
    }

    // MARK: hotkey state machine

    private func handle(_ e: HotkeyEvent) {
        switch (e, mode) {
        case (.pasteLast, _):
            pasteLast()

        case (.commandModifier, .holding), (.commandModifier, .handsFree), (.commandModifier, .awaitingSecondTap):
            guard state.settings.commandModeEnabled else { break }
            isCommand = true
            state.commandActive = true

        case (.transform(let n), .idle):
            Task { await runTransform(number: n) }

        case (.viewDiff, _):
            if let t = lastTransform {
                ResultPanel.shared.show(.diff(title: "\(t.name): changes", parts: WordDiff.diff(t.original, t.result), result: t.result))
            } else {
                showMessage("No transform yet", isError: false)
            }

        case (.scratchpad, _):
            onScratchpad?()

        case (.triggerDown, .idle):
            pressedAt = Date()
            mode = .holding
            begin()

        case (.triggerDown, .awaitingSecondTap):
            tapTimer?.cancel()
            mode = .handsFree
            setPhase(.recording(handsFree: true))

        case (.triggerDown, .handsFree):
            finish()

        case (.triggerDown, .processing):
            break  // spec: ignore presses while the previous dictation is processing

        case (.triggerUp, .holding):
            let held = Date().timeIntervalSince(pressedAt)
            if held < Self.tapThreshold {
                guard state.settings.handsFreeEnabled else { cancel(reason: nil); return }
                mode = .awaitingSecondTap
                tapTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.doubleTapWindow * 1e9))
                    guard !Task.isCancelled, let self, self.mode == .awaitingSecondTap else { return }
                    self.cancel(reason: nil)  // a single short tap: nothing meant
                }
            } else {
                finish()
            }

        case (.escape, .holding), (.escape, .handsFree), (.escape, .awaitingSecondTap):
            cancel(reason: "Cancelled")

        case (.otherKey, .holding):
            if Date().timeIntervalSince(pressedAt) < Self.shortcutGrace { cancel(reason: nil) }

        default:
            break
        }
    }

    // MARK: recording

    private func begin() {
        let id = UUID().uuidString
        audioURL = state.settings.retention == .never ? nil : AppPaths.audio.appendingPathComponent("\(id).wav")
        let device = MicrophoneManager.bestDevice(preferred: state.settings.preferredMicUIDs, excluding: failedDevices)
        do {
            try recorder.start(device: device, recordTo: audioURL)
        } catch {
            mode = .idle
            showMessage("Microphone unavailable: \(error.localizedDescription)", isError: true)
            return
        }
        startedAt = Date()
        // Read the target field after the mic is running, so capture never delays recording.
        captured = ContextCapture.capture()
        if state.settings.playSounds { Sounds.start() }
        state.resetLevels()
        setPhase(.recording(handsFree: false))

        silenceCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.isRecordingMode else { return }
            if self.recorder.openingLevel(seconds: 1.5) < 0.0005 {
                self.showMessage("Mic hears nothing. Check your input device", isError: true, keepPhase: true)
            }
        }
        capTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.maxSession - 60) * 1e9))
            guard let self, !Task.isCancelled, self.isRecordingMode else { return }
            self.showMessage("1 minute left in this dictation", isError: false, keepPhase: true)
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, self.isRecordingMode else { return }
            self.finish()
        }
    }

    private var isRecordingMode: Bool { [.holding, .handsFree, .awaitingSecondTap].contains(mode) }

    private func deviceLost() {
        guard isRecordingMode else { return }
        // Fall back to the next-best mic and keep the audio recorded so far.
        let next = MicrophoneManager.bestDevice(preferred: state.settings.preferredMicUIDs, excluding: failedDevices)
        do {
            try recorder.start(device: next, recordTo: nil, keepSamples: true)
            showMessage("Switched to \(next?.name ?? "default mic")", isError: false, keepPhase: true)
        } catch {
            finish()
        }
    }

    private func stopTimers() {
        tapTimer?.cancel(); capTimer?.cancel(); silenceCheck?.cancel()
    }

    func cancel(reason: String?) {
        stopTimers()
        isCommand = false
        state.commandActive = false
        recorder.cancel()
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        mode = .idle
        if let reason { showMessage(reason, isError: false) } else { setPhase(.idle) }
    }

    /// Stop recording and run the pipeline.
    func finish() {
        guard isRecordingMode else { return }
        stopTimers()
        let samples = recorder.stop()
        let duration = Double(samples.count) / Double(WAVEncoder.sampleRate)
        if state.settings.playSounds { Sounds.stop() }
        guard duration > 0.25 else { cancel(reason: nil); return }
        mode = .processing
        setPhase(.processing)

        let ctx = captured
        if isCommand {
            isCommand = false
            Task {
                await runCommand(samples: samples, captured: ctx)
                state.commandActive = false
                mode = .idle
                if state.phase == .processing { setPhase(.idle) }
            }
            return
        }
        let record = DictationRecord(createdAt: startedAt, appName: ctx.app?.localizedName, appBundleID: ctx.app?.bundleIdentifier,
                                     duration: duration, audioPath: audioURL?.path)
        Task { await process(samples: samples, record: record, paste: true, captured: ctx) }
    }

    /// Debug/test hook: treat a WAV file as if it were just dictated into the frontmost app.
    func simulateDictation(wavPath: String, command: Bool = false) {
        guard mode == .idle, let data = FileManager.default.contents(atPath: wavPath),
              let samples = WAVEncoder.decode(data) else { return }
        let ctx = ContextCapture.capture()
        mode = .processing
        setPhase(.processing)
        if command {
            Task {
                await runCommand(samples: samples, captured: ctx)
                mode = .idle
                if state.phase == .processing { setPhase(.idle) }
            }
            return
        }
        let record = DictationRecord(appName: ctx.app?.localizedName, appBundleID: ctx.app?.bundleIdentifier,
                                     duration: Double(samples.count) / Double(WAVEncoder.sampleRate))
        Task { await process(samples: samples, record: record, paste: true, captured: ctx) }
    }

    // MARK: Command Mode & Transforms

    /// The language model for a role, honouring the text provider and per-role model choice.
    func makeLLM(role: ModelRole = .commands) -> (any LLMClient)? {
        let s = state.settings
        switch s.textProvider {
        case .local:
            return OllamaCleaner(baseURL: URL(string: s.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!,
                                 model: s.ollamaModel(for: role))
        case .cloud:
            guard let key = Keychain.apiKey(), let url = URL(string: s.cloudBaseURL) else { return nil }
            return ChatCompletionsCleaner(baseURL: url, model: s.cloudLLMModel, apiKey: key)
        }
    }

    private func runCommand(samples: [Float], captured: CapturedContext) async {
        guard let pipeline = makePipeline(), let llm = makeLLM() else {
            showMessage("Add an API key in Settings", isError: true); return
        }
        let instruction: String
        do {
            let r = try await pipeline.transcriber.transcribe(wav: WAVEncoder.encode(AudioGain.normalise(samples)),
                                                              language: state.settings.languages.count == 1 ? state.settings.languages[0] : nil,
                                                              prompt: nil)
            instruction = TranscriptFilter.clean(r.text)
        } catch {
            showMessage("Command Mode: transcription failed", isError: true); return
        }
        guard !instruction.isEmpty else { showMessage("Didn't catch that", isError: false); return }
        var selection = captured.selectedText
        if selection == nil || selection!.isEmpty { selection = await TextInserter.selectedText() }
        let hasSelection = !(selection ?? "").isEmpty
        log.info("command: \(instruction, privacy: .public) (selection: \(hasSelection))")

        let result: CommandResult
        if let q = CommandMode.explicitSearch(instruction) {
            result = CommandResult(action: .search, text: q)
        } else {
            do {
                let out = try await llm.complete(
                    CommandMode.messages(instruction: instruction, selection: selection, field: captured.fieldText, appName: captured.app?.localizedName),
                    json: true, maxTokens: 1200, contextTokens: 8192)
                guard let r = CommandMode.parse(out, hasSelection: hasSelection) else {
                    showMessage("Command Mode couldn't understand the reply", isError: true); return
                }
                result = r
            } catch {
                showMessage("Command Mode servers are busy", isError: true); return
            }
        }
        await perform(result, instruction: instruction, hasSelection: hasSelection, captured: captured)
    }

    private func perform(_ r: CommandResult, instruction: String, hasSelection: Bool, captured: CapturedContext) async {
        let bundle = captured.app?.bundleIdentifier
        switch r.action {
        case .search:
            if let url = CommandMode.searchURL(r.text) { NSWorkspace.shared.open(url) }
            setPhase(.idle)
        case .answer:
            setPhase(.idle)
            ResultPanel.shared.show(.answer(title: instruction, text: r.text))
        case .replace, .insert:
            if captured.isSecure || captured.element == nil {
                // No editable field: show it instead (spec: result in a notification).
                setPhase(.idle)
                ResultPanel.shared.show(.answer(title: instruction, text: r.text))
                return
            }
            if r.action == .replace && !hasSelection {
                guard (captured.fieldText ?? "").count < 4000 else {
                    ResultPanel.shared.show(.answer(title: instruction, text: r.text)); return
                }
                TextInserter.sendCommandA()
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            _ = await TextInserter.insert(r.text, bundleID: bundle)
            lastTransform = (captured.selectedText ?? captured.fieldText ?? "", r.text, "Command")
            setPhase(.idle)
        }
    }

    /// ⌥1 Polish, ⌥2 Prompt Engineer, ⌥3… custom transforms.
    func runTransform(number n: Int) async {
        let personal = state.personal
        let name: String
        let build: (String) -> [ChatMessage]
        switch n {
        case 1: name = "Polish"; build = { Transforms.polishMessages($0, rules: personal.polish) }
        case 2: name = "Prompt Engineer"; build = { Transforms.promptEngineerMessages($0) }
        default:
            guard n - 3 < personal.transforms.count else { showMessage("No transform on ⌥\(n)", isError: false); return }
            let t = personal.transforms[n - 3]
            name = t.name; build = { Transforms.customMessages($0, transform: t) }
        }
        guard let llm = makeLLM() else { showMessage("Add an API key in Settings", isError: true); return }

        // Input: selection → whole field → the last dictation from the past 60 s.
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var input = await TextInserter.selectedText()
        var prepare: (() async -> Void)?
        if input == nil {
            let ctx = ContextCapture.capture()
            if let field = ctx.fieldText, !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ctx.isSecure {
                input = field
                prepare = { TextInserter.sendCommandA(); try? await Task.sleep(nanoseconds: 80_000_000) }
            } else if let last = state.last, Date().timeIntervalSince(last.createdAt) < 60 + last.duration {
                input = last.final
                prepare = { TextInserter.sendCommandZ(); try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        guard let input, Transforms.validInput(input) else { showMessage("Select 1–1,000 words to transform", isError: false); return }
        setPhase(.processing)
        do {
            let out = try await llm.complete(build(input), json: false, maxTokens: 2000, contextTokens: 8192)
            let result = OutputSanitizer.sanitize(out, raw: input)
            guard !result.isEmpty else { throw QuothError.badResponse("empty") }
            await prepare?()
            _ = await TextInserter.insert(result, bundleID: bundle)
            lastTransform = (input, result, name)
            setPhase(.idle)
        } catch {
            showMessage("\(name) failed", isError: true)
        }
    }

    /// "Auto Apply After Dictation": runs one transform before paste, at most every 5 s.
    private func autoTransform(_ text: String) async -> String {
        guard let id = state.personal.autoApplyTransform, Date().timeIntervalSince(lastAutoTransform) > 5,
              let llm = makeLLM(), Transforms.validInput(text) else { return text }
        let msgs: [ChatMessage]
        switch id {
        case Transforms.polishID: msgs = Transforms.polishMessages(text, rules: state.personal.polish)
        case Transforms.promptEngineerID: msgs = Transforms.promptEngineerMessages(text)
        default:
            guard let t = state.personal.transforms.first(where: { $0.id.uuidString == id }) else { return text }
            msgs = Transforms.customMessages(text, transform: t)
        }
        lastAutoTransform = Date()
        guard let out = try? await withTimeout(15, { try await llm.complete(msgs, json: false, maxTokens: 2000, contextTokens: 8192) }) else {
            return text  // on failure paste the original
        }
        let result = OutputSanitizer.sanitize(out, raw: text)
        if !result.isEmpty { lastTransform = (text, result, "Auto transform") }
        return result.isEmpty ? text : result
    }

    // MARK: pipeline

    func makePipeline() -> DictationPipeline? {
        let s = state.settings
        let transcriber: any Transcriber
        switch s.speechProvider {
        case .local:
            transcriber = WhisperServerTranscriber(port: s.whisperPort)
        case .cloud:
            guard let key = Keychain.apiKey(), let url = URL(string: s.cloudBaseURL) else { return nil }
            transcriber = OpenAITranscriber(baseURL: url, model: s.cloudASRModel, apiKey: key)
        }
        guard let cleaner = makeLLM(role: .cleanup) as? any Cleaner else { return nil }
        return s.textProvider == .local
            ? DictationPipeline(transcriber: transcriber, cleaner: cleaner, llmTimeout: s.llmTimeoutLocal)
            : DictationPipeline(transcriber: transcriber, cleaner: cleaner, llmTimeout: s.llmTimeoutCloud, llmSecondsPerWord: 0.02)
    }

    func context(for record: DictationRecord, captured: CapturedContext?) -> CleanupContext {
        let category = StyleCategory.detect(bundleID: record.appBundleID, windowTitle: captured?.windowTitle)
        var ctx = CleanupContext(
            appName: record.appName, bundleID: record.appBundleID, windowTitle: captured?.windowTitle,
            preferRawFormatting: AppOverrides.lookup(record.appBundleID).preferRawFormatting ?? false,
            category: category, tone: state.personal.styles[category],
            vocabulary: state.personal.vocabulary())
        ctx.variant = state.settings.languageVariant
        if let captured, state.settings.contextAwareness {
            ctx.textBeforeCursor = captured.before
            ctx.textAfterCursor = captured.after
            ctx.hasSelection = !(captured.selectedText ?? "").isEmpty
            if ctx.isCodeEditor, let text = captured.fieldText {
                ctx.identifiers = DevFormatting.identifiers(in: text)
            }
        }
        return ctx
    }

    private func process(samples: [Float], record: DictationRecord, paste: Bool, captured: CapturedContext? = nil) async {
        var record = record
        defer {
            mode = .idle
            if state.phase == .processing { setPhase(.idle) }
        }
        guard let pipeline = makePipeline() else {
            record.status = .failed
            record.error = "Cloud provider selected but no API key set"
            save(record)
            showMessage("Add an API key in Settings", isError: true)
            return
        }
        let t0 = Date()
        do {
            var o = try await pipeline.run(samples: samples, level: state.settings.cleanupLevel,
                                           languages: state.settings.languages,
                                           context: context(for: record, captured: captured),
                                           personal: state.personal)
            if paste, !o.final.isEmpty, state.personal.autoApplyTransform != nil {
                o.final = await autoTransform(o.final)
            }
            record.raw = o.raw
            record.final = o.final
            record.words = OutputSanitizer.wordCount(o.final)
            record.asrMs = o.asrMs
            record.llmMs = o.llmMs
            record.status = o.final.isEmpty ? .empty : .ok
            record.error = o.fallbackReason
            guard !o.final.isEmpty else {
                save(record)
                showMessage("Didn't catch that", isError: false)
                return
            }
            state.last = record
            if paste { history?.recordStats(words: record.words, seconds: record.duration, app: record.appName) }
            countUses(entries: o.firedEntries)
            if let other = o.detectedOutsideSet { suggestLanguage(other) }
            var pasteMs = 0
            if paste {
                let t1 = Date()
                let result = await TextInserter.insert(o.final, bundleID: record.appBundleID)
                pasteMs = Int(Date().timeIntervalSince(t1) * 1000)
                switch result {
                case .pasted:
                    if let el = captured?.element, state.personal.autoLearn {
                        learner.watch(element: el, pasted: o.final) { [weak self] words in self?.learned(words) }
                    }
                case .secureField: showMessage("Won't type into password fields", isError: true)
                }
            }
            let total = Int(Date().timeIntervalSince(t0) * 1000)
            state.lastLatency = "ASR \(o.asrMs) ms · LLM \(o.llmMs) ms · paste \(pasteMs) ms · total \(total) ms"
            log.info("dictation \(record.words) words: \(self.state.lastLatency, privacy: .public)\(o.usedFallback ? " (fallback: \(o.fallbackReason ?? ""))" : "", privacy: .public)")
            save(record)
        } catch {
            record.status = .failed
            record.error = error.localizedDescription
            save(record)
            log.error("dictation failed: \(error.localizedDescription, privacy: .public)")
            showMessage("Transcription failed. Retry in History", isError: true)
        }
    }

    /// "Speaking a different language?" at most once a day.
    private func suggestLanguage(_ code: String) {
        let key = "lastLanguageSuggestion"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        showMessage("Speaking \(Languages.name(code))? Add it in Settings", isError: false)
    }

    private func countUses(entries: [UUID]) {
        guard !entries.isEmpty else { return }
        for i in state.personal.dictionary.indices where entries.contains(state.personal.dictionary[i].id) {
            state.personal.dictionary[i].uses += 1
        }
    }

    private func learned(_ words: [String]) {
        var added: [String] = []
        for w in words {
            let e = DictionaryEntry(word: w, autoLearned: true)
            if state.personal.validate(e) == nil {
                state.personal.dictionary.append(e)
                added.append(w)
            }
        }
        if !added.isEmpty { showMessage("Learned: \(added.joined(separator: ", "))", isError: false) }
    }

    private func save(_ record: DictationRecord) {
        guard state.settings.retention != .never else { return }
        history?.upsert(record)
        reloadHistory()
    }

    func reloadHistory() {
        let r = state.settings.retention
        history?.purge(audioMaxAge: r == .day ? 86_400 : 14 * 86_400, rowMaxAge: r == .day ? 86_400 : nil)
        state.history = history?.recent() ?? []
    }

    // MARK: actions from menu / Hub

    func pasteLast() {
        guard let last = state.last ?? state.history.first(where: { $0.status == .ok }) else { return }
        Task { _ = await TextInserter.insert(last.final, bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    }

    /// Undo the paste and insert the raw transcript instead.
    func undoAIEdit() {
        guard let last = state.last, !last.raw.isEmpty else { return }
        TextInserter.sendCommandZ()
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            _ = await TextInserter.insert(SpokenPunctuation.apply(last.raw), bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
    }

    /// Re-run a failed (or any) dictation from its saved audio; result goes to the clipboard.
    func retry(_ record: DictationRecord) async {
        guard let path = record.audioPath, let data = FileManager.default.contents(atPath: path),
              let samples = WAVEncoder.decode(data) else {
            showMessage("No audio saved for this dictation", isError: true)
            return
        }
        mode = .processing
        setPhase(.processing)
        await process(samples: samples, record: record, paste: false)
        if let updated = state.history.first(where: { $0.id == record.id }), updated.status == .ok {
            TextInserter.copyToClipboard(updated.final)
            showMessage("Copied to clipboard", isError: false)
        }
    }

    /// WAV files on disk with no history row were interrupted by a quit or crash.
    private func recoverInterruptedRecordings() {
        guard let history else { return }
        let known = Set(history.recent(limit: 100_000).compactMap(\.audioPath))
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.audio, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in files where url.pathExtension == "wav" && !known.contains(url.path) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size > 44 + 16_000 else { try? FileManager.default.removeItem(at: url); continue }
            // Fix the header (sizes were never written) so the file can be decoded.
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.write(contentsOf: WAVEncoder.header(dataBytes: size - 44))
                try? h.close()
            }
            history.upsert(DictationRecord(createdAt: created, duration: Double(size - 44) / 32_000, status: .failed,
                                           error: "Interrupted. Tap retry", audioPath: url.path))
        }
        reloadHistory()
    }

    // MARK: UI helpers

    private func setPhase(_ p: Phase) {
        state.phase = p
        earshot.refresh()
    }

    func showMessage(_ text: String, isError: Bool, keepPhase: Bool = false) {
        let previous = state.phase
        setPhase(.message(text, isError: isError))
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: keepPhase ? 1_800_000_000 : 2_500_000_000)
            guard let self, !Task.isCancelled, case .message = self.state.phase else { return }
            if keepPhase, self.isRecordingMode {
                self.setPhase(previous)
            } else if self.mode == .processing {
                self.setPhase(.processing)
            } else {
                self.setPhase(.idle)
            }
        }
    }
}

enum Sounds {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
}
