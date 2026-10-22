import AppKit
import AVFoundation
import SwiftUI
import QuothCore

enum HubSection: String, CaseIterable, Identifiable {
    case features = "Features"
    case history = "History"
    case insights = "Insights"
    case meetings = "Meetings"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case transforms = "Transforms"
    case models = "Models"
    case settings = "Settings"
    case setup = "Setup"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .features: "square.grid.2x2"
        case .history: "clock"
        case .insights: "chart.bar"
        case .meetings: "person.2.wave.2"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .style: "textformat"
        case .transforms: "wand.and.stars"
        case .models: "cpu"
        case .settings: "gearshape"
        case .setup: "checkmark.shield"
        }
    }
}

struct HubView: View {
    @ObservedObject var state: AppState
    let controller: DictationController
    @ObservedObject var meetings: MeetingController
    private var section: Binding<HubSection?> {
        Binding(get: { HubSection(rawValue: state.hubSection ?? "") ?? (Permissions.allGranted ? .features : .setup) },
                set: { state.hubSection = $0?.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(HubSection.allCases, selection: section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch section.wrappedValue ?? .features {
            case .features: FeaturesView(state: state)
            case .history: HistoryView(state: state, controller: controller)
            case .insights: InsightsView(state: state, controller: controller)
            case .meetings: MeetingsView(meetings: meetings)
            case .dictionary: DictionaryView(state: state)
            case .snippets: SnippetsView(state: state)
            case .style: StyleView(state: state)
            case .transforms: TransformsView(state: state)
            case .models: ModelsView(state: state)
            case .settings: SettingsView(state: state)
            case .setup: SetupView(state: state)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: History

struct HistoryView: View {
    @ObservedObject var state: AppState
    let controller: DictationController
    @State private var player: AVAudioPlayer?
    @State private var showRaw: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.title2.bold())
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !state.history.isEmpty {
                    Button("Delete All", role: .destructive) {
                        controller.history?.deleteAll()
                        controller.reloadHistory()
                    }
                }
            }
            .padding(20)
            if !state.lastLatency.isEmpty {
                Text("Last: \(state.lastLatency)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            if state.history.isEmpty {
                ContentUnavailableView("No dictations yet",
                                       systemImage: "waveform",
                                       description: Text("Hold \(state.settings.hotkey.title), speak, and release."))
            } else {
                List(state.history) { r in row(r) }
                    .listStyle(.inset)
            }
        }
    }

    private var summary: String {
        let words = state.history.reduce(0) { $0 + $1.words }
        return "\(state.history.count) dictations · \(words) words"
    }

    @ViewBuilder private func row(_ r: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(r.createdAt, style: .time).font(.caption.monospacedDigit())
                Text(r.createdAt, style: .date).font(.caption)
                if let app = r.appName { Text("· \(app)").font(.caption) }
                Text("· \(String(format: "%.1f", r.duration)) s").font(.caption)
                Spacer()
                if r.asrMs > 0 { Text("\(r.asrMs + r.llmMs) ms").font(.caption.monospacedDigit()) }
            }
            .foregroundStyle(.secondary)

            switch r.status {
            case .failed:
                Text(r.error ?? "Failed").foregroundStyle(.orange)
            case .empty:
                Text("(nothing heard)").foregroundStyle(.secondary)
            case .ok:
                Text(showRaw.contains(r.id) ? r.raw : r.final)
                    .textSelection(.enabled)
                    .foregroundStyle(showRaw.contains(r.id) ? .secondary : .primary)
                if let note = r.error {
                    Text("Cleanup skipped: \(note)").font(.caption).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 12) {
                if r.status == .ok {
                    Button("Copy") { TextInserter.copyToClipboard(r.final) }
                    Button("Copy raw") { TextInserter.copyToClipboard(r.raw) }
                    Button(showRaw.contains(r.id) ? "Show cleaned" : "Show raw") {
                        if showRaw.contains(r.id) { showRaw.remove(r.id) } else { showRaw.insert(r.id) }
                    }
                }
                if r.audioPath != nil {
                    Button("Play") { play(r) }
                    Button("Retry") { Task { await controller.retry(r) } }
                }
                Spacer()
                Button("Delete") {
                    controller.history?.delete(id: r.id)
                    controller.reloadHistory()
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    private func play(_ r: DictationRecord) {
        guard let p = r.audioPath else { return }
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: p))
        player?.play()
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var mics: [AudioInputDevice] = MicrophoneManager.inputDevices()

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: $state.settings.hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if state.settings.hotkey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so macOS doesn't open the emoji picker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Double-tap for hands-free mode", isOn: $state.settings.handsFreeEnabled)
                Picker("Auto Cleanup", selection: $state.settings.cleanupLevel) {
                    Text("None: raw transcript").tag(CleanupLevel.none)
                    Text("Light: remove fillers, fix grammar").tag(CleanupLevel.light)
                    Text("Medium: also reword for clarity").tag(CleanupLevel.medium)
                }
                LanguagesPicker(selection: $state.settings.languages)
                Picker("Variant", selection: $state.settings.languageVariant) {
                    ForEach(LanguageVariant.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("No languages = detect any language. One = pinned (about 0.5 s faster locally). Several = detect, but only among these.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play sounds", isOn: $state.settings.playSounds)
            }

            Section("Microphone priority") {
                ForEach(rankedMics, id: \.uid) { mic in
                    HStack {
                        Text(mic.name)
                        if mic.isVirtual { Text("virtual").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { move(mic, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(mic, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    }
                }
                Text("Quoth uses the highest available device and falls back if it's unplugged.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Models") {
                Text("Choose speech and language models, download new ones and compare them in the **Models** tab.")
                    .foregroundStyle(.secondary)
                Stepper("Cleanup timeout: \(state.settings.llmTimeoutLocal, specifier: "%.1f") s + 0.08 s per word (on this Mac)",
                        value: $state.settings.llmTimeoutLocal, in: 1...15, step: 0.5)
                Stepper("Cleanup timeout: \(state.settings.llmTimeoutCloud, specifier: "%.1f") s + 0.02 s per word (cloud)",
                        value: $state.settings.llmTimeoutCloud, in: 0.5...10, step: 0.5)
            }

            PowerSettingsSection(state: state)

            Section("Earshot pill") {
                Toggle("Show the Earshot pill at all times", isOn: $state.settings.earshotAlwaysVisible)
                Toggle("Hide the Earshot pill from screen recordings", isOn: $state.settings.hideEarshotFromScreenCapture)
            }

            Section("Privacy") {
                Picker("History", selection: $state.settings.retention) {
                    ForEach(Retention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Reveal data folder") { NSWorkspace.shared.open(AppPaths.support) }
            }
        }
        .formStyle(.grouped)
        .onAppear { mics = MicrophoneManager.inputDevices() }
    }

    private var rankedMics: [AudioInputDevice] {
        let order = state.settings.preferredMicUIDs
        return mics.sorted { a, b in
            let ia = order.firstIndex(of: a.uid) ?? (a.isVirtual ? 2000 : 1000)
            let ib = order.firstIndex(of: b.uid) ?? (b.isVirtual ? 2000 : 1000)
            return ia < ib
        }
    }

    private func move(_ mic: AudioInputDevice, by delta: Int) {
        var order = rankedMics.map(\.uid)
        guard let i = order.firstIndex(of: mic.uid) else { return }
        let j = max(0, min(order.count - 1, i + delta))
        order.swapAt(i, j)
        state.settings.preferredMicUIDs = order
    }
}

// MARK: Setup

struct SetupView: View {
    @ObservedObject var state: AppState
    @State private var micStatus = Permissions.microphone
    // Every permission is tracked as state and re-read each second, so a grant made in
    // System Settings shows up here without reopening the window.
    @State private var accessibility = Permissions.accessibility
    @State private var inputMonitoring = Permissions.inputMonitoring
    @State private var screenRecording = SystemAudioRecorder.hasPermission

    var body: some View {
        Form {
            Section {
                Text("Quoth needs three permissions (the fourth, for meeting notes, is optional). Grant each, then come back; this page updates by itself.")
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                row("Microphone", "To hear you while you hold the hotkey.", granted: micStatus == .authorized) {
                    if micStatus == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone(); micStatus = Permissions.microphone }
                    } else {
                        Permissions.openSettings("Privacy_Microphone")
                    }
                }
                row("Accessibility", "To paste text into the focused app and check for password fields.",
                    granted: accessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openSettings("Privacy_Accessibility")
                }
                row("Input Monitoring", "To notice when you hold the hotkey.", granted: inputMonitoring) {
                    Permissions.requestInputMonitoring()
                    Permissions.openSettings("Privacy_ListenEvent")
                }
                row("Screen & System Audio Recording (optional)", "Only for meeting notes: records what other participants say. No video is kept.",
                    granted: screenRecording) {
                    SystemAudioRecorder.requestPermission()
                    Permissions.openSettings("Privacy_ScreenCapture")
                }
            }
            Section("Engines") {
                LabeledContent("Speech model", value: state.settings.speechProvider == .local
                               ? "\(ModelCatalog.speechInfo(forPath: state.settings.whisperModelPath)?.name ?? "Whisper"): \(state.whisperStatus)" : "Cloud")
                LabeledContent("Cleanup model", value: state.settings.textProvider == .local ? state.settings.ollamaModel : state.settings.cloudLLMModel)
            }
            Section("Try it") {
                Text("Click into any text field, hold \(state.settings.hotkey.title), say “um so let's meet at two actually three”, and release.")
                Text("Double-tap the hotkey for hands-free; tap again to stop. Esc cancels. ⌃⌘V pastes the last transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            micStatus = Permissions.microphone
            accessibility = Permissions.accessibility
            inputMonitoring = Permissions.inputMonitoring
            screenRecording = SystemAudioRecorder.hasPermission
        }
    }

    private func row(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

struct LanguagesPicker: View {
    @Binding var selection: [String]

    var body: some View {
        LabeledContent("Languages") {
            Menu(selection.isEmpty ? "Auto-detect" : selection.map(Languages.name).joined(separator: ", ")) {
                Button("Auto-detect (clear)") { selection = [] }
                Divider()
                ForEach(Languages.all, id: \.code) { lang in
                    Button {
                        if let i = selection.firstIndex(of: lang.code) { selection.remove(at: i) } else { selection.append(lang.code) }
                    } label: {
                        if selection.contains(lang.code) { Label(lang.name, systemImage: "checkmark") } else { Text(lang.name) }
                    }
                }
            }
            .fixedSize()
        }
    }
}
