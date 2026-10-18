import SwiftUI
import QuothCore

/// Every feature in one place: what it does, how to use it, and where to configure it.
struct FeaturesView: View {
    @ObservedObject var state: AppState

    struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let what: String
        let how: String
        var tab: HubSection? = nil
    }

    private var hotkey: String { state.settings.hotkey.title }

    private var groups: [(String, [Feature])] {
        [
            ("Dictation", [
                Feature(icon: "mic", title: "Push to talk",
                        what: "Speak instead of typing, in any app. Cleaned-up text appears where your cursor is.",
                        how: "Hold \(hotkey), speak, release. Esc cancels.", tab: .settings),
                Feature(icon: "hand.raised", title: "Hands-free",
                        what: "Keep recording without holding a key, for longer thoughts.",
                        how: "Double-tap \(hotkey). Tap again (or ■ on the Earshot pill) to stop.", tab: .settings),
                Feature(icon: "sparkles", title: "Auto Cleanup",
                        what: "Removes um/uh, applies corrections (\"2, actually 3\" → 3), spoken punctuation, lists and email layout. Never answers questions you dictate.",
                        how: "Choose None, Light or Medium in Settings or the menu bar.", tab: .settings),
                Feature(icon: "doc.on.clipboard", title: "Paste last / Undo AI edit",
                        what: "Paste your last dictation again, or swap the cleaned text for exactly what you said.",
                        how: "⌃⌘V pastes the last one. Menu bar → Undo AI Edit.", tab: .history),
                Feature(icon: "computermouse", title: "Thumb Talk",
                        what: "Dictate with a mouse button instead of the keyboard. Handy with a mouse that has extra side buttons (back/forward) or a middle button.",
                        how: "Settings → Mouse button to dictate: hold that button, speak, release. You can also map a button to Enter.", tab: .settings),
                Feature(icon: "globe", title: "Languages",
                        what: "About 100 languages, detected automatically, pinned, or limited to a set you choose. UK/Canadian spelling, Swiss German, Hinglish and more.",
                        how: "Settings → Languages and Variant.", tab: .settings),
            ]),
            ("Personal", [
                Feature(icon: "character.book.closed", title: "Dictionary",
                        what: "Names and terms spelled your way, plus replacements. Learns a name when you fix it right after dictating.",
                        how: "Add words in Dictionary. Star important ones.", tab: .dictionary),
                Feature(icon: "text.badge.plus", title: "Snippets",
                        what: "Say a short trigger, get a longer text exactly as saved (links, addresses, signatures).",
                        how: "Create them in Snippets, then just say the trigger.", tab: .snippets),
                Feature(icon: "textformat", title: "Style",
                        what: "Formal, casual, very casual or excited, separately for messages, work chat, email and everything else.",
                        how: "Pick a tone per app type in Style.", tab: .style),
                Feature(icon: "text.cursor", title: "Context awareness",
                        what: "Reads the text around your cursor (never password fields) to continue sentences naturally and spell code identifiers.",
                        how: "On by default; toggle it in Style.", tab: .style),
            ]),
            ("Power tools", [
                Feature(icon: "command", title: "Command Mode",
                        what: "Speak an instruction: edit selected text, draft a reply, ask a question, or search the web.",
                        how: "Hold \(hotkey) + Control and say e.g. \"make this shorter\" or \"reply that I'll be late\".", tab: .settings),
                Feature(icon: "wand.and.stars", title: "Transforms",
                        what: "One-key rewrites of selected text: Polish, Prompt Engineer, and up to 7 of your own.",
                        how: "Select text, press ⌥1 (Polish), ⌥2 (Prompt Engineer), ⌥3–⌥9 (yours). ⌥O shows the changes.", tab: .transforms),
                Feature(icon: "chevron.left.forwardslash.chevron.right", title: "Developer features",
                        what: "In Cursor/Windsurf, \"index dot ts\" becomes @index.ts; spoken names match identifiers in your code; terminals get safe pasting.",
                        how: "Just dictate in your editor or terminal."),
                Feature(icon: "note.text", title: "Scratchpad",
                        what: "A floating notepad with version history. Dictate into it like any app.",
                        how: "⌥S, or menu bar → Scratchpad."),
            ]),
            ("Meetings & insights", [
                Feature(icon: "person.2.wave.2", title: "Meeting notes",
                        what: "Records your mic and the call audio on this Mac (no bot joins), then writes a transcript, summary, decisions and action items. Ask questions across meetings.",
                        how: "Menu bar → Start Meeting Notes. Let participants know you're taking notes.", tab: .meetings),
                Feature(icon: "chart.bar", title: "Insights",
                        what: "Words per minute, time saved, streaks, the apps you dictate in, and a profile of your speaking style.",
                        how: "Open Insights.", tab: .insights),
                Feature(icon: "clock", title: "History",
                        what: "Every dictation with raw and cleaned text, audio playback and retry.",
                        how: "Open History. Retention is set in Settings → Privacy.", tab: .history),
            ]),
            ("Models & connections", [
                Feature(icon: "cpu", title: "Models & Model Lab",
                        what: "Choose the speech model (Whisper) and language models (Qwen, Llama…) for each job, on this Mac or in the cloud, and compare them side by side.",
                        how: "Open Models.", tab: .models),
                Feature(icon: "link", title: "AI apps (MCP)",
                        what: "Lets Claude and other AI apps read your meeting and Scratchpad notes (read-only, never dictations).",
                        how: "Settings → AI apps: copy the config into Claude Desktop.", tab: .settings),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("Features", "Everything Quoth can do, how to use it, and where to change it.")
                    .padding(-20).padding(.bottom, 4)
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.0).font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                            ForEach(group.1) { f in card(f) }
                        }
                    }
                }
                shortcuts
            }
            .padding(20)
        }
    }

    private func card(_ f: Feature) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: f.icon).foregroundStyle(Color.orange).frame(width: 22)
                Text(f.title).font(.headline)
                Spacer()
                if let tab = f.tab {
                    Button("Open") { state.hubSection = tab.rawValue }.buttonStyle(.link).font(.caption)
                }
            }
            Text(f.what).font(.callout)
            Text(f.how).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach([
                    ("Hold \(hotkey)", "Dictate"), ("Double-tap \(hotkey)", "Hands-free"),
                    ("\(hotkey) + Control", "Command Mode"), ("Esc", "Cancel recording"),
                    ("⌃⌘V", "Paste last dictation"), ("⌥1 … ⌥9", "Transforms"), ("⌥O", "Show last transform's changes"),
                    ("⌥S", "Scratchpad"),
                ], id: \.0) { k, v in
                    GridRow { Text(k).font(.callout.monospaced()); Text(v).font(.callout) }
                }
            }
        }
    }
}
