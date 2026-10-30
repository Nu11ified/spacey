import Foundation

public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func approximatelyEquals(_ other: Frame) -> Bool {
        abs(x - other.x) < 2 && abs(y - other.y) < 2 &&
        abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}

public struct Display: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: Frame
    public var usableFrame: Frame

    public init(id: String, name: String, frame: Frame, usableFrame: Frame? = nil) {
        self.id = id; self.name = name; self.frame = frame
        self.usableFrame = usableFrame ?? frame
    }
}

public enum TileLayout: String, Codable, Sendable { case horizontal, vertical }
public enum FocusMode: String, Codable, CaseIterable, Sendable {
    case allDisplays, workspace, window
}

public struct WindowRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var appID: String
    public var title: String
    public var accessibilityID: String
    public var workspace: Int

    public init(id: UUID = UUID(), appID: String, title: String,
                accessibilityID: String = "", workspace: Int) {
        self.id = id; self.appID = appID; self.title = title
        self.accessibilityID = accessibilityID; self.workspace = workspace
    }
}

public struct LiveWindow: Sendable {
    public var id: UUID
    public var frame: Frame
    public var minimized: Bool

    public init(id: UUID, frame: Frame, minimized: Bool = false) {
        self.id = id; self.frame = frame; self.minimized = minimized
    }
}

public struct DesktopState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var windows: [WindowRecord] = []
    public var focusedWorkspace = 1
    public var focusedWindow: UUID?
    public var mode: FocusMode = .allDisplays
    public var activeByDisplay: [String: Int] = [:]
    public var activeProfiles: [String: [String: Int]] = [:]
    public var lastTopologyKey: String?
    public var topologyProfiles: [String: [Int: String]] = [:]
    public var layoutOverrides: [String: [Int: TileLayout]] = [:]
    public var minimizedByManager: Set<UUID> = []

    public init() {}

    public static func topologyKey(_ displays: [Display]) -> String {
        displays.map(\.id).sorted().joined(separator: "|")
    }

    // Screen observations can change geometry, but never window membership.
    public mutating func reconcile(displays: [Display]) {
        guard !displays.isEmpty else { return }
        let key = Self.topologyKey(displays)
        if lastTopologyKey != key {
            if let previous = lastTopologyKey { activeProfiles[previous] = activeByDisplay }
            activeByDisplay = activeProfiles[key] ?? [:]
            lastTopologyKey = key
        }
        if topologyProfiles[key] == nil {
            let sorted = displays.sorted {
                $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
            }
            var next = 1
            var assignments: [Int: String] = [:]
            for (index, display) in sorted.enumerated() {
                let count = 9 / sorted.count + (index < 9 % sorted.count ? 1 : 0)
                for _ in 0..<count {
                    assignments[next] = display.id
                    next += 1
                }
            }
            topologyProfiles[key] = assignments
        }
        let assignments = topologyProfiles[key] ?? [:]
        for display in displays {
            let members = assignments.filter { $0.value == display.id }.keys.sorted()
            guard let first = members.first else { continue }
            if !members.contains(activeByDisplay[display.id] ?? 0) {
                activeByDisplay[display.id] = first
            }
        }
        if let displayID = assignments[focusedWorkspace] {
            activeByDisplay[displayID] = focusedWorkspace
        }
    }

    public mutating func select(_ workspace: Int, displays: [Display]) {
        guard (1...9).contains(workspace) else { return }
        focusedWorkspace = workspace
        reconcile(displays: displays)
    }

    public mutating func assign(window: UUID, to workspace: Int) {
        guard (1...9).contains(workspace), let index = windows.firstIndex(where: { $0.id == window }) else { return }
        windows[index].workspace = workspace
    }

    public mutating func setLayout(_ layout: TileLayout, displays: [Display]) {
        guard let displayID = topologyProfiles[Self.topologyKey(displays)]?[focusedWorkspace] else { return }
        layoutOverrides[displayID, default: [:]][focusedWorkspace] = layout
    }

    public func plan(displays: [Display], live: [LiveWindow], gap: Double = 8) -> [Placement] {
        var result: [Placement] = []
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let assignments = topologyProfiles[Self.topologyKey(displays)] ?? [:]
        var visible: Set<UUID> = []
        for display in displays {
            guard let workspace = activeByDisplay[display.id], assignments[workspace] == display.id else { continue }
            if mode != .allDisplays && workspace != focusedWorkspace { continue }
            let candidates = windows.filter { record in
                guard record.workspace == workspace, let window = liveByID[record.id] else { return false }
                if mode == .window && record.id != focusedWindow { return false }
                return !window.minimized || minimizedByManager.contains(record.id)
            }
            let layout = layoutOverrides[display.id]?[workspace] ??
                (display.frame.height > display.frame.width ? .vertical : .horizontal)
            let area = display.usableFrame
            let count = Double(candidates.count)
            guard count > 0 else { continue }
            let innerWidth = max(1, area.width - 2 * gap)
            let innerHeight = max(1, area.height - 2 * gap)
            for (index, window) in candidates.enumerated() {
                visible.insert(window.id)
                let width = layout == .horizontal ? max(1, (innerWidth - gap * (count - 1)) / count) : innerWidth
                let height = layout == .vertical ? max(1, (innerHeight - gap * (count - 1)) / count) : innerHeight
                let frame = Frame(x: area.x + gap + (layout == .horizontal ? Double(index) * (width + gap) : 0),
                                  y: area.y + gap + (layout == .vertical ? Double(index) * (height + gap) : 0),
                                  width: width, height: height)
                result.append(Placement(id: window.id, frame: frame, hidden: false))
            }
        }
        for window in windows where liveByID[window.id] != nil && !visible.contains(window.id) {
            result.append(Placement(id: window.id, frame: nil, hidden: true))
        }
        return result
    }
}

public struct Placement: Equatable, Sendable {
    public var id: UUID
    public var frame: Frame?
    public var hidden: Bool
}

public struct StateStore {
    public var url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> DesktopState {
        guard FileManager.default.fileExists(atPath: url.path) else { return DesktopState() }
        let state = try JSONDecoder().decode(DesktopState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    public func save(_ state: DesktopState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let current = try? Data(contentsOf: url), current == data { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
