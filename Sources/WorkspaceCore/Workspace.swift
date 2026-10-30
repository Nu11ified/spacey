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

    // Splits into `count` equal parts with `gap` between them.
    public func split(_ count: Int, along layout: TileLayout, gap: Double) -> [Frame] {
        guard count > 1 else { return [self] }
        let n = Double(count)
        return (0..<count).map { index in
            let i = Double(index)
            switch layout {
            case .horizontal:
                let w = (width - gap * (n - 1)) / n
                return Frame(x: x + i * (w + gap), y: y, width: w, height: height)
            case .vertical:
                let h = (height - gap * (n - 1)) / n
                return Frame(x: x, y: y + i * (h + gap), width: width, height: h)
            }
        }
    }

    public func inset(_ amount: Double) -> Frame {
        Frame(x: x + amount, y: y + amount, width: max(1, width - 2 * amount), height: max(1, height - 2 * amount))
    }

    // Wider than tall reads side by side; taller than wide stacks.
    public var naturalLayout: TileLayout { height > width ? .vertical : .horizontal }
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

// A kind of work (Agents, Browser, Comms…) with its own workspaces 1–9. Option-<letter> focuses it.
public struct Category: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var letter: String
    public var icon: String
    public var color: String
    // Apps whose new windows open here. Spacey learns these when you move a window.
    public var apps: [String]

    public init(id: String, name: String, letter: String, icon: String, color: String, apps: [String] = []) {
        self.id = id; self.name = name; self.letter = letter; self.icon = icon; self.color = color; self.apps = apps
    }
}

public struct WindowRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var appID: String
    public var title: String
    public var accessibilityID: String
    public var category: String
    public var workspace: Int

    public init(id: UUID = UUID(), appID: String, title: String, accessibilityID: String = "",
                category: String, workspace: Int = 1) {
        self.id = id; self.appID = appID; self.title = title
        self.accessibilityID = accessibilityID; self.category = category; self.workspace = workspace
    }
}

// One monitor in a profile: which categories live on it and whether they share it side by side
// or take turns.
public struct ScreenSetup: Codable, Equatable, Sendable {
    public var categories: [String]
    public var split: Bool
    // How categories divide the screen when split; nil follows the screen's shape.
    public var layout: TileLayout?
    // The category shown when not split.
    public var showing: String?

    public init(categories: [String], split: Bool, layout: TileLayout? = nil, showing: String? = nil) {
        self.categories = categories; self.split = split; self.layout = layout; self.showing = showing
    }
}

// A monitor arrangement (desk, laptop alone…). Spacey keeps one per set of connected displays and
// switches automatically when monitors come and go.
public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var screens: [String: ScreenSetup]

    public init(name: String, screens: [String: ScreenSetup]) { self.name = name; self.screens = screens }
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
    public static let version = 3

    public var schemaVersion = DesktopState.version
    public var categories: [Category] = Category.standard
    public var windows: [WindowRecord] = []
    // Topology key → profile.
    public var profiles: [String: Profile] = [:]
    // Category → its active workspace.
    public var workspaces: [String: Int] = [:]
    public var focusedCategory: String?
    public var focusedWindow: UUID?
    // Show only the focused window.
    public var solo = false
    // "displayID|categoryID" → how windows inside that category's area are arranged.
    public var windowLayouts: [String: TileLayout] = [:]
    public var minimizedByManager: Set<UUID> = []
    // Pre-park frames of windows Spacey moved offscreen, so pause and crash recovery can restore them.
    public var parkedByManager: [UUID: Frame] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, categories, windows, profiles, workspaces, focusedCategory, focusedWindow, solo,
             windowLayouts, minimizedByManager, parkedByManager
    }

    // Fields added after a file was written decode to their defaults instead of rejecting the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? Category.standard
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
        profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        workspaces = try c.decodeIfPresent([String: Int].self, forKey: .workspaces) ?? [:]
        focusedCategory = try c.decodeIfPresent(String.self, forKey: .focusedCategory)
        focusedWindow = try c.decodeIfPresent(UUID.self, forKey: .focusedWindow)
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        windowLayouts = try c.decodeIfPresent([String: TileLayout].self, forKey: .windowLayouts) ?? [:]
        minimizedByManager = try c.decodeIfPresent(Set<UUID>.self, forKey: .minimizedByManager) ?? []
        parkedByManager = try c.decodeIfPresent([UUID: Frame].self, forKey: .parkedByManager) ?? [:]
    }

    public static func topologyKey(_ displays: [Display]) -> String {
        displays.map(\.id).sorted().joined(separator: "|")
    }

    public func record(_ id: UUID) -> WindowRecord? { windows.first { $0.id == id } }
    public func category(_ id: String?) -> Category? { categories.first { $0.id == id } }
    public func workspace(of category: String) -> Int { workspaces[category] ?? 1 }

    // The category a new window from this app joins: the one that claims the app, else the one
    // in focus, else the first.
    public func home(for appID: String) -> String {
        categories.first { $0.apps.contains(appID) }?.id ?? focusedCategory.flatMap { category($0)?.id } ?? categories[0].id
    }

    // Each workspace holds one window: a new window takes its category's first empty workspace,
    // or the current one if all nine are taken.
    public func freeWorkspace(in category: String, live: Set<UUID>) -> Int {
        let taken = Set(windows.filter { $0.category == category && live.contains($0.id) }.map(\.workspace))
        return (1...9).first { !taken.contains($0) } ?? workspace(of: category)
    }

    // Focus following a window: its category comes forward and shows the window's workspace.
    public mutating func follow(_ window: UUID, displays: [Display]) {
        guard let record = record(window) else { return }
        focusedWindow = window
        workspaces[record.category] = record.workspace
        focus(record.category, displays: displays)
    }

    // MARK: Profiles

    public func profile(for displays: [Display]) -> Profile? { profiles[Self.topologyKey(displays)] }

    // Makes sure this monitor arrangement has a profile and that every category lives on a screen.
    // A new arrangement spreads categories across screens, biggest screen first; a screen with more
    // than two categories shows one at a time.
    public mutating func ensureProfile(displays: [Display]) {
        guard !displays.isEmpty else { return }
        let key = Self.topologyKey(displays)
        let isNew = profiles[key] == nil
        var profile = profiles[key] ?? Profile(name: displays.count == 1 ? "Laptop" : "\(displays.count) screens", screens: [:])
        for display in displays where profile.screens[display.id] == nil {
            profile.screens[display.id] = ScreenSetup(categories: [], split: true)
        }
        let known = Set(categories.map(\.id))
        for id in profile.screens.keys { profile.screens[id]?.categories.removeAll { !known.contains($0) } }
        let placed = Set(profile.screens.values.flatMap(\.categories))
        let bySize = displays.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for category in categories where !placed.contains(category.id) {
            let target = bySize.min { (profile.screens[$0.id]?.categories.count ?? 0) < (profile.screens[$1.id]?.categories.count ?? 0) }!
            profile.screens[target.id]?.categories.append(category.id)
        }
        if isNew {
            for id in profile.screens.keys where (profile.screens[id]?.categories.count ?? 0) > 2 {
                profile.screens[id]?.split = false
            }
        }
        profiles[key] = profile
    }

    public func screen(of category: String, displays: [Display]) -> Display? {
        guard let profile = profile(for: displays) else { return displays.first }
        return displays.first { profile.screens[$0.id]?.categories.contains(category) == true } ?? displays.first
    }

    // The categories a screen is showing right now.
    public func visible(on display: Display, displays: [Display]) -> [String] {
        guard let setup = profile(for: displays)?.screens[display.id], !setup.categories.isEmpty else { return [] }
        if setup.split { return setup.categories }
        return [setup.showing.flatMap { setup.categories.contains($0) ? $0 : nil } ?? setup.categories[0]]
    }

    // MARK: Focus and moves

    // Focusing a category brings it forward on its screen if that screen takes turns.
    public mutating func focus(_ category: String, displays: [Display]) {
        guard self.category(category) != nil else { return }
        focusedCategory = category
        guard let display = screen(of: category, displays: displays) else { return }
        profiles[Self.topologyKey(displays)]?.screens[display.id]?.showing = category
    }

    public mutating func select(workspace: Int, in category: String, displays: [Display]) {
        guard (1...9).contains(workspace) else { return }
        workspaces[category] = workspace
        focus(category, displays: displays)
    }

    // Moving a window to a category also teaches Spacey where that app belongs.
    public mutating func move(window: UUID, to category: String) {
        guard self.category(category) != nil, let index = windows.firstIndex(where: { $0.id == window }) else { return }
        windows[index].category = category
        windows[index].workspace = workspace(of: category)
        let app = windows[index].appID
        for i in categories.indices {
            categories[i].apps.removeAll { $0 == app }
            if categories[i].id == category { categories[i].apps.append(app) }
        }
    }

    public mutating func move(window: UUID, toWorkspace number: Int) {
        guard (1...9).contains(number), let index = windows.firstIndex(where: { $0.id == window }) else { return }
        windows[index].workspace = number
    }

    // Puts a category on a screen in the current profile, taking it off any other screen.
    public mutating func place(_ category: String, on display: Display, displays: [Display]) {
        let key = Self.topologyKey(displays)
        guard var profile = profiles[key], self.category(category) != nil else { return }
        for id in profile.screens.keys { profile.screens[id]?.categories.removeAll { $0 == category } }
        profile.screens[display.id, default: ScreenSetup(categories: [], split: true)].categories.append(category)
        profile.screens[display.id]?.showing = category
        profiles[key] = profile
    }

    public mutating func toggleSplit(on display: Display, displays: [Display]) {
        profiles[Self.topologyKey(displays)]?.screens[display.id]?.split.toggle()
    }

    public mutating func setLayout(_ layout: TileLayout, display: Display, category: String) {
        windowLayouts["\(display.id)|\(category)"] = layout
    }

    // MARK: Categories

    // Letters Spacey already uses for other keys can't name a category.
    public static let reservedLetters: Set<Character> = ["h", "j", "k", "l", "f", "s", "q"]

    public func freeLetter(for name: String) -> String? {
        let taken = Set(categories.compactMap(\.letter.first)).union(Self.reservedLetters)
        let candidates = name.lowercased().filter(\.isLetter) + "abcdeginmoprtuvwxyz"
        return candidates.first { !taken.contains($0) }.map(String.init)
    }

    @discardableResult
    public mutating func addCategory(named name: String, icon: String = "square.grid.2x2", color: String = "#8E8E93",
                                     apps: [String] = []) -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !id.isEmpty, category(id) == nil, let letter = freeLetter(for: trimmed) else { return nil }
        let new = Category(id: id, name: trimmed, letter: letter, icon: icon, color: color, apps: apps)
        categories.append(new)
        return new
    }

    // Deletes a category; its windows move to the first remaining one. The last category stays.
    public mutating func removeCategory(_ id: String, displays: [Display]) {
        guard categories.count > 1, let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories.remove(at: index)
        let fallback = categories[0].id
        for i in windows.indices where windows[i].category == id { windows[i].category = fallback }
        if focusedCategory == id { focusedCategory = fallback }
        workspaces[id] = nil
        for key in profiles.keys {
            for screen in profiles[key]!.screens.keys { profiles[key]!.screens[screen]!.categories.removeAll { $0 == id } }
        }
        ensureProfile(displays: displays)
    }

    // Replaces the categories with a new set (from Apple Intelligence or the config) and re-sorts
    // every window by the apps each category claims. Profiles keep their screens; new categories
    // are spread over them by ensureProfile.
    public mutating func adopt(_ new: [Category], displays: [Display]) {
        guard !new.isEmpty else { return }
        categories = new
        for index in windows.indices {
            windows[index].category = categories.first { $0.apps.contains(windows[index].appID) }?.id
                ?? (category(windows[index].category)?.id ?? categories[0].id)
        }
        if category(focusedCategory) == nil { focusedCategory = categories[0].id }
        ensureProfile(displays: displays)
    }

    // MARK: Layout

    public func plan(displays: [Display], live: [LiveWindow], gap: Double = 10) -> [Placement] {
        guard !displays.isEmpty else { return [] }
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        func showable(_ record: WindowRecord) -> Bool {
            guard let window = liveByID[record.id] else { return false }
            return !window.minimized || minimizedByManager.contains(record.id)
        }
        var result: [Placement] = []
        var shown: Set<UUID> = []
        if solo, let id = focusedWindow, let record = record(id), showable(record),
           let display = screen(of: record.category, displays: displays) {
            result.append(Placement(id: id, frame: display.usableFrame.inset(gap), hidden: false))
            shown.insert(id)
        } else {
            for display in displays {
                // A category with nothing in its current workspace gives its share of the screen away.
                let groups = visible(on: display, displays: displays).map { category in
                    (category, windows.filter { $0.category == category && $0.workspace == workspace(of: category) && showable($0) })
                }.filter { !$0.1.isEmpty }
                guard !groups.isEmpty else { continue }
                let setup = profile(for: displays)?.screens[display.id]
                let area = display.usableFrame.inset(gap)
                let regions = area.split(groups.count, along: setup?.layout ?? area.naturalLayout, gap: gap)
                for ((category, members), region) in zip(groups, regions) {
                    let layout = windowLayouts["\(display.id)|\(category)"] ?? region.naturalLayout
                    for (record, frame) in zip(members, region.split(members.count, along: layout, gap: gap)) {
                        result.append(Placement(id: record.id, frame: frame, hidden: false))
                        shown.insert(record.id)
                    }
                }
            }
        }
        for record in windows where liveByID[record.id] != nil && !shown.contains(record.id) {
            result.append(Placement(id: record.id, frame: nil, hidden: true))
        }
        return result
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

    // Swapping two windows exchanges their places, including category and workspace when they sit
    // in different areas.
    public mutating func swap(_ a: UUID, _ b: UUID) {
        guard let i = windows.firstIndex(where: { $0.id == a }), let j = windows.firstIndex(where: { $0.id == b }) else { return }
        let (category, workspace) = (windows[i].category, windows[i].workspace)
        windows[i].category = windows[j].category; windows[i].workspace = windows[j].workspace
        windows[j].category = category; windows[j].workspace = workspace
        windows.swapAt(i, j)
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

    // Older state files start fresh: their records can't be mapped onto categories, and window
    // positions are rebuilt within a second anyway.
    public func load() throws -> DesktopState {
        guard FileManager.default.fileExists(atPath: url.path) else { return DesktopState() }
        let data = try Data(contentsOf: url)
        struct Version: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        if version < DesktopState.version { return DesktopState() }
        guard version == DesktopState.version else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(DesktopState.self, from: data)
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
