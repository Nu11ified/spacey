import Foundation

// ~/.config/spacey/config.json. Every field is optional; anything missing uses the defaults below.
public struct SpaceyConfig: Codable, Equatable, Sendable {
    public struct Mode: Codable, Equatable, Sendable {
        public var name: String
        // An SF Symbol name.
        public var icon: String
        // "#RRGGBB".
        public var color: String
        // Bundle identifiers that always open in this mode. Everything else joins the mode you're in.
        public var apps: [String]

        public init(name: String, icon: String, color: String, apps: [String]) {
            self.name = name; self.icon = icon; self.color = color; self.apps = apps
        }
    }

    public var modes: [Mode]
    public var gap: Double
    public var dock: Bool
    // Option-<key> opens the app, or a new window of it when it's already in front.
    // Keys are single letters or "return"; values are bundle identifiers.
    public var launch: [String: String]

    public init(modes: [Mode], gap: Double = 10, dock: Bool = true, launch: [String: String] = Self.defaultLaunch) {
        self.modes = Array(modes.prefix(9)); self.gap = gap; self.dock = dock; self.launch = launch
    }

    public static let defaultLaunch = [
        "b": "app.zen-browser.zen", "return": "com.mitchellh.ghostty", "r": "com.superlogical.rex",
        "u": "com.termius-dmg.mac", "e": "org.gnu.Emacs", "v": "com.microsoft.VSCode",
        "c": "com.todesktop.230313mzl4w4u92", "i": "com.apple.MobileSMS", "d": "com.hnc.Discord",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let modes = try c.decodeIfPresent([Mode].self, forKey: .modes) ?? Self.standard.modes
        self.init(modes: modes.isEmpty ? Self.standard.modes : modes,
                  gap: try c.decodeIfPresent(Double.self, forKey: .gap) ?? 10,
                  dock: try c.decodeIfPresent(Bool.self, forKey: .dock) ?? true,
                  launch: try c.decodeIfPresent([String: String].self, forKey: .launch) ?? Self.defaultLaunch)
    }

    // Modes are filled by what you open in them. Add bundle IDs to a mode's apps to always open them there.
    public static let standard = SpaceyConfig(modes: [
        Mode(name: "Build", icon: "hammer.fill", color: "#5B8CFF", apps: []),
        Mode(name: "Research", icon: "globe", color: "#2EC4B6", apps: []),
        Mode(name: "Chat", icon: "bubble.left.and.bubble.right.fill", color: "#3DDC84",
             apps: []),
        Mode(name: "Write", icon: "pencil", color: "#FF9F1C", apps: []),
        Mode(name: "Music", icon: "music.note", color: "#FF5C8A", apps: []),
    ])

    // The first mode that lists the app, as a 1-based mode number.
    public func mode(for appID: String) -> Int? {
        modes.firstIndex { $0.apps.contains(appID) }.map { $0 + 1 }
    }

    public static func load(_ url: URL) throws -> SpaceyConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        return try JSONDecoder().decode(SpaceyConfig.self, from: Data(contentsOf: url))
    }
}
