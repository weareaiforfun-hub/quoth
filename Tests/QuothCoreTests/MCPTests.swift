import Foundation
import Testing
@testable import QuothCore

@Suite struct MCPTests {
    func makeServer(enabled: Bool = true) -> (MCPServer, Meeting, Note) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ms = MeetingStore(dir: base.appendingPathComponent("m"))
        let ns = NotesStore(dir: base.appendingPathComponent("n"))
        var m = Meeting(title: "Pricing review"); m.status = .ready; m.endedAt = m.startedAt.addingTimeInterval(1800)
        ms.save(m)
        ms.saveSummary(m.id, "## Summary\nPro plan stays at $12.")
        ms.saveTranscript(m.id, [Segment(speaker: "Others", start: 75, end: 80, text: "The pro plan price stays at twelve dollars.")])
        let n = ns.create()
        ns.save(n.id, rtf: Data("x".utf8), plainText: "Groceries\nmilk")
        return (MCPServer(meetings: ms, notes: ns, enabled: { enabled }), m, n)
    }

    func call(_ s: MCPServer, _ json: String) -> [String: Any] {
        let out = s.handle(json)!
        return try! JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
    }

    func text(_ r: [String: Any]) -> String {
        (((r["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
    }

    @Test func handshakeAndList() {
        let (s, _, _) = makeServer()
        let i = call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(((i["result"] as! [String: Any])["serverInfo"] as! [String: Any])["name"] as? String == "quoth")
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let t = call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let names = ((t["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        #expect(names == ["list_meetings", "get_meeting", "search_meetings", "list_notes", "get_note"])
        let e = call(s, #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
        #expect((e["error"] as! [String: Any])["code"] as? Int == -32601)
    }

    @Test func tools() {
        let (s, m, n) = makeServer()
        #expect(text(call(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)).contains("Pricing review"))
        let got = text(call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"\#(m.id)","include_transcript":true}}}"#))
        #expect(got.contains("$12") && got.contains("[01:15] Others"))
        #expect(text(call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"pro plan price"}}}"#)).contains("Pricing review @ 01:15"))
        #expect(text(call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"\#(n.id)"}}}"#)) == "Groceries\nmilk")
        let bad = call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"nope"}}}"#)
        #expect((bad["result"] as! [String: Any])["isError"] as? Bool == true)
    }

    @Test func respectsOffSwitch() {
        let (s, _, _) = makeServer(enabled: false)
        let r = call(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)
        #expect(text(r).contains("turned off"))
    }
}
