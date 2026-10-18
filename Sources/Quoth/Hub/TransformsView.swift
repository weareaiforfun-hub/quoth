import SwiftUI
import QuothCore

struct TransformsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Transforms", "Select text anywhere and press a hotkey to rewrite it. With nothing selected, the whole field (or your last dictation) is used. ⌥O shows what changed.")
            Form {
                Section {
                    Toggle("Enable ⌥1–⌥9 and ⌥O hotkeys", isOn: $state.settings.transformHotkeys)
                    Picker("Auto-apply after every dictation", selection: $state.personal.autoApplyTransform) {
                        Text("Off").tag(String?.none)
                        Text("Polish").tag(String?.some(Transforms.polishID))
                        Text("Prompt Engineer").tag(String?.some(Transforms.promptEngineerID))
                        ForEach(state.personal.transforms) { t in Text(t.name).tag(String?.some(t.id.uuidString)) }
                    }
                }
                Section("⌥1 Polish") {
                    Toggle("Make more concise", isOn: $state.personal.polish.concise)
                    Toggle("Reword for clarity", isOn: $state.personal.polish.clarity)
                    Toggle("Reorder for readability", isOn: $state.personal.polish.reorder)
                    Toggle("Add structure", isOn: $state.personal.polish.structure)
                    Toggle("Maintain tone", isOn: $state.personal.polish.maintainTone)
                    Toggle("Clarify the main point", isOn: $state.personal.polish.clarifyMainPoint)
                    Toggle("Refine phrasing for impact", isOn: $state.personal.polish.impact)
                    ForEach(state.personal.polish.custom.indices, id: \.self) { i in
                        HStack {
                            TextField("Custom instruction (≤50 words)", text: $state.personal.polish.custom[i])
                            Button(role: .destructive) { state.personal.polish.custom.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    if state.personal.polish.custom.count < 5 {
                        Button("Add custom instruction") { state.personal.polish.custom.append("") }
                    }
                }
                Section("⌥2 Prompt Engineer") {
                    Text("Turns a rambling spoken request into a structured prompt for an AI assistant.").foregroundStyle(.secondary)
                }
                ForEach(Array(state.personal.transforms.enumerated()), id: \.element.id) { i, _ in
                    Section("⌥\(i + 3) \(state.personal.transforms[i].name)") {
                        TextField("Name", text: $state.personal.transforms[i].name)
                        TextField("Instruction (e.g. Rewrite as a friendly Slack message)", text: $state.personal.transforms[i].instruction, axis: .vertical)
                        ForEach(state.personal.transforms[i].samples.indices, id: \.self) { j in
                            TextEditor(text: $state.personal.transforms[i].samples[j]).frame(minHeight: 50)
                        }
                        HStack {
                            if state.personal.transforms[i].samples.count < 5 {
                                Button("Add writing sample") { state.personal.transforms[i].samples.append("") }
                            }
                            Spacer()
                            Button("Delete transform", role: .destructive) { state.personal.transforms.remove(at: i) }
                        }
                    }
                }
                if state.personal.transforms.count < 7 {
                    Button("New custom transform") {
                        state.personal.transforms.append(TransformPrompt(name: "Custom \(state.personal.transforms.count + 1)", instruction: ""))
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct PowerSettingsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section("Command Mode, Scratchpad & Mouse") {
            Toggle("Command Mode: hold the hotkey + Control and speak an instruction", isOn: $state.settings.commandModeEnabled)
            Text("Edits the selection (“make this shorter”, “translate to Spanish”), drafts at the cursor (“reply saying I'll be late”), answers questions, or searches the web (“search for…”).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Command & Transform model (blank = cleanup model)", text: $state.settings.commandModel)
            Toggle("⌥S toggles the Scratchpad", isOn: $state.settings.scratchpadHotkey)
            Picker("Mouse button to dictate", selection: $state.settings.mouseDictateButton) {
                Text("Off").tag(0); Text("Middle button").tag(2); Text("Back button").tag(3); Text("Forward button").tag(4)
            }
            Picker("Mouse button for Enter", selection: $state.settings.mouseEnterButton) {
                Text("Off").tag(0); Text("Middle button").tag(2); Text("Back button").tag(3); Text("Forward button").tag(4)
            }
        }
        Section("AI apps (MCP)") {
            Toggle("Let MCP clients read my meeting notes and Scratchpad", isOn: $state.settings.mcpEnabled)
            Text("Read-only. Dictations are never shared. Add this to Claude Desktop's claude_desktop_config.json (or any MCP client):")
                .font(.caption).foregroundStyle(.secondary)
            Text(Self.config).font(.caption.monospaced()).textSelection(.enabled)
            Button("Copy config") { TextInserter.copyToClipboard(Self.config) }
        }
    }

    static var config: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/quoth-mcp").path
        return "\"quoth\": { \"command\": \"\(path)\" }"
    }
}
