import AppKit
import WorkspaceCore

// Talks to the local Rex server through its CLI: one long-lived `rex events` stream for changes,
// plus short API calls to seed state and to jump to a pane.
@MainActor
final class RexBridge {
    static let bundleID = "com.superlogical.rex"

    var board = RexBoard()
    var connected = false
    var onChange: (RexChange) -> Void = { _ in }
    private var stream: Process?
    private var buffer = Data()
    private var backoff = 1.0
    private var pendingViews: Set<String> = []
    private var viewWork: DispatchWorkItem?

    nonisolated static var cli: URL? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.superlogical.rex/RexServer")
        let linked = support.appendingPathComponent("CLI/rex")
        if fm.isExecutableFile(atPath: linked.path) { return linked }
        let versions = support.appendingPathComponent("Versions")
        let newest = (try? fm.contentsOfDirectory(atPath: versions.path))?
            .compactMap(Int.init).max()
        if let newest {
            let binary = versions.appendingPathComponent("\(newest)/Rex Server.app/Contents/MacOS/rex")
            if fm.isExecutableFile(atPath: binary.path) { return binary }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("rex")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var appRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    static var appFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

    // Never starts a Rex server on its own; Spacey only follows one that is already running.
    static func run(_ arguments: [String]) async -> [String: Any]? {
        guard let cli else { return nil }
        let output = await Task.detached { () -> Data? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = cli
            process.arguments = arguments + ["--autostart=false", "--timeout", "3s"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        guard let output else { return nil }
        return try? JSONSerialization.jsonObject(with: output) as? [String: Any]
    }

    static func call(_ method: String, _ args: [String: Any]) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return await run(["api", "call", method, json])
    }

    func start() {
        guard stream == nil, let cli = Self.cli else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = cli
        process.arguments = ["events", "--all", "--json", "--autostart=false"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamEnded() } }
        }
        do { try process.run() } catch { return }
        stream = process
        Task { await seed() }
    }

    func stop() {
        stream?.terminationHandler = nil
        stream?.terminate()
        stream = nil
    }

    private func streamEnded() {
        stream = nil
        buffer.removeAll()
        if connected { connected = false; onChange(.updated) }
        // Rex quit or restarted its server. Come back quietly, slower each time.
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
        backoff = min(backoff * 2, 30)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(board.apply(event: Data(line)))
        }
    }

    private func handle(_ change: RexChange) {
        if case .views(let sessions) = change {
            pendingViews.formUnion(sessions)
            viewWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let sessions = self.pendingViews
                    self.pendingViews.removeAll()
                    Task { for session in sessions { await self.refresh(session: session) } }
                }
            }
            viewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        if change != .none { onChange(change) }
    }

    func seed() async {
        guard let list = await Self.call("session.list", [:]),
              let sessions = list["sessions"] as? [[String: Any]] else { return }
        var labels: [String: String] = [:]
        for session in sessions {
            if let id = session["session_id"] as? String { labels[id] = session["label"] as? String ?? "" }
        }
        board.setSessions(labels)
        for id in labels.keys { await refresh(session: id, seeding: true) }
        connected = true
        backoff = 1
        onChange(.updated)
    }

    func refresh(session: String, seeding: Bool = false) async {
        guard let view = await Self.call("session.view", ["session_id": session]) else { return }
        let added = board.apply(view: view)
        for block in seeding ? Array(board.panes.values.filter { $0.sessionID == session }.map(\.id)) : added {
            let target: [String: Any] = ["session_id": session, "block_id": block]
            if let status = await Self.call("block.method", target.merging(["method": "program_status"]) { $1 }) {
                board.seed(block: block, status: status, now: Date())
            }
            if let title = await Self.call("block.method", target.merging(["method": "title"]) { $1 })?["title"] as? String {
                board.setTitle(title, block: block)
            }
        }
        if Self.appFrontmost { acknowledgeFocused() }
        onChange(.updated)
    }

    // Whatever the user is looking at in Rex has been seen.
    func acknowledgeFocused() {
        for block in board.focusedBlocks.values where board.panes[block]?.needsUser == true {
            board.markSeen(block)
        }
    }

    func jump(to pane: RexPane) async {
        board.markSeen(pane.id)
        onChange(.updated)
        let clients = await Self.call("client.list", [:])?["clients"] as? [[String: Any]] ?? []
        let app = clients.first {
            ($0["info"] as? [String: Any])?["kind"] as? String == "app" &&
            ($0["session_ids"] as? [String] ?? []).contains(pane.sessionID)
        } ?? clients.first { ($0["info"] as? [String: Any])?["kind"] as? String == "app" }
        if let client = app?["client_id"] as? String {
            var args: [String: Any] = ["session_id": pane.sessionID]
            if let window = pane.windowID { args["window_id"] = window }
            _ = await Self.call("client.perform", ["client_id": client, "action": "session.select", "args": args])
        }
        _ = await Self.call("session.focus_block", ["session_id": pane.sessionID, "block_id": pane.id])
    }
}
