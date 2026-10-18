import Foundation
import Testing
@testable import QuothCore

@Suite struct CommandModeTests {
    @Test func parsesJSON() {
        #expect(CommandMode.parse(#"{"action":"replace","text":"Shorter."}"#, hasSelection: true) == CommandResult(action: .replace, text: "Shorter."))
        #expect(CommandMode.parse("```json\n{\"action\": \"answer\", \"text\": \"Paris\"}\n```", hasSelection: false)?.action == .answer)
        #expect(CommandMode.parse(#"Sure! {"text":"Draft"}"#, hasSelection: false) == CommandResult(action: .insert, text: "Draft"))
        #expect(CommandMode.parse(#"{"action":"insert","text":"  "}"#, hasSelection: false) == nil)
        #expect(CommandMode.parse("not json", hasSelection: false) == nil)
        #expect(CommandMode.parse(#"{"answer": "366 days"}"#, hasSelection: false) == CommandResult(action: .answer, text: "366 days"))
    }

    @Test func explicitSearch() {
        #expect(CommandMode.explicitSearch("Search for best ramen in Berlin.") == "best ramen in Berlin")
        #expect(CommandMode.explicitSearch("look up the weather tomorrow") == "the weather tomorrow")
        #expect(CommandMode.explicitSearch("make this shorter") == nil)
        #expect(CommandMode.searchURL("a b")?.absoluteString == "https://www.perplexity.ai/search?q=a%20b")
    }

    @Test func messagesCarryInputs() {
        let m = CommandMode.messages(instruction: "make it formal", selection: "hey", field: "hey there", appName: "Mail")
        #expect(m.count == 2 && m[1].content.contains("SELECTED:\nhey") && m[1].content.contains("APP: Mail"))
    }
}

@Suite struct TransformTests {
    @Test func polishRulesInPrompt() {
        var r = PolishRules()
        r.reorder = true
        r.custom = ["Use British spelling."]
        let sys = Transforms.polishMessages("x", rules: r)[0].content
        #expect(sys.contains("concise") && sys.contains("Reorder") && sys.contains("British") && !sys.contains("impact"))
    }

    @Test func customUsesSamples() {
        let t = TransformPrompt(name: "Tweet", instruction: "Make it a tweet", samples: ["Sample A", ""])
        let sys = Transforms.customMessages("x", transform: t)[0].content
        #expect(sys.contains("Make it a tweet") && sys.contains("Sample A") && !sys.contains("Sample 2"))
    }

    @Test func wordLimits() {
        #expect(!Transforms.validInput(" "))
        #expect(Transforms.validInput("hello"))
        #expect(!Transforms.validInput(String(repeating: "w ", count: 1001)))
    }

    @Test func diff() {
        let d = WordDiff.diff("the quick brown fox", "the slow brown fox jumps")
        #expect(d.contains(.removed("quick ")) && d.contains(.added("slow ")) && d.contains(.added("jumps")))
        #expect(d.contains(.same("brown fox ")))
        // Reconstruction
        let parts = WordDiff.diff("a b c", "a x c")
        let new = parts.compactMap { if case .removed = $0 { return nil }; switch $0 { case .same(let s), .added(let s): return s; default: return nil } }.joined()
        #expect(new == "a x c")
    }
}

@Suite struct NotesTests {
    @Test func createSaveVersionDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NotesStore(dir: dir)
        let n = store.create()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.save(n.id, rtf: Data("v1".utf8), plainText: "Groceries\nmilk", now: t0)
        store.save(n.id, rtf: Data("v2".utf8), plainText: "Groceries\nmilk eggs", now: t0.addingTimeInterval(30))
        store.save(n.id, rtf: Data("v3".utf8), plainText: "Groceries\nmilk eggs bread", now: t0.addingTimeInterval(300))
        #expect(store.list().first?.title == "Groceries")
        #expect(store.content(n.id) == Data("v3".utf8))
        #expect(store.plainText(n.id) == "Groceries\nmilk eggs bread")
        // v2 came within the interval, so only v1 and v3 are versions
        let versions = store.versions(n.id)
        #expect(versions.count == 2)
        #expect(store.version(n.id, at: versions.last!) == Data("v1".utf8))
        store.delete(n.id)
        #expect(store.list().isEmpty)
    }
}
