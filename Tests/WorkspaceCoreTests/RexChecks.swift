import Foundation
import WorkspaceCore

let session = "session:01a18a18-7dc6-7825-a06b-65a90161ceb6"
let block = "block:01a18d82-e1fc-7488-b6c9-12dc9dbe4b9d"

// Shapes match `rex events --all --json` output captured from a real Rex server.
func blockEvent(_ name: String, _ payload: String) -> Data {
    Data("""
    {"type":"session_event","payload":{"session_id":"\(session)","event":{"type":"block_event","payload":{\
    "block_id":"\(block)","creator_name":"com.superlogical.terminal","name":"\(name)","payload":\(payload)}}}}
    """.utf8)
}

func status(_ state: String, extra: String = "") -> Data {
    blockEvent("program_status_changed", """
    {"id":"","record":{"state":"\(state)","app":"claude-code","effective_app":"claude-code"\(extra),\
    "updated_at":"2026-10-30T11:57:49.385403-04:00"},"reason":"report"}
    """)
}

func view(blocks: [String]) -> [String: Any] {
    ["session_id": session, "label": "quiet-atoll", "active_window_id": "window:a",
     "windows": [["window_id": "window:a", "focused_block_id": blocks.first ?? "",
                  "layers": [["blocks": blocks.map { ["block_id": $0, "creator_name": "com.superlogical.terminal"] }]]]]]
}

func rexChecks() -> [(String, () throws -> Void)] { [
    ("Blocked agent needs the user", {
        var board = RexBoard()
        board.apply(view: view(blocks: [block]))
        try expect(board.apply(event: status("working", extra: #","msg":"Running tests""#)) == .updated)
        try expect(board.working.first?.message == "Running tests")
        try expect(board.apply(event: status("blocked", extra: #","kind":"permission""#)) == .needsUser(block))
        try expect(board.attention.first?.reason == "Wants permission")
        try expect(board.label(for: board.attention[0]) == "quiet-atoll")
    }),
    ("Seeing a finished pane clears it", {
        var board = RexBoard()
        board.apply(view: view(blocks: [block]))
        _ = board.apply(event: status("done"))
        try expect(board.attention.count == 1)
        board.markSeen(block)
        try expect(board.attention.isEmpty)
        _ = board.apply(event: status("working"))
        _ = board.apply(event: status("done"))
        try expect(board.attention.count == 1)
    }),
    ("Blocked outranks finished", {
        var board = RexBoard()
        let other = "block:other"
        board.apply(view: view(blocks: [block, other]))
        _ = board.apply(event: Data(String(decoding: status("done"), as: UTF8.self).replacingOccurrences(of: block, with: other).utf8))
        _ = board.apply(event: status("blocked"))
        try expect(board.attention.map(\.id) == [block, other])
    }),
    ("Notifications and bells surface idle panes", {
        var board = RexBoard()
        board.apply(view: view(blocks: [block]))
        try expect(board.apply(event: blockEvent("desktop_notification", #"{"title":"Claude Code","body":"Needs your input"}"#)) == .needsUser(block))
        try expect(board.attention.first?.reason == "Claude Code: Needs your input")
        _ = board.apply(event: status("working"))
        try expect(board.attention.isEmpty)
    }),
    ("Old finished work at startup is not news", {
        var board = RexBoard()
        board.apply(view: view(blocks: [block]))
        let record: [String: Any] = ["records": [["state": "done", "updated_at": "2026-10-29T21:44:10.879099-04:00"]]]
        board.seed(block: block, status: record, now: Date(timeIntervalSince1970: 1_793_400_000))
        try expect(board.attention.isEmpty)
    }),
    ("Closed panes and sessions disappear", {
        var board = RexBoard()
        board.apply(view: view(blocks: [block]))
        _ = board.apply(event: status("blocked"))
        _ = board.apply(event: Data(#"{"type":"session_destroyed","payload":{"session_id":"\#(session)"}}"#.utf8))
        try expect(board.panes.isEmpty)
    }),
    ("Unknown events and garbage are ignored", {
        var board = RexBoard()
        try expect(board.apply(event: Data("not json".utf8)) == .none)
        try expect(board.apply(event: Data(#"{"type":"client_joined","payload":{}}"#.utf8)) == .none)
        try expect(board.apply(event: status("weird")) == .updated)
        try expect(board.panes[block]?.state == .idle)
    }),
] }
