import SwiftUI
import QuothCore

/// Choose which model does which job, download models, and compare them side by side.
struct ModelsView: View {
    @ObservedObject var state: AppState
    @StateObject private var lab: ModelLab
    @State private var installedText: [String] = []
    @State private var progress: [String: Double] = [:]
    @State private var error: String?
    @State private var apiKey: String = Keychain.apiKey() ?? ""

    init(state: AppState) {
        self.state = state
        _lab = StateObject(wrappedValue: ModelLab(state: state))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Models", "Pick which AI model does which job, download new ones, and compare them on the same input.")
            Form {
                explainer
                speechSection
                textSection
                if state.settings.speechProvider == .cloud || state.settings.textProvider == .cloud { cloudSection }
                LabSection(state: state, lab: lab, installedText: installedText)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
        }
        .task { await refreshInstalled() }
    }

    private var explainer: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Two kinds of model, two different jobs", systemImage: "info.circle").font(.headline)
                Text("**Speech recognition** turns your voice into raw text. Quoth uses OpenAI's open-source **Whisper** models, run on your Mac by whisper.cpp.")
                Text("**Language models** turn that raw text into what you meant (cleanup), follow your commands, and write meeting notes. By default that's Alibaba's open-weights **Qwen 2.5**, run by Ollama. Llama, Gemma and Mistral work too.")
                Text("They aren't interchangeable: Qwen can't listen to audio and Whisper can't rewrite text. You can swap the model within each job, and mix local and cloud (e.g. local Whisper + a cloud language model).")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: speech

    private var speechSection: some View {
        Section(ModelRole.speech.title) {
            Text(ModelRole.speech.explanation).font(.caption).foregroundStyle(.secondary)
            Picker("Runs on", selection: $state.settings.speechProvider) {
                Text("This Mac (whisper.cpp)").tag(ProviderKind.local)
                Text("Cloud API").tag(ProviderKind.cloud)
            }
            if state.settings.speechProvider == .local {
                LabeledContent("Status", value: state.whisperStatus)
                ForEach(ModelCatalog.speech) { m in speechRow(m) }
            } else {
                TextField("Cloud transcription model", text: $state.settings.cloudASRModel)
            }
        }
    }

    private func speechRow(_ m: SpeechModelInfo) -> some View {
        let installed = ModelCatalog.isInstalled(m)
        let active = (state.settings.whisperModelPath as NSString).lastPathComponent == m.file
        return HStack(alignment: .top) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name)
                Text("\(m.sizeMB) MB · \(m.notes)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = progress[m.file] {
                ProgressView(value: p).frame(width: 90)
            } else if installed {
                if !active { Button("Use") { state.settings.whisperModelPath = AppPaths.models.appendingPathComponent(m.file).path } }
            } else {
                Button("Download") { Task { await download(m) } }
            }
        }
    }

    private func download(_ m: SpeechModelInfo) async {
        progress[m.file] = 0
        defer { progress[m.file] = nil }
        do {
            _ = try await ModelDownloader().download(m.url, to: AppPaths.models.appendingPathComponent(m.file)) { p in
                Task { @MainActor in progress[m.file] = p }
            }
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: text

    private var textSection: some View {
        Section("Language models") {
            Picker("Runs on", selection: $state.settings.textProvider) {
                Text("This Mac (Ollama)").tag(ProviderKind.local)
                Text("Cloud API").tag(ProviderKind.cloud)
            }
            if state.settings.textProvider == .local {
                roleRow(.cleanup, binding: $state.settings.ollamaModel, allowBlank: false)
                roleRow(.commands, binding: $state.settings.commandModel, allowBlank: true)
                roleRow(.meetings, binding: $state.settings.meetingModel, allowBlank: true)
                DisclosureGroup("Download more models") {
                    ForEach(ModelCatalog.text) { m in textCatalogRow(m) }
                    Text("Any model from ollama.com/library works: type its name in a picker above, then download it here or with `ollama pull`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField("Cloud language model", text: $state.settings.cloudLLMModel)
            }
        }
    }

    private func roleRow(_ role: ModelRole, binding: Binding<String>, allowBlank: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(role.title)
                Spacer()
                Picker("", selection: binding) {
                    if allowBlank { Text("Same as cleanup").tag("") }
                    ForEach(choices(including: binding.wrappedValue), id: \.self) { Text(label($0)).tag($0) }
                }
                .frame(maxWidth: 280)
            }
            Text(role.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choices(including current: String) -> [String] {
        var all = installedText
        if !current.isEmpty && !all.contains(current) { all.insert(current, at: 0) }
        return all
    }

    private func label(_ tag: String) -> String {
        let name = ModelCatalog.text.first { $0.tag == tag }?.name ?? tag
        return installedText.contains(tag) ? name : "\(name) (not downloaded)"
    }

    private func textCatalogRow(_ m: TextModelInfo) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name)
                Text("\(String(format: "%.1f", m.sizeGB)) GB download · ~\(m.ramGB) GB memory · \(m.license)\n\(m.notes)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = progress[m.tag] {
                ProgressView(value: p).frame(width: 90)
            } else if installedText.contains(m.tag) {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Download") { Task { await pull(m.tag) } }
            }
        }
    }

    private func ollama(_ model: String = "") -> OllamaCleaner {
        OllamaCleaner(baseURL: URL(string: state.settings.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!, model: model)
    }

    private func pull(_ tag: String) async {
        progress[tag] = 0
        defer { progress[tag] = nil }
        do {
            try await ollama().pull(tag) { p, _ in Task { @MainActor in progress[tag] = p } }
            await refreshInstalled()
        } catch {
            self.error = "Couldn't download \(tag): \(error.localizedDescription). Is Ollama running?"
        }
    }

    private func refreshInstalled() async {
        installedText = ((try? await ollama().listTags()) ?? []).sorted()
    }

    // MARK: cloud

    private var cloudSection: some View {
        Section("Cloud API") {
            TextField("Base URL", text: $state.settings.cloudBaseURL)
            SecureField("API key (stored in Keychain)", text: $apiKey)
                .onChange(of: apiKey) { _, v in Keychain.setAPIKey(v) }
            Text("Any OpenAI-compatible service. Groq: https://api.groq.com/openai/v1 with whisper-large-v3-turbo and llama-3.3-70b-versatile. OpenAI: https://api.openai.com/v1 with gpt-4o-mini-transcribe and gpt-4.1-mini. A local server (LM Studio, llama.cpp, vLLM) also works here.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Model Lab: run the same input through 2–3 models and compare the results.
struct LabSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var lab: ModelLab
    let installedText: [String]
    @State private var kind = 0
    @State private var picked: Set<String> = []
    @State private var quick = true
    @State private var includeRecent = true

    var body: some View {
        Section("Model Lab: compare models") {
            Picker("Compare", selection: $kind) {
                Text("Language models (cleanup)").tag(0)
                Text("Speech models").tag(1)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in picked = [] }
            Text(kind == 0
                 ? "Runs Quoth's test sentences (fillers, corrections, lists, questions it must not answer…) through each model with the real cleanup rules, plus your latest dictations."
                 : "Transcribes three short test recordings with known text, plus your latest dictations, with each model.")
                .font(.caption).foregroundStyle(.secondary)
            let options = kind == 0 ? installedText + (Keychain.apiKey() != nil ? ["cloud"] : [])
                                    : ModelCatalog.speech.filter { ModelCatalog.isInstalled($0) }.map(\.file)
            ForEach(options, id: \.self) { m in
                Toggle(isOn: Binding(get: { picked.contains(m) }, set: { on in
                    if on { if picked.count < 3 { picked.insert(m) } } else { picked.remove(m) }
                })) { Text(m == "cloud" ? "Cloud: \(state.settings.cloudLLMModel)" : (ModelCatalog.speech.first { $0.file == m }?.name ?? m)) }
            }
            if kind == 0 { Toggle("Quick run (about 20 sentences, one or two per behaviour)", isOn: $quick) }
            Toggle("Include my recent dictations", isOn: $includeRecent)
            HStack {
                Button(lab.running ? "Running…" : "Compare \(picked.count) model\(picked.count == 1 ? "" : "s")") {
                    let models = options.filter { picked.contains($0) }
                    Task {
                        if kind == 0 { await lab.runCleanup(models: models, quick: quick, includeRecent: includeRecent) }
                        else { await lab.runSpeech(models: models, useRecordings: includeRecent) }
                    }
                }
                .disabled(lab.running || picked.isEmpty)
                if lab.running { ProgressView().controlSize(.small); Text(lab.status).font(.caption).foregroundStyle(.secondary) }
            }
            if kind == 0 && !lab.cleanup.isEmpty { cleanupResults }
            if kind == 1 && !lab.speech.isEmpty { speechResults }
        }
    }

    private var cleanupResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Model").bold(); Text("Exact").bold(); Text("Same words").bold(); Text("Serious errors").bold(); Text("Typical time").bold() }
                ForEach(lab.cleanupModels, id: \.self) { m in
                    let s = lab.summary(m)
                    GridRow {
                        Text(m); Text("\(s.exact)/\(s.cases)"); Text("\(s.sameWords)/\(s.cases)")
                        Text("\(s.serious)").foregroundStyle(s.serious > 0 ? .red : .green)
                        Text("\(s.p50ms) ms")
                    }
                }
            }
            .font(.callout)
            Text("Serious = answered your question, added content, or had to fall back. ✓ exact · ≈ same words · · different").font(.caption).foregroundStyle(.secondary)
            ForEach(lab.cleanupInputs, id: \.id) { input in
                VStack(alignment: .leading, spacing: 3) {
                    Text(input.raw).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    ForEach(lab.cleanup.filter { $0.caseID == input.id }, id: \.model) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Text(r.verdict?.symbol ?? "–").frame(width: 14)
                            Text(r.model).font(.caption.bold()).frame(width: 150, alignment: .leading).lineLimit(1)
                            Text(r.output).font(.callout).textSelection(.enabled)
                            Spacer()
                            Text("\(r.ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }
        }
    }

    private var speechResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Model").bold(); Text("Word errors (test clips)").bold(); Text("Typical time").bold() }
                ForEach(lab.speechModels, id: \.self) { m in
                    let rows = lab.speech.filter { $0.model == m }
                    let known = rows.filter { !$0.sample.hasPrefix("Your") }.compactMap(\.wer)
                    let wer = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
                    let ms = rows.map(\.ms).sorted()
                    GridRow {
                        Text(ModelCatalog.speech.first { $0.file == m }?.name ?? m)
                        Text(String(format: "%.0f%%", wer * 100))
                        Text("\(ms.isEmpty ? 0 : ms[ms.count / 2]) ms")
                    }
                }
            }
            .font(.callout)
            Text("Word errors = share of words wrong vs the known text. For your own recordings, the difference is measured against the first model.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(Set(lab.speech.map(\.sample))).sorted(), id: \.self) { sample in
                VStack(alignment: .leading, spacing: 3) {
                    Text(sample).font(.caption.bold())
                    ForEach(lab.speech.filter { $0.sample == sample }) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Text(ModelCatalog.speech.first { $0.file == r.model }?.name ?? r.model).font(.caption).frame(width: 170, alignment: .leading)
                            Text(r.text).font(.callout).textSelection(.enabled)
                            Spacer()
                            if let w = r.wer { Text(String(format: "%.0f%%", w * 100)).font(.caption.monospacedDigit()) }
                            Text("\(r.ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }
        }
    }
}
