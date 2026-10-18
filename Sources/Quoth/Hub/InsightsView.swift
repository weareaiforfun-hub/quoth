import SwiftUI
import QuothCore

struct InsightsView: View {
    @ObservedObject var state: AppState
    let controller: DictationController
    @State private var insights = Insights()
    @State private var profileText: String?
    @State private var generating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header("Insights", "Your dictation, in numbers. Only counts are stored here, never text.")
                    .padding(-20)
                    .padding(.bottom, 8)
                HStack(spacing: 12) {
                    tile("Words dictated", insights.totalWords.formatted())
                    tile("Words per minute", "\(insights.wpm)")
                    tile("Time saved", formatMinutes(insights.minutesSaved))
                    tile("Streak", "\(insights.currentStreak) day\(insights.currentStreak == 1 ? "" : "s")",
                         sub: "Longest: \(insights.longestStreak)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last 16 weeks").font(.headline)
                    Heatmap(days: insights.days)
                }
                if !insights.topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where you dictate").font(.headline)
                        let maxWords = max(1, insights.topApps.first?.words ?? 1)
                        ForEach(insights.topApps, id: \.app) { a in
                            HStack {
                                Text(a.app).frame(width: 140, alignment: .leading).lineLimit(1)
                                GeometryReader { g in
                                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                                        .frame(width: max(4, g.size.width * CGFloat(a.words) / CGFloat(maxWords)))
                                }
                                .frame(height: 12)
                                Text(a.words.formatted()).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                }
                voice
            }
            .padding(20)
        }
        .onAppear { insights = controller.history?.insights() ?? Insights() }
    }

    @ViewBuilder private var voice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Voice").font(.headline)
            if !insights.voiceUnlocked {
                ProgressView(value: Double(insights.totalWords), total: 2000)
                Text("Unlocks at 2,000 words (\(max(0, 2000 - insights.totalWords)) to go).").font(.callout).foregroundStyle(.secondary)
            } else {
                let samples = state.history.filter { $0.status == .ok }.map(\.final)
                let p = VoiceProfile.compute(samples)
                Text("About \(p.averageWordsPerDictation) words per dictation, \(p.averageSentenceLength) words per sentence. \(p.questionShare)% questions, \(p.exclamationShare)% exclamations.")
                if !p.topWords.isEmpty { Text("Words you use most: \(p.topWords.joined(separator: ", "))").foregroundStyle(.secondary) }
                if let profileText { Text(profileText).textSelection(.enabled).padding(.top, 4) }
                Button(generating ? "Writing your profile…" : "Describe my communication style") {
                    generating = true
                    Task {
                        defer { generating = false }
                        guard let llm = controller.makeLLM() else { return }
                        profileText = try? await llm.complete(VoiceProfile.llmMessages(samples: samples), json: false, maxTokens: 400, contextTokens: 8192)
                    }
                }
                .disabled(generating || samples.isEmpty)
            }
        }
    }

    private func tile(_ title: String, _ value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func formatMinutes(_ m: Int) -> String { m < 60 ? "\(m) min" : String(format: "%.1f h", Double(m) / 60) }
}

/// GitHub-style activity grid: columns are weeks, rows are weekdays.
struct Heatmap: View {
    let days: [String: Int]
    private let weeks = 16

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) - 1
        let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today)!
        let maxWords = max(1, days.values.max() ?? 1)
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        let date = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                        let words = days[Insights.dayKey(date)] ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(date > today ? Color.clear
                                  : words == 0 ? Color.primary.opacity(0.07)
                                  : Color.accentColor.opacity(0.25 + 0.75 * Double(words) / Double(maxWords)))
                            .frame(width: 12, height: 12)
                            .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(words) words")
                    }
                }
            }
        }
    }
}
