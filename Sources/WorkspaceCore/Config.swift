import Foundation

extension Category {
    // Where common apps belong until Apple Intelligence (or you) sorts them differently.
    public static let standard: [Category] = [
        Category(id: "agents", name: "Agents", letter: "a", icon: "terminal.fill", color: "#5B8CFF",
                 apps: ["com.superlogical.rex", "com.openai.codex", "com.anthropic.claudefordesktop", "com.mitchellh.ghostty",
                        "dev.warp.Warp-Stable", "com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode",
                        "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed", "com.termius-dmg.mac",
                        "com.tinyapp.TablePlus", "com.usebruno.app", "org.gnu.Emacs"]),
        Category(id: "browser", name: "Browser", letter: "b", icon: "globe", color: "#2EC4B6",
                 apps: ["app.zen-browser.zen", "net.imput.helium", "com.google.Chrome", "com.apple.Safari",
                        "company.thebrowser.Browser", "org.mozilla.firefox"]),
        Category(id: "comms", name: "Comms", letter: "c", icon: "bubble.left.and.bubble.right.fill", color: "#3DDC84",
                 apps: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "com.apple.mail",
                        "com.apple.iCal", "us.zoom.xos", "com.microsoft.teams2", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp"]),
        Category(id: "notes", name: "Notes", letter: "n", icon: "note.text", color: "#FF9F1C",
                 apps: ["com.apple.Notes", "notion.id", "md.obsidian", "net.shinyfrog.bear"]),
        Category(id: "media", name: "Media", letter: "m", icon: "music.note", color: "#FF5C8A",
                 apps: ["com.apple.Music", "com.spotify.client", "com.apple.TV"]),
        others,
    ]

    // Floats over your work: file browsing, settings, and small tools you open and put away.
    public static let others = Category(
        id: "others", name: "Others", letter: "o", icon: "square.on.square", color: "#8E8E93",
        apps: ["com.apple.finder", "com.apple.systempreferences", "io.tailscale.ipn.macos", "io.tailscale.ipn.macsys",
               "com.apple.ActivityMonitor", "com.apple.calculator", "com.apple.archiveutility", "com.apple.DiskUtility",
               "com.apple.keychainaccess", "com.apple.ScreenSharing", "com.apple.FontBook", "com.apple.Passwords",
               "com.1password.1password", "com.bitwarden.desktop", "com.apple.AppStore", "com.apple.Console",
               "com.apple.Digital-Color-Meter", "com.apple.print.PrinterProxy", "com.apple.BluetoothFileExchange",
               "com.raycast.macos", "com.surteesstudios.Bartender", "com.apple.Image_Capture", "com.apple.findmy"],
        floating: true)
}

// ~/.config/spacey/config.json. Every field is optional.
public struct SpaceyConfig: Codable, Equatable, Sendable {
    public var gap: Double
    public var dock: Bool
    // When set, these replace the categories Spacey (or Apple Intelligence) made. Leave it out to
    // let Spacey manage categories.
    public var categories: [Category]?

    public init(gap: Double = 10, dock: Bool = true, categories: [Category]? = nil) {
        self.gap = gap; self.dock = dock; self.categories = categories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(gap: try c.decodeIfPresent(Double.self, forKey: .gap) ?? 10,
                  dock: try c.decodeIfPresent(Bool.self, forKey: .dock) ?? true,
                  categories: try c.decodeIfPresent([Category].self, forKey: .categories))
    }

    public static let standard = SpaceyConfig()

    public static func load(_ url: URL) throws -> SpaceyConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        return try JSONDecoder().decode(SpaceyConfig.self, from: Data(contentsOf: url))
    }
}
