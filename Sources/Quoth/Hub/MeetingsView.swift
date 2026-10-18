import SwiftUI
import QuothCore

struct MeetingsView: View {
    @ObservedObject var meetings: MeetingController
    @State private var selected: String?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                header("Meetings", "Notes from your calls, recorded on this Mac without a bot joining. Let participants know you're taking notes.")
                Spacer()
                Button(meetings.isRecording ? "Stop notes" : "Start meeting notes") {
                    Task { meetings.isRecording ? await meetings.stop() : await meetings.start() }
                }
                .padding(20)
            }
            HStack {
                TextField("Ask across all meetings (e.g. what did we decide about pricing?)", text: $question)
                    .onSubmit(ask)
                Button(asking ? "Thinking…" : "Ask", action: ask).disabled(question.isEmpty || asking)
            }
            .padding(.horizontal, 20)
            if let answer {
                Text(answer).textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            Divider().padding(.top, 12)
            HSplitView {
                List(meetings.meetings, selection: $selected) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(m.startedAt, style: .date)
                            Text("· \(Int(m.duration / 60)) min")
                            if m.status != .ready { Text("· \(m.status.rawValue)").foregroundStyle(m.status == .failed ? .red : .orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
                .frame(minWidth: 200, idealWidth: 230)
                detail.frame(minWidth: 380)
            }
        }
    }

    private func ask() {
        guard !question.isEmpty else { return }
        asking = true
        Task {
            answer = await meetings.ask(question)
            asking = false
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selected, let m = meetings.meetings.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.title).font(.title3.bold())
                    if let p = meetings.progress[id] { ProgressView(p).controlSize(.small) }
                    if let e = m.error { Text(e).foregroundStyle(.red) }
                    HStack {
                        Picker("", selection: $showTranscript) { Text("Notes").tag(false); Text("Transcript").tag(true) }
                            .pickerStyle(.segmented).fixedSize()
                        Spacer()
                        if m.status == .failed || m.status == .ready {
                            Button("Reprocess") { Task { await meetings.process(id) } }
                        }
                        Button("Copy") {
                            TextInserter.copyToClipboard(showTranscript ? MeetingTranscript.text(meetings.store.transcript(id)) : (meetings.store.summary(id) ?? ""))
                        }
                        Button("Delete", role: .destructive) { meetings.delete(id); selected = nil }
                    }
                    if showTranscript {
                        ForEach(Array(meetings.store.transcript(id).enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .top) {
                                Text(MeetingTranscript.timestamp(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Text(s.speaker).bold().foregroundStyle(s.speaker == "Me" ? Color.accentColor : .primary)
                                    .frame(width: 56, alignment: .leading)
                                Text(s.text).textSelection(.enabled)
                            }
                        }
                    } else if let md = meetings.store.summary(id) {
                        MarkdownText(md)
                    } else {
                        Text("Notes appear here once the meeting is processed.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        } else {
            Text(meetings.meetings.isEmpty ? "No meetings yet." : "Select a meeting.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Minimal Markdown renderer for meeting notes: headings, bullets, checkboxes, inline styles.
struct MarkdownText: View {
    let lines: [String]
    init(_ md: String) { lines = md.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 8)
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title2.bold())
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            HStack(alignment: .top) { Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square"); inline(String(line.dropFirst(6))) }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top) { Text("•"); inline(String(line.dropFirst(2))) }
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 4)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }
}
