import Foundation

// Rex panes report their state with the Program Status Protocol (OSC 7501).
// The board keeps one record per terminal block and ranks what needs the user.
public enum RexState: String, Codable, Sendable {
    case idle, working, done, blocked, error

    public init(report: String?) { self = RexState(rawValue: report ?? "") ?? .idle }
}

public struct RexPane: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var windowID: String?
    public var title = ""
    public var app = ""
    public var state = RexState.idle
    public var kind: String?
    public var message = ""
    public var updatedAt = Date.distantPast
    public var seen = true
    public var notification: String?

    public init(id: String, sessionID: String) { self.id = id; self.sessionID = sessionID }

    public var needsUser: Bool {
        switch state {
        case .blocked, .error: true
        case .done: !seen
        case .idle, .working: notification != nil
        }
    }

    // Lower sorts first.
    public var urgency: Int {
        switch state {
        case .blocked: 0
        case .error: 1
        case .done: 2
        case .idle, .working: 3
        }
    }

    public var name: String {
        if !title.isEmpty { return title }
        return app.isEmpty ? "Terminal" : app
    }

    public var reason: String {
        switch state {
        case .blocked:
            switch kind {
            case "permission": "Wants permission"
            case "question": "Has a question"
            case "auth": "Needs credentials"
            default: "Waiting for you"
            }
        case .error: "Failed"
        case .done: "Finished"
        case .working: message.isEmpty ? "Working" : message
        case .idle: notification ?? "Idle"
        }
    }
}

public enum RexChange: Equatable, Sendable {
    case none, updated
    case needsUser(String)
    case views(Set<String>)
}

public struct RexBoard: Sendable {
    public private(set) var panes: [String: RexPane] = [:]
    public private(set) var sessionLabels: [String: String] = [:]
    public private(set) var focusedBlocks: [String: String] = [:]

    public init() {}

    public var attention: [RexPane] {
        panes.values.filter(\.needsUser).sorted {
            $0.urgency == $1.urgency ? $0.updatedAt > $1.updatedAt : $0.urgency < $1.urgency
        }
    }

    public var working: [RexPane] {
        panes.values.filter { $0.state == .working && !$0.needsUser }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func label(for pane: RexPane) -> String { sessionLabels[pane.sessionID] ?? "" }

    public mutating func markSeen(_ block: String) {
        panes[block]?.seen = true
        panes[block]?.notification = nil
    }

    public mutating func setTitle(_ title: String, block: String) { panes[block]?.title = title }

    public mutating func setSessions(_ labels: [String: String]) {
        sessionLabels = labels
        panes = panes.filter { labels[$0.value.sessionID] != nil }
    }

    // A done report older than `stale` at startup is history, not news.
    public mutating func seed(block: String, status: [String: Any], now: Date, stale: TimeInterval = 600) {
        guard var pane = panes[block],
              let record = (status["records"] as? [[String: Any]])?.first(where: { $0["id"] == nil }) else { return }
        Self.apply(record: record, to: &pane)
        if pane.state == .done, now.timeIntervalSince(pane.updatedAt) > stale { pane.seen = true }
        panes[block] = pane
    }

    // Accepts a session.view result. New terminal blocks get records; vanished blocks are dropped.
    @discardableResult
    public mutating func apply(view: [String: Any]) -> [String] {
        guard let session = view["session_id"] as? String else { return [] }
        if let label = view["label"] as? String { sessionLabels[session] = label }
        var present: Set<String> = []
        var added: [String] = []
        for window in view["windows"] as? [[String: Any]] ?? [] {
            let windowID = window["window_id"] as? String
            if windowID == view["active_window_id"] as? String, let focused = window["focused_block_id"] as? String {
                focusedBlocks[session] = focused
            }
            for layer in window["layers"] as? [[String: Any]] ?? [] {
                for block in layer["blocks"] as? [[String: Any]] ?? [] {
                    guard let id = block["block_id"] as? String,
                          (block["creator_name"] as? String) == "com.superlogical.terminal" else { continue }
                    present.insert(id)
                    if panes[id] == nil { panes[id] = RexPane(id: id, sessionID: session); added.append(id) }
                    panes[id]?.windowID = windowID
                }
            }
        }
        panes = panes.filter { $0.value.sessionID != session || present.contains($0.key) }
        return added
    }

    // Accepts one line of `rex events --all --json`.
    public mutating func apply(event line: Data, now: Date = Date()) -> RexChange {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String, let payload = event["payload"] as? [String: Any] else { return .none }
        switch type {
        case "session_created":
            guard let session = payload["session"] as? [String: Any], let id = session["session_id"] as? String else { return .none }
            sessionLabels[id] = session["label"] as? String ?? ""
            return .views([id])
        case "session_destroyed":
            guard let id = payload["session_id"] as? String else { return .none }
            sessionLabels[id] = nil
            focusedBlocks[id] = nil
            panes = panes.filter { $0.value.sessionID != id }
            return .updated
        case "session_event":
            guard let session = payload["session_id"] as? String,
                  let inner = payload["event"] as? [String: Any], let kind = inner["type"] as? String else { return .none }
            let body = inner["payload"] as? [String: Any] ?? [:]
            switch kind {
            case "block_event": return apply(block: body, session: session, now: now)
            case "session_label_changed":
                sessionLabels[session] = body["label"] as? String ?? ""
                return .updated
            case "block_closed":
                if let id = body["block_id"] as? String { panes[id] = nil }
                return .updated
            case "session_view_changed", "active_window_changed": return .views([session])
            default: return .none
            }
        default: return .none
        }
    }

    mutating func apply(block body: [String: Any], session: String, now: Date) -> RexChange {
        guard let id = body["block_id"] as? String, (body["creator_name"] as? String) == "com.superlogical.terminal",
              let name = body["name"] as? String else { return .none }
        let fields = body["payload"] as? [String: Any] ?? [:]
        var pane = panes[id] ?? RexPane(id: id, sessionID: session)
        let before = pane.needsUser
        switch name {
        case "program_status_changed":
            // Child records (build/test) describe sub-tasks; the root record is the pane's state.
            guard (fields["id"] as? String ?? "").isEmpty, let record = fields["record"] as? [String: Any] else { return .none }
            let previous = pane.state
            Self.apply(record: record, to: &pane)
            if pane.state != previous || pane.state == .blocked { pane.seen = false }
            if pane.state == .working { pane.notification = nil }
        case "program_status_removed":
            guard (fields["ids"] as? [String] ?? []).contains("") else { return .none }
            pane.state = .idle; pane.kind = nil; pane.message = ""
        case "title_changed":
            pane.title = fields["title"] as? String ?? ""
        case "bell":
            pane.notification = pane.notification ?? "Rang the bell"
            pane.updatedAt = now
        case "desktop_notification":
            let text = [fields["title"], fields["body"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            pane.notification = text.isEmpty ? "Sent a notification" : text.joined(separator: ": ")
            pane.updatedAt = now
        default: return .none
        }
        panes[id] = pane
        return !before && pane.needsUser ? .needsUser(id) : .updated
    }

    nonisolated(unsafe) static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func apply(record: [String: Any], to pane: inout RexPane) {
        pane.state = RexState(report: record["state"] as? String)
        pane.kind = record["kind"] as? String
        pane.app = record["effective_app"] as? String ?? record["app"] as? String ?? pane.app
        pane.message = record["msg"] as? String ?? ""
        if let stamp = record["updated_at"] as? String {
            pane.updatedAt = timestamps.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) ?? pane.updatedAt
        }
    }
}
