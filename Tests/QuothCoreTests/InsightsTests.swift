import Foundation
import Testing
@testable import QuothCore

@Suite struct InsightsTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    func date(_ s: String) -> Date { Insights.dayDate(s, cal)! }

    @Test func totalsWpmTimeSaved() {
        let days = [DayStats(day: "2026-10-10", words: 600, seconds: 240, dictations: 10),
                    DayStats(day: "2026-10-11", words: 400, seconds: 60, dictations: 5)]
        let i = Insights.compute(days: days, apps: [("Slack", 300), ("Notes", 700)], today: date("2026-10-11"), calendar: cal)
        #expect(i.totalWords == 1000 && i.dictations == 15)
        #expect(i.wpm == 200)                // 1000 words / 5 min
        #expect(i.minutesSaved == 20)        // 1000/40 = 25 min typing − 5 min speaking
        #expect(i.topApps.first?.app == "Notes")
        #expect(!i.voiceUnlocked)
    }

    @Test func streaks() {
        let d = ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-07", "2026-10-08", "2026-10-09"]
            .map { DayStats(day: $0, words: 10, seconds: 5, dictations: 1) }
        // Today (10th) has nothing yet: the streak through yesterday still counts.
        let i = Insights.compute(days: d, apps: [], today: date("2026-10-10"), calendar: cal)
        #expect(i.currentStreak == 3 && i.longestStreak == 3)
        let broken = Insights.compute(days: d, apps: [], today: date("2026-10-12"), calendar: cal)
        #expect(broken.currentStreak == 0)
    }

    @Test func storeAggregates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try HistoryStore(url: dir.appendingPathComponent("h.sqlite"))
        store.recordStats(words: 10, seconds: 4, app: "Slack")
        store.recordStats(words: 5, seconds: 2, app: "Slack")
        store.recordStats(words: 7, seconds: 3, app: nil)
        let i = store.insights()
        #expect(i.totalWords == 22 && i.dictations == 3 && i.currentStreak == 1)
        #expect(i.topApps.first?.app == "Slack" && i.topApps.first?.words == 15)
        store.deleteAll()  // deleting history keeps the aggregates
        #expect(store.insights().totalWords == 22)
    }

    @Test func voiceProfile() {
        let p = VoiceProfile.compute(["Ship the release today!", "Can we ship the release tomorrow?", "The release notes are ready."])
        #expect(p.topWords.prefix(2) == ["release", "ship"])
        #expect(p.questionShare == 33 && p.exclamationShare == 33)
    }
}
