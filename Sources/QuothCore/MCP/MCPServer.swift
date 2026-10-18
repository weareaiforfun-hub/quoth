import Foundation

/// A read-only Model Context Protocol server over stdio: lets Claude, ChatGPT or
/// any MCP client read your meeting notes and Scratchpad notes. Dictations are never exposed.
public final class MCPServer: @unchecked Sendable {
    let meetings: MeetingStore
    let notes: NotesStore
    let enabled: () -> Bool

    public init(meetings: MeetingStore = MeetingStore(), notes: NotesStore = NotesStore(),
                enabled: @escaping () -> Bool = { SettingsStore.load().mcpEnabled }) {
        self.meetings = meetings
        self.notes = notes
        self.enabled = enabled
    }

    /// Runs the newline-delimited JSON-RPC loop on stdin/stdout.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// Handles one JSON-RPC message; returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }
        if id == nil { return nil }  // notification (e.g. notifications/initialized)
        let params = msg["params"] as? [String: Any] ?? [:]

        func result(_ r: Any) -> String? { encode(["jsonrpc": "2.0", "id": id!, "result": r]) }
        func error(_ code: Int, _ message: String) -> String? {
            encode(["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": message]])
        }

        switch method {
        case "initialize":
            return result([
                "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "quoth", "version": "0.1.0"],
                "instructions": "Read-only access to the user's Quoth meeting notes (summaries, transcripts) and Scratchpad notes.",
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            guard enabled() else {
                return result(["content": [["type": "text", "text": "MCP access is turned off in Quoth's settings."]], "isError": true])
            }
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(["content": [["type": "text", "text": try call(name, args)]]])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        ["name": "list_meetings",
         "description": "List the user's recorded meetings, newest first, with id, title, date and duration.",
         "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "Max meetings (default 20)"]]]],
        ["name": "get_meeting",
         "description": "Get a meeting's notes (summary, decisions, action items) and optionally its full transcript.",
         "inputSchema": ["type": "object", "required": ["id"],
                         "properties": ["id": ["type": "string"],
                                        "include_transcript": ["type": "boolean", "description": "Include the timestamped transcript (default false)"]]]],
        ["name": "search_meetings",
         "description": "Search all meeting transcripts for a topic; returns the most relevant excerpts with meeting title and timestamp.",
         "inputSchema": ["type": "object", "required": ["query"],
                         "properties": ["query": ["type": "string"], "limit": ["type": "integer"]]]],
        ["name": "list_notes",
         "description": "List the user's Scratchpad notes with id, title and last-edited date.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "get_note",
         "description": "Get the full text of a Scratchpad note.",
         "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]],
    ]

    struct ToolError: LocalizedError { let errorDescription: String? }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        let iso = ISO8601DateFormatter()
        switch name {
        case "list_meetings":
            let limit = args["limit"] as? Int ?? 20
            let list = meetings.list().prefix(limit)
            if list.isEmpty { return "No meetings recorded yet." }
            return list.map { "- \($0.title) (id: \($0.id)) — \(iso.string(from: $0.startedAt)), \(Int($0.duration / 60)) min, \($0.status.rawValue)" }
                .joined(separator: "\n")
        case "get_meeting":
            guard let id = args["id"] as? String, let m = meetings.meeting(id) else { throw ToolError(errorDescription: "No meeting with that id.") }
            var out = "# \(m.title)\nDate: \(iso.string(from: m.startedAt)), \(Int(m.duration / 60)) min\n\n"
            out += meetings.summary(id) ?? "(No summary yet: status \(m.status.rawValue))"
            if args["include_transcript"] as? Bool == true {
                out += "\n\n## Transcript\n" + MeetingTranscript.text(meetings.transcript(id))
            }
            return out
        case "search_meetings":
            guard let q = args["query"] as? String, !q.isEmpty else { throw ToolError(errorDescription: "query is required") }
            let hits = MeetingSearch.rank(q, in: MeetingSearch.passages(store: meetings), limit: args["limit"] as? Int ?? 8)
            if hits.isEmpty { return "No matching excerpts." }
            return hits.map { "[\($0.title) @ \(MeetingTranscript.timestamp($0.start)), id \($0.meetingID)] \($0.text)" }
                .joined(separator: "\n\n")
        case "list_notes":
            let list = notes.list()
            if list.isEmpty { return "No Scratchpad notes." }
            return list.map { "- \($0.title) (id: \($0.id)) — edited \(iso.string(from: $0.updatedAt))" }.joined(separator: "\n")
        case "get_note":
            guard let id = args["id"] as? String, notes.list().contains(where: { $0.id == id }) else {
                throw ToolError(errorDescription: "No note with that id.")
            }
            return notes.plainText(id)
        default:
            throw ToolError(errorDescription: "Unknown tool \(name)")
        }
    }

    private func encode(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
