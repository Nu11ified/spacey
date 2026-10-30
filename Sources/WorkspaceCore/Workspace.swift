import Foundation

public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
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
public enum Direction: Sendable { case left, right, up, down }

// A mode is one of the user's named contexts (Build, Web, Chat…). It spans every display:
// switching modes changes all screens at once, and each window remembers which screen it
// lives on separately for every combination of connected displays.
public struct WindowRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var appID: String
    public var title: String
    public var accessibilityID: String
    // 1-based. 0 means every mode: the window stays on its screen whichever mode is active.
    public var mode: Int
    // Topology key → display ID.
    public var displays: [String: String]
    // Moved to a mode by hand, so the config's app rules no longer apply to it.
    public var pinned: Bool?

    public init(id: UUID = UUID(), appID: String, title: String, accessibilityID: String = "",
                mode: Int, displays: [String: String] = [:]) {
        self.id = id; self.appID = appID; self.title = title
        self.accessibilityID = accessibilityID; self.mode = mode; self.displays = displays
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

public struct Placement: Equatable, Sendable {
    public var id: UUID
    public var frame: Frame?
    public var hidden: Bool
}

public struct DesktopState: Codable, Equatable, Sendable {
    public static let version = 2

    public var schemaVersion = DesktopState.version
    public var windows: [WindowRecord] = []
    public var mode = 1
    public var focusedWindow: UUID?
    // Show only the focused window, everything else in the mode parked.
    public var solo = false
    public var layoutOverrides: [String: [Int: TileLayout]] = [:]
    public var minimizedByManager: Set<UUID> = []
    // Pre-park frames of windows Spacey moved offscreen, so pause and crash recovery can restore them.
    public var parkedByManager: [UUID: Frame] = [:]
    // The display set seen by the last settle; a change means macOS moved windows, not the user.
    public var lastTopology: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, windows, mode, focusedWindow, solo, layoutOverrides, minimizedByManager, parkedByManager, lastTopology
    }

    // Fields added after a file was written decode to their defaults instead of rejecting the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
        mode = try c.decodeIfPresent(Int.self, forKey: .mode) ?? 1
        focusedWindow = try c.decodeIfPresent(UUID.self, forKey: .focusedWindow)
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        layoutOverrides = try c.decodeIfPresent([String: [Int: TileLayout]].self, forKey: .layoutOverrides) ?? [:]
        minimizedByManager = try c.decodeIfPresent(Set<UUID>.self, forKey: .minimizedByManager) ?? []
        parkedByManager = try c.decodeIfPresent([UUID: Frame].self, forKey: .parkedByManager) ?? [:]
        lastTopology = try c.decodeIfPresent(String.self, forKey: .lastTopology)
    }

    public static func topologyKey(_ displays: [Display]) -> String {
        displays.map(\.id).sorted().joined(separator: "|")
    }

    public func record(_ id: UUID) -> WindowRecord? { windows.first { $0.id == id } }

    // The screen a window belongs on right now. In order: what it was given for this exact set of
    // displays, any screen it has lived on that is still connected, the screen it is on, the first.
    public func display(of record: WindowRecord, displays: [Display], live: Frame?) -> Display {
        let present = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        if let id = record.displays[Self.topologyKey(displays)], let display = present[id] { return display }
        if let display = record.displays.values.sorted().compactMap({ present[$0] }).first { return display }
        if let live, let display = displays.first(where: { $0.frame.contains(x: live.midX, y: live.midY) }) { return display }
        return displays[0]
    }

    // Pins every live window to a screen for this topology so later moves are stable, and adopts
    // a screen change when the user drags a visible window onto another display. Right after a
    // display connects or disconnects, macOS has shuffled windows itself, so nothing is adopted.
    public mutating func settle(displays: [Display], live: [LiveWindow]) {
        guard !displays.isEmpty else { return }
        let key = Self.topologyKey(displays)
        let stable = lastTopology == key
        lastTopology = key
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        for index in windows.indices {
            guard let window = liveByID[windows[index].id] else { continue }
            let assigned = display(of: windows[index], displays: displays, live: window.frame)
            var target = assigned.id
            let visible = (windows[index].mode == mode || windows[index].mode == 0) && !window.minimized && parkedByManager[windows[index].id] == nil
            if stable, visible, let dragged = displays.first(where: { $0.frame.contains(x: window.frame.midX, y: window.frame.midY) }),
               dragged.id != assigned.id {
                target = dragged.id
            }
            windows[index].displays[key] = target
        }
    }

    public mutating func select(_ mode: Int, count: Int) {
        guard (1...max(1, count)).contains(mode) else { return }
        self.mode = mode
    }

    public mutating func assign(window: UUID, to mode: Int) {
        guard (0...9).contains(mode), let index = windows.firstIndex(where: { $0.id == window }) else { return }
        windows[index].mode = mode
        windows[index].pinned = true
    }

    // The config is the source of truth for apps it names, except for windows moved by hand.
    public mutating func applyRules(_ config: SpaceyConfig) {
        for index in windows.indices where windows[index].pinned != true {
            if let mode = config.mode(for: windows[index].appID) { windows[index].mode = mode }
        }
    }

    public mutating func move(window: UUID, to display: Display, displays: [Display]) {
        guard let index = windows.firstIndex(where: { $0.id == window }) else { return }
        windows[index].displays[Self.topologyKey(displays)] = display.id
    }

    // The nearest visible window in a direction, by centre, across every display. Windows straight
    // ahead win over ones off to the side.
    public static func neighbour(of origin: Frame, in direction: Direction, among candidates: [(UUID, Frame)]) -> UUID? {
        candidates.compactMap { id, frame -> (UUID, Double)? in
            let dx = frame.midX - origin.midX, dy = frame.midY - origin.midY
            let (ahead, side): (Double, Double) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard ahead > 1 else { return nil }
            return (id, ahead + 2 * abs(side))
        }.min { $0.1 < $1.1 }?.0
    }

    // Swapping two windows swaps their places in the tiling order and, if they're on different
    // screens, their screens too.
    public mutating func swap(_ a: UUID, _ b: UUID, displays: [Display]) {
        guard let i = windows.firstIndex(where: { $0.id == a }), let j = windows.firstIndex(where: { $0.id == b }) else { return }
        let key = Self.topologyKey(displays)
        let (first, second) = (windows[i].displays[key], windows[j].displays[key])
        windows[i].displays[key] = second
        windows[j].displays[key] = first
        windows.swapAt(i, j)
    }

    public mutating func setLayout(_ layout: TileLayout, on display: Display) {
        layoutOverrides[display.id, default: [:]][mode] = layout
    }

    public func layout(on display: Display) -> TileLayout {
        layoutOverrides[display.id]?[mode] ?? (display.frame.height > display.frame.width ? .vertical : .horizontal)
    }

    public func plan(displays: [Display], live: [LiveWindow], gap: Double = 10) -> [Placement] {
        guard !displays.isEmpty else { return [] }
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var result: [Placement] = []
        var shown: Set<UUID> = []
        for display in displays {
            let members = windows.filter { record in
                guard record.mode == mode || record.mode == 0, let window = liveByID[record.id] else { return false }
                if solo && record.id != focusedWindow { return false }
                guard !window.minimized || minimizedByManager.contains(record.id) else { return false }
                return self.display(of: record, displays: displays, live: window.frame).id == display.id
            }
            guard !members.isEmpty else { continue }
            let layout = self.layout(on: display)
            let area = display.usableFrame
            let count = Double(members.count)
            let innerWidth = max(1, area.width - 2 * gap)
            let innerHeight = max(1, area.height - 2 * gap)
            let width = layout == .horizontal ? max(1, (innerWidth - gap * (count - 1)) / count) : innerWidth
            let height = layout == .vertical ? max(1, (innerHeight - gap * (count - 1)) / count) : innerHeight
            for (index, record) in members.enumerated() {
                shown.insert(record.id)
                let frame = Frame(x: area.x + gap + (layout == .horizontal ? Double(index) * (width + gap) : 0),
                                  y: area.y + gap + (layout == .vertical ? Double(index) * (height + gap) : 0),
                                  width: width, height: height)
                result.append(Placement(id: record.id, frame: frame, hidden: false))
            }
        }
        for record in windows where liveByID[record.id] != nil && !shown.contains(record.id) {
            result.append(Placement(id: record.id, frame: nil, hidden: true))
        }
        return result
    }

    // Hidden windows sit just past a screen corner, like AeroSpace, so switching is an instant move
    // instead of a minimize animation. The corner whose spill-over covers the least of any other
    // display wins, so a parked window never peeks onto a neighbouring monitor.
    public static func parkingFrame(for window: Frame, on display: Display, among displays: [Display]) -> Frame {
        let d = display.frame
        let corners = [Frame(x: d.x + d.width - 1, y: d.y + d.height - 1, width: window.width, height: window.height),
                       Frame(x: d.x - window.width + 1, y: d.y + d.height - 1, width: window.width, height: window.height),
                       Frame(x: d.x + d.width - 1, y: d.y - window.height + 1, width: window.width, height: window.height),
                       Frame(x: d.x - window.width + 1, y: d.y - window.height + 1, width: window.width, height: window.height)]
        func overlap(_ a: Frame, _ b: Frame) -> Double {
            max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x)) *
            max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        }
        let others = displays.filter { $0.id != display.id }
        return corners.min { a, b in
            others.reduce(0) { $0 + overlap(a, $1.frame) } < others.reduce(0) { $0 + overlap(b, $1.frame) }
        }!
    }
}

public struct StateStore {
    public var url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> DesktopState {
        guard FileManager.default.fileExists(atPath: url.path) else { return DesktopState() }
        let state = try JSONDecoder().decode(DesktopState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == DesktopState.version else { throw CocoaError(.fileReadCorruptFile) }
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
