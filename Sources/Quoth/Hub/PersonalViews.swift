import SwiftUI
import QuothCore

// MARK: Dictionary

struct DictionaryView: View {
    @ObservedObject var state: AppState
    @State private var word = ""
    @State private var spoken = ""
    @State private var replacement = ""
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Dictionary", "Words Quoth should spell your way, and phrases to replace. Words also steer the speech model.")
            Form {
                Section("Add") {
                    HStack {
                        TextField("Word or name (e.g. Kubernetes)", text: $word).onSubmit(addWord)
                        Button("Add word", action: addWord).disabled(word.isEmpty)
                    }
                    HStack {
                        TextField("When I say…", text: $spoken)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("…write", text: $replacement).onSubmit(addReplacement)
                        Button("Add replacement", action: addReplacement).disabled(spoken.isEmpty || replacement.isEmpty)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Toggle("Learn words automatically when I correct a dictation", isOn: $state.personal.autoLearn)
                }
                Section("\(state.personal.dictionary.count) entries") {
                    TextField("Filter", text: $filter)
                    ForEach(filtered) { e in
                        HStack {
                            Button { toggleStar(e) } label: {
                                Image(systemName: e.starred ? "star.fill" : "star").foregroundStyle(e.starred ? .yellow : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Starred words are always sent to the speech model")
                            if e.kind == .word {
                                Text(e.phrase)
                            } else {
                                Text(e.phrase).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                Text(e.replacement ?? "")
                            }
                            if e.autoLearned { Text("learned").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.blue.opacity(0.15))) }
                            Spacer()
                            if e.uses > 0 { Text("\(e.uses)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            Button(role: .destructive) { delete(e) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var filtered: [DictionaryEntry] {
        let all = state.personal.dictionary.sorted { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.phrase.localizedCaseInsensitiveContains(filter) || ($0.replacement ?? "").localizedCaseInsensitiveContains(filter) }
    }

    private func add(_ e: DictionaryEntry) -> Bool {
        if let err = state.personal.validate(e) { error = err.localizedDescription; return false }
        error = nil
        state.personal.dictionary.append(e)
        state.personal.deletedWords.removeAll { $0.lowercased() == e.output.lowercased() }
        return true
    }

    private func addWord() {
        if add(DictionaryEntry(word: word.trimmingCharacters(in: .whitespaces))) { word = "" }
    }

    private func addReplacement() {
        if add(DictionaryEntry(spoken: spoken.trimmingCharacters(in: .whitespaces), replacement: replacement.trimmingCharacters(in: .whitespaces))) {
            spoken = ""; replacement = ""
        }
    }

    private func toggleStar(_ e: DictionaryEntry) {
        if let i = state.personal.dictionary.firstIndex(where: { $0.id == e.id }) { state.personal.dictionary[i].starred.toggle() }
    }

    private func delete(_ e: DictionaryEntry) {
        state.personal.dictionary.removeAll { $0.id == e.id }
        // Deleted words are never re-added by auto-learn.
        state.personal.deletedWords.append(e.output)
    }
}

// MARK: Snippets

struct SnippetsView: View {
    @ObservedObject var state: AppState
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Snippets", "Say a trigger phrase and Quoth types the full text, exactly as saved.")
            Form {
                Section("New snippet") {
                    TextField("Trigger (e.g. my calendar link)", text: $trigger)
                    TextEditor(text: $expansion).frame(minHeight: 70).font(.body)
                    HStack {
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Button("Add snippet", action: add).disabled(trigger.isEmpty || expansion.isEmpty)
                    }
                }
                Section("\(state.personal.snippets.count) snippets") {
                    ForEach($state.personal.snippets) { $sn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Trigger", text: $sn.trigger).font(.body.bold())
                                Button(role: .destructive) {
                                    state.personal.snippets.removeAll { $0.id == sn.id }
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            TextEditor(text: $sn.expansion).frame(minHeight: 40).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func add() {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 60 else { error = "Trigger: 60 characters at most"; return }
        guard expansion.count <= 4000 else { error = "Expansion: 4,000 characters at most"; return }
        guard !state.personal.snippets.contains(where: { $0.trigger.lowercased() == t.lowercased() }) else { error = "That trigger exists"; return }
        state.personal.snippets.append(Snippet(trigger: t, expansion: expansion))
        trigger = ""; expansion = ""; error = nil
    }
}

// MARK: Style

struct StyleView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Style", "How capitalisation and punctuation look in each kind of app. Your words never change.")
            Form {
                ForEach(StyleCategory.allCases, id: \.self) { cat in
                    Section(cat.title) {
                        Picker("Tone", selection: Binding(
                            get: { state.personal.styles[cat] ?? .formal },
                            set: { state.personal.styles[cat] = $0 })) {
                            ForEach(cat.allowedTones, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text((state.personal.styles[cat] ?? .formal).example)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Use the text around the cursor as context", isOn: $state.settings.contextAwareness)
                    Text("Quoth reads the focused field through Accessibility (never screenshots, never password fields or password managers) to continue sentences naturally and recognise code identifiers. Nothing leaves your Mac in Local mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

func header(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title2.bold())
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .padding(20)
}
