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
    // Windows here float over whatever you're working on instead of taking a tile: Finder,
    // settings, small utilities. Minimize one and the work underneath is just as it was.
    public var floating: Bool?

    public init(id: String, name: String, letter: String, icon: String, color: String, apps: [String] = [],
                floating: Bool? = nil) {
        self.id = id; self.name = name; self.letter = letter; self.icon = icon; self.color = color; self.apps = apps
        self.floating = floating
    }

    public var overlay: Bool { floating == true }
}

public struct WindowRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var appID: String
    public var title: String
    public var accessibilityID: String
    public var category: String
    public var workspace: Int
    // Put into a workspace that already had a window, on purpose, so it shares rather than being
    // moved to a workspace of its own.
    public var together: Bool?

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
    // Categories taken off every monitor on purpose. Their windows stay parked until the category is
    // put back, and Spacey doesn't place them on its own.
    public var unplaced: [String]?
    // The monitors as they were last connected, so setup can draw a profile that isn't in use and
    // a new desk can start from the profile whose monitors look most like its own.
    public var displays: [Display]?

    public init(name: String, screens: [String: ScreenSetup], unplaced: [String]? = nil, displays: [Display]? = nil) {
        self.name = name; self.screens = screens; self.unplaced = unplaced; self.displays = displays
    }
}

// What a category's area on one screen shows instead of its own workspace, after a window from
// elsewhere was brought into it (a link opened from Slack, say).
public struct Slot: Codable, Equatable, Sendable {
    public var category: String
    public var workspace: Int

    public init(category: String, workspace: Int) { self.category = category; self.workspace = workspace }
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
    // "displayID|categoryID" → what that area shows instead, until restored.
    public var overrides: [String: Slot] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, categories, windows, profiles, workspaces, focusedCategory, focusedWindow, solo,
             windowLayouts, minimizedByManager, parkedByManager, overrides
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
        overrides = try c.decodeIfPresent([String: Slot].self, forKey: .overrides) ?? [:]
    }

    public static func topologyKey(_ displays: [Display]) -> String {
        displays.map(\.id).sorted().joined(separator: "|")
    }

    public func record(_ id: UUID) -> WindowRecord? { windows.first { $0.id == id } }
    public func isOverlay(_ id: UUID) -> Bool { record(id).flatMap { category($0.category) }?.overlay == true }
    public var others: Category? { categories.first { $0.overlay } }

    // Every desktop has a floating category for Finder, settings and small utilities. The first
    // time it's added, windows of the apps it claims move into it, out of wherever they landed.
    public mutating func ensureOthers() {
        guard others == nil else { return }
        var others = Category.others
        let used = Set(categories.compactMap(\.letter.first)).union(Self.reservedLetters)
        if used.contains("o"), let free = "otxyzuvwpgderi".first(where: { !used.contains($0) }) { others.letter = String(free) }
        if categories.contains(where: { $0.id == others.id }) { others.id = "others-floating" }
        for index in categories.indices { categories[index].apps.removeAll { others.apps.contains($0) } }
        categories.append(others)
        for index in windows.indices where others.apps.contains(windows[index].appID) {
            windows[index].category = others.id
            windows[index].workspace = 1
            windows[index].together = nil
        }
    }
    public func category(_ id: String?) -> Category? { categories.first { $0.id == id } }
    public func workspace(of category: String) -> Int { workspaces[category] ?? 1 }

    // The category a new window from this app joins: the one that claims the app, else the one
    // in focus, else the first.
    public func home(for appID: String) -> String {
        categories.first { $0.apps.contains(appID) }?.id
            ?? focusedCategory.flatMap { category($0) }.flatMap { $0.overlay ? nil : $0.id } ?? categories[0].id
    }

    // Each workspace holds one window: a new window takes its category's first empty workspace,
    // or the current one if all nine are taken.
    public func freeWorkspace(in category: String, live: Set<UUID>) -> Int {
        let taken = Set(windows.filter { $0.category == category && live.contains($0.id) }.map(\.workspace))
        return (1...9).first { !taken.contains($0) } ?? workspace(of: category)
    }

    // Focus following a window: its category comes forward and shows the window's workspace. If the
    // category is on several screens and none shows it, it appears on `preferred` (or the first).
    public mutating func follow(_ window: UUID, displays: [Display], preferred: Display? = nil) {
        guard let record = record(window) else { return }
        focusedWindow = window
        if isOverlay(window) { return }
        if let showing = hosts(of: record.category, displays: displays)
            .first(where: { workspace(of: record.category, on: $0, displays: displays) == record.workspace }) {
            focus(record.category, on: showing, displays: displays)
        } else {
            select(workspace: record.workspace, in: record.category, on: preferred, displays: displays)
        }
    }

    // MARK: Bringing a window into the area you're in

    // Shows a window's category and workspace in place of `category`'s area on `display`.
    public mutating func summon(_ window: UUID, into display: Display, replacing category: String) {
        guard let record = record(window) else { return }
        overrides["\(display.id)|\(category)"] = Slot(category: record.category, workspace: record.workspace)
        focusedWindow = window
        focusedCategory = record.category
    }

    // Puts the area back to its own category and workspace.
    public mutating func restore(_ category: String, on display: Display) {
        overrides["\(display.id)|\(category)"] = nil
        focusedCategory = category
    }

    // Drops takeovers whose windows are gone or whose area no longer exists.
    public mutating func pruneOverrides(live: Set<UUID>, displays: [Display]) {
        overrides = overrides.filter { key, slot in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let display = displays.first(where: { $0.id == parts[0] }),
                  hosts(of: parts[1], displays: displays).contains(where: { $0.id == display.id }) else { return false }
            return windows.contains { $0.category == slot.category && $0.workspace == slot.workspace && live.contains($0.id) }
        }
    }

    // A window in `category`'s `workspace` was closed or minimized. Screens showing that workspace,
    // now empty, move to the nearest workspace of the category that still has a window and isn't
    // showing elsewhere. With nothing left, the area simply gives its space away.
    public mutating func fallBack(from category: String, workspace number: Int, visible: Set<UUID>, displays: [Display]) {
        if self.category(category)?.overlay == true { return }
        let hosts = hosts(of: category, displays: displays)
        let occupied = Set(windows.filter { $0.category == category && visible.contains($0.id) }.map(\.workspace))
        guard !occupied.contains(number) else { return }
        for host in hosts where workspace(of: category, on: host, displays: displays) == number {
            let elsewhere = Set(hosts.filter { $0.id != host.id }.map { workspace(of: category, on: $0, displays: displays) })
            let candidates = occupied.subtracting(elsewhere).sorted { abs($0 - number) == abs($1 - number) ? $0 < $1 : abs($0 - number) < abs($1 - number) }
            guard let next = candidates.first else { continue }
            if hosts.count > 1 { select(workspace: next, in: category, on: host, displays: displays) } else { workspaces[category] = next }
        }
    }

    // MARK: Areas and their keys

    // One category on one screen. Each area has its own Option-letter: a category's first screen
    // (left to right) uses the category's letter, and any further screen gets the next free letter
    // of the category's name, so Browser on two monitors is Option-B and Option-R.
    public struct Area: Equatable, Sendable {
        public var display: String
        public var category: String
        public var letter: String
    }

    public func areas(displays: [Display]) -> [Area] {
        guard let profile = profile(for: displays) else { return [] }
        let ordered = displays.sorted { $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x }
        var taken = Set(categories.compactMap(\.letter.first)).union(Self.reservedLetters)
        var seen: Set<String> = []
        var result: [Area] = []
        for display in ordered {
            for id in profile.screens[display.id]?.categories ?? [] {
                guard let category = category(id) else { continue }
                if seen.insert(id).inserted {
                    result.append(Area(display: display.id, category: id, letter: category.letter))
                } else if let letter = (category.name.lowercased().filter(\.isLetter) + "abcdeginmoprtuvwxyz").first(where: { !taken.contains($0) }) {
                    taken.insert(letter)
                    result.append(Area(display: display.id, category: id, letter: String(letter)))
                }
            }
        }
        return result
    }

    // MARK: Categories on several screens

    // The screens a category is on, left to right.
    public func hosts(of category: String, displays: [Display]) -> [Display] {
        guard let profile = profile(for: displays) else { return Array(displays.prefix(1)) }
        return displays.filter { profile.screens[$0.id]?.categories.contains(category) == true }
            .sorted { $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x }
    }

    // A category on several screens shows a different workspace on each. The first screen uses the
    // category's own workspace; the others remember theirs, defaulting to the next workspace along
    // that holds a window and isn't showing elsewhere.
    public func workspace(of category: String, on display: Display, displays: [Display]) -> Int {
        let hosts = hosts(of: category, displays: displays)
        guard hosts.count > 1, let index = hosts.firstIndex(where: { $0.id == display.id }), index > 0 else {
            return workspace(of: category)
        }
        if let own = workspaces["\(category)|\(display.id)"] { return own }
        let earlier = Set(hosts.prefix(index).map { workspace(of: category, on: $0, displays: displays) })
        let order = (1...9).map { (workspace(of: category) - 1 + $0) % 9 + 1 }.filter { !earlier.contains($0) }
        let used = Set(windows.filter { $0.category == category }.map(\.workspace))
        return order.first { used.contains($0) } ?? order.first ?? 1
    }

    private mutating func show(_ number: Int, of category: String, on display: Display, hosts: [Display]) {
        if display.id == hosts.first?.id { workspaces[category] = number } else { workspaces["\(category)|\(display.id)"] = number }
    }

    // Shows a category on another screen too, keeping it where it already is.
    public mutating func add(_ category: String, to display: Display, displays: [Display]) {
        let key = Self.topologyKey(displays)
        guard self.category(category)?.overlay == false, profiles[key]?.screens[display.id]?.categories.contains(category) == false else { return }
        let before = hosts(of: category, displays: displays).map { ($0, workspace(of: category, on: $0, displays: displays)) }
        profiles[key]?.unplaced?.removeAll { $0 == category }
        profiles[key]?.screens[display.id]?.categories.append(category)
        profiles[key]?.screens[display.id]?.showing = category
        // Screens that already showed the category keep showing the same workspace.
        let hosts = hosts(of: category, displays: displays)
        for (host, number) in before { show(number, of: category, on: host, hosts: hosts) }
    }

    // Takes a category off a screen. Off its last screen, it waits in `unplaced` with its windows
    // parked until it's put back.
    public mutating func remove(_ category: String, from display: Display, displays: [Display]) {
        let key = Self.topologyKey(displays)
        let hosts = hosts(of: category, displays: displays)
        guard hosts.contains(where: { $0.id == display.id }) else { return }
        if hosts.count == 1 {
            profiles[key]?.screens[display.id]?.categories.removeAll { $0 == category }
            if profiles[key]?.screens[display.id]?.showing == category { profiles[key]?.screens[display.id]?.showing = nil }
            let unplaced = (profiles[key]?.unplaced ?? []) + [category]
            profiles[key]?.unplaced = unplaced
            return
        }
        let kept = hosts.filter { $0.id != display.id }.map { ($0, workspace(of: category, on: $0, displays: displays)) }
        profiles[key]?.screens[display.id]?.categories.removeAll { $0 == category }
        if profiles[key]?.screens[display.id]?.showing == category { profiles[key]?.screens[display.id]?.showing = nil }
        workspaces["\(category)|\(display.id)"] = nil
        let remaining = self.hosts(of: category, displays: displays)
        for (host, number) in kept { show(number, of: category, on: host, hosts: remaining) }
    }

    // MARK: Profiles

    public func profile(for displays: [Display]) -> Profile? { profiles[Self.topologyKey(displays)] }

    // Makes sure this monitor arrangement has a profile and that every category lives on a screen.
    // A new arrangement starts from the saved profile whose monitors look most like its own (a
    // second desk with the same monitors works at once). Failing that, categories are spread across
    // screens, biggest first, and a screen with more than two shows one at a time.
    public mutating func ensureProfile(displays: [Display]) {
        guard !displays.isEmpty else { return }
        ensureOthers()
        let key = Self.topologyKey(displays)
        let isNew = profiles[key] == nil
        var profile: Profile
        if let existing = profiles[key] {
            profile = existing
        } else if let source = closestProfile(to: displays) {
            profile = Self.adapt(source, to: displays)
            profile.name = uniqueProfileName(source.name)
        } else {
            profile = Profile(name: uniqueProfileName(Self.defaultName(for: displays)), screens: [:])
        }
        profile.displays = displays
        for display in displays where profile.screens[display.id] == nil {
            profile.screens[display.id] = ScreenSetup(categories: [], split: true)
        }
        let known = Set(categories.filter { !$0.overlay }.map(\.id))
        for id in profile.screens.keys { profile.screens[id]?.categories.removeAll { !known.contains($0) } }
        profile.unplaced?.removeAll { !known.contains($0) }
        let placed = Set(profile.screens.values.flatMap(\.categories)).union(profile.unplaced ?? [])
        let bySize = displays.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for category in categories where !placed.contains(category.id) && !category.overlay {
            let target = bySize.min { (profile.screens[$0.id]?.categories.count ?? 0) < (profile.screens[$1.id]?.categories.count ?? 0) }!
            profile.screens[target.id]?.categories.append(category.id)
        }
        if isNew {
            for id in profile.screens.keys where (profile.screens[id]?.categories.count ?? 0) > 2 {
                profile.screens[id]?.split = false
            }
        }
        if profiles[key] != profile { profiles[key] = profile }
    }

    static func defaultName(for displays: [Display]) -> String {
        if displays.count == 1 { return displays[0].name.contains("Built-in") ? "Laptop" : displays[0].name }
        return "Desk"
    }

    func uniqueProfileName(_ base: String) -> String {
        let taken = Set(profiles.values.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }

    // The saved profile, for other monitors, whose monitors best match these: the same number,
    // each paired with one of the same shape, preferring the same model.
    public func closestProfile(to displays: [Display]) -> Profile? {
        let key = Self.topologyKey(displays)
        return profiles.filter { $0.key != key }.sorted { $0.key < $1.key }.compactMap { _, profile -> (Profile, Int)? in
            guard let saved = profile.displays, saved.count == displays.count else { return nil }
            let pairs = Self.pair(saved, with: displays)
            guard pairs.allSatisfy({ target, source in
                let a = displays.first { $0.id == target }!, b = saved.first { $0.id == source }!
                return Self.vertical(a) == Self.vertical(b)
            }) else { return nil }
            let score = pairs.filter { target, source in
                displays.first { $0.id == target }!.name == saved.first { $0.id == source }!.name
            }.count
            return (profile, score)
        }.max { $0.1 < $1.1 }?.0
    }

    static func vertical(_ display: Display) -> Bool { display.frame.height > display.frame.width }

    // Pairs each of `targets` (by id) with one of `sources`, left to right, preferring the same
    // model and then the same shape.
    static func pair(_ sources: [Display], with targets: [Display]) -> [String: String] {
        let order: (Display, Display) -> Bool = { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
        var free = sources.sorted(by: order)
        var pairs: [String: String] = [:]
        for target in targets.sorted(by: order) where !free.isEmpty {
            let best = free.indices.max { a, b in
                let score = { (d: Display) in (d.name == target.name ? 2 : 0) + (vertical(d) == vertical(target) ? 1 : 0) }
                return (score(free[a]), b) < (score(free[b]), a)
            }!
            pairs[target.id] = free.remove(at: best).id
        }
        return pairs
    }

    // `profile`'s arrangement moved onto `displays`, monitor by monitor.
    static func adapt(_ profile: Profile, to displays: [Display]) -> Profile {
        var adapted = Profile(name: profile.name, screens: [:], unplaced: profile.unplaced, displays: displays)
        for (target, source) in pair(profile.displays ?? [], with: displays) {
            var setup = profile.screens[source] ?? ScreenSetup(categories: [], split: true)
            setup.showing = setup.showing.flatMap { setup.categories.contains($0) ? $0 : nil }
            adapted.screens[target] = setup
        }
        return adapted
    }

    // Replaces the arrangement for these monitors with another profile's, keeping this one's name.
    public mutating func copyProfile(_ sourceKey: String, displays: [Display]) {
        let key = Self.topologyKey(displays)
        guard sourceKey != key, let source = profiles[sourceKey] else { return }
        let name = profiles[key]?.name ?? source.name
        var copy = Self.adapt(source, to: displays)
        copy.name = name
        profiles[key] = copy
        for display in displays { for id in copy.screens[display.id]?.categories ?? [] { workspaces["\(id)|\(display.id)"] = nil } }
        overrides = overrides.filter { area, _ in !displays.contains { area.hasPrefix($0.id + "|") } }
        ensureProfile(displays: displays)
    }

    // Forgets a profile for monitors that aren't connected.
    public mutating func deleteProfile(_ key: String, displays: [Display]) {
        guard key != Self.topologyKey(displays) else { return }
        profiles[key] = nil
    }

    public func isUnplaced(_ category: String, displays: [Display]) -> Bool {
        profile(for: displays)?.unplaced?.contains(category) == true
    }

    public func screen(of category: String, displays: [Display]) -> Display? {
        hosts(of: category, displays: displays).first ?? displays.first
    }

    // The categories a screen is showing right now.
    public func visible(on display: Display, displays: [Display]) -> [String] {
        guard let setup = profile(for: displays)?.screens[display.id], !setup.categories.isEmpty else { return [] }
        if setup.split { return setup.categories }
        return [setup.showing.flatMap { setup.categories.contains($0) ? $0 : nil } ?? setup.categories[0]]
    }

    // MARK: Focus and moves

    // Focusing a category brings it forward on its screen if that screen takes turns.
    public mutating func focus(_ category: String, on display: Display? = nil, displays: [Display]) {
        guard self.category(category)?.overlay == false else { return }
        focusedCategory = category
        let hosts = hosts(of: category, displays: displays)
        guard let target = display.flatMap({ d in hosts.first { $0.id == d.id } }) ?? hosts.first else { return }
        profiles[Self.topologyKey(displays)]?.screens[target.id]?.showing = category
    }

    // Shows a workspace on `display` (when the category is there) or the category's first screen.
    // On a category spread over several screens, a workspace already showing elsewhere swaps places.
    public mutating func select(workspace number: Int, in category: String, on display: Display? = nil, displays: [Display]) {
        guard (1...9).contains(number) else { return }
        let hosts = hosts(of: category, displays: displays)
        let area = display.flatMap { d in hosts.first { $0.id == d.id } } ?? hosts.first
        if let area { overrides["\(area.id)|\(category)"] = nil }
        guard hosts.count > 1, let target = display.flatMap({ d in hosts.first { $0.id == d.id } }) ?? hosts.first else {
            workspaces[category] = number
            focus(category, displays: displays)
            return
        }
        var current = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, workspace(of: category, on: $0, displays: displays)) })
        if let other = hosts.first(where: { $0.id != target.id && current[$0.id] == number }) { current[other.id] = current[target.id] }
        current[target.id] = number
        for host in hosts { show(current[host.id]!, of: category, on: host, hosts: hosts) }
        focus(category, on: target, displays: displays)
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

    // `live` tells which windows still exist, so moving into a workspace that holds one counts as
    // choosing to share it.
    public mutating func move(window: UUID, toWorkspace number: Int, live: Set<UUID> = []) {
        guard (1...9).contains(number), let index = windows.firstIndex(where: { $0.id == window }) else { return }
        let category = windows[index].category
        windows[index].workspace = number
        windows[index].together = windows.contains { $0.id != window && $0.category == category && $0.workspace == number && live.contains($0.id) } ? true : nil
    }

    // Puts a window in a category's workspace. Whatever was there takes the window's old place, in
    // its old category if that was different.
    public mutating func exchange(_ window: UUID, category: String, workspace number: Int, live: Set<UUID>) {
        guard (1...9).contains(number), self.category(category) != nil, let record = record(window) else { return }
        let (fromCategory, fromWorkspace) = (record.category, record.workspace)
        for index in windows.indices where windows[index].id != window && live.contains(windows[index].id)
            && windows[index].category == category && windows[index].workspace == number {
            windows[index].category = fromCategory
            windows[index].workspace = fromWorkspace
            windows[index].together = nil
        }
        if category != fromCategory { move(window: window, to: category) }
        if let index = windows.firstIndex(where: { $0.id == window }) {
            windows[index].workspace = number
            windows[index].together = nil
        }
    }

    // One window per workspace: when windows share one without that being chosen, every window after
    // the first moves to the next empty workspace of its category.
    public mutating func separate(live: Set<UUID>) {
        var seen: Set<String> = []
        for index in windows.indices where live.contains(windows[index].id) && !isOverlay(windows[index].id) {
            let key = "\(windows[index].category)|\(windows[index].workspace)"
            if seen.insert(key).inserted || windows[index].together == true { continue }
            let free = freeWorkspace(in: windows[index].category, live: live)
            if free != windows[index].workspace { windows[index].workspace = free; seen.insert("\(windows[index].category)|\(free)") }
        }
    }

    // Puts a category on a screen in the current profile, taking it off any other screen. `before`
    // places it ahead of another category on that screen; otherwise it goes last.
    public mutating func place(_ category: String, on display: Display, before: String? = nil, displays: [Display]) {
        let key = Self.topologyKey(displays)
        guard var profile = profiles[key], self.category(category)?.overlay == false else { return }
        for id in profile.screens.keys { profile.screens[id]?.categories.removeAll { $0 == category } }
        profile.unplaced?.removeAll { $0 == category }
        var order = profile.screens[display.id]?.categories ?? []
        order.insert(category, at: before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        profile.screens[display.id, default: ScreenSetup(categories: [], split: true)].categories = order
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
        guard categories.count > 1, let index = categories.firstIndex(where: { $0.id == id }), !categories[index].overlay else { return }
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
            // Windows brought into another area show there, not in their own.
            var claimed: Set<UUID> = []
            for display in displays {
                for category in visible(on: display, displays: displays) {
                    guard let slot = overrides["\(display.id)|\(category)"] else { continue }
                    windows.filter { $0.category == slot.category && $0.workspace == slot.workspace }.forEach { claimed.insert($0.id) }
                }
            }
            for display in displays {
                // A category with nothing in its current workspace gives its share of the screen away.
                let groups = visible(on: display, displays: displays).map { category in
                    if let slot = overrides["\(display.id)|\(category)"] {
                        return (category, windows.filter { $0.category == slot.category && $0.workspace == slot.workspace && showable($0) && !shown.contains($0.id) })
                    }
                    let number = workspace(of: category, on: display, displays: displays)
                    return (category, windows.filter { $0.category == category && $0.workspace == number && showable($0) && !shown.contains($0.id) && !claimed.contains($0.id) })
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
            // Overlays float where they are; only minimizing or closing puts them away.
            if category(record.category)?.overlay == true {
                result.append(Placement(id: record.id, frame: nil, hidden: !showable(record)))
                continue
            }
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
