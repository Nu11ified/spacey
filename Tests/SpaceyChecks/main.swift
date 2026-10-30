import Foundation
import WorkspaceCore

// Laptop below, a portrait monitor to the upper left and a landscape monitor above.
let laptop = Display(id: "laptop", name: "MacBook", frame: Frame(x: 0, y: 0, width: 1512, height: 982))
let portrait = Display(id: "portrait", name: "External", frame: Frame(x: -1080, y: -1080, width: 1080, height: 1920))
let landscape = Display(id: "landscape", name: "External", frame: Frame(x: 0, y: -1080, width: 1920, height: 1080))
let desk = [laptop, portrait, landscape]

struct CheckFailure: Error { var message: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = #function) throws {
    if try !condition() { throw CheckFailure(message: message) }
}

func center(of display: Display) -> Frame {
    Frame(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
}

// Three Build windows, one per screen, and one Chat window on the laptop.
func deskState() -> (DesktopState, [LiveWindow]) {
    var state = DesktopState()
    state.windows = [
        WindowRecord(appID: "rex", title: "Rex", mode: 1),
        WindowRecord(appID: "code", title: "Editor", mode: 1),
        WindowRecord(appID: "zen", title: "Docs", mode: 1),
        WindowRecord(appID: "slack", title: "Slack", mode: 3),
    ]
    let live = [LiveWindow(id: state.windows[0].id, frame: center(of: portrait)),
                LiveWindow(id: state.windows[1].id, frame: center(of: landscape)),
                LiveWindow(id: state.windows[2].id, frame: center(of: laptop)),
                LiveWindow(id: state.windows[3].id, frame: center(of: laptop))]
    state.settle(displays: desk, live: live)
    return (state, live)
}

func screen(of id: UUID, in placements: [Placement], displays: [Display]) -> String? {
    guard let frame = placements.first(where: { $0.id == id })?.frame else { return nil }
    return displays.first { $0.frame.contains(x: frame.midX, y: frame.midY) }?.id
}

let checks: [(String, () throws -> Void)] = [
    ("A mode spans every screen", {
        let (state, live) = deskState()
        let plan = state.plan(displays: desk, live: live)
        try expect(screen(of: state.windows[0].id, in: plan, displays: desk) == "portrait")
        try expect(screen(of: state.windows[1].id, in: plan, displays: desk) == "landscape")
        try expect(screen(of: state.windows[2].id, in: plan, displays: desk) == "laptop")
        try expect(plan.first { $0.id == state.windows[3].id }?.hidden == true)
    }),
    ("Unplugging collapses onto the laptop and replugging restores each screen", {
        var (state, live) = deskState()
        let memberships = state.windows.map(\.mode)
        state.settle(displays: [laptop], live: live)
        let alone = state.plan(displays: [laptop], live: live)
        try expect(alone.filter { !$0.hidden }.count == 3)
        try expect(alone.compactMap(\.frame).allSatisfy { laptop.frame.contains(x: $0.midX, y: $0.midY) })
        // Back at the desk, windows are wherever the laptop-only tiling left them.
        let tiled = alone.compactMap { p in p.frame.map { LiveWindow(id: p.id, frame: $0) } }
        state.settle(displays: desk, live: tiled)
        let back = state.plan(displays: desk, live: tiled)
        try expect(screen(of: state.windows[0].id, in: back, displays: desk) == "portrait")
        try expect(screen(of: state.windows[1].id, in: back, displays: desk) == "landscape")
        try expect(state.windows.map(\.mode) == memberships)
    }),
    ("Switching modes changes every screen at once", {
        var (state, live) = deskState()
        state.select(3, count: 5)
        let plan = state.plan(displays: desk, live: live)
        try expect(plan.filter { !$0.hidden }.map(\.id) == [state.windows[3].id])
    }),
    ("Portrait stacks and landscape sits side by side", {
        var state = DesktopState()
        state.windows = (0..<2).map { WindowRecord(appID: "t", title: "\($0)", mode: 1) }
        let up = state.windows.map { LiveWindow(id: $0.id, frame: center(of: portrait)) }
        state.settle(displays: [portrait], live: up)
        let stacked = state.plan(displays: [portrait], live: up).compactMap(\.frame)
        try expect(stacked[0].x == stacked[1].x && stacked[0].y + stacked[0].height < stacked[1].y)
        var wide = DesktopState()
        wide.windows = state.windows.map { WindowRecord(id: $0.id, appID: "t", title: $0.title, mode: 1) }
        let across = wide.windows.map { LiveWindow(id: $0.id, frame: center(of: landscape)) }
        wide.settle(displays: [landscape], live: across)
        let side = wide.plan(displays: [landscape], live: across).compactMap(\.frame)
        try expect(side[0].y == side[1].y && side[0].x + side[0].width < side[1].x)
    }),
    ("Dragging a window to another screen sticks", {
        var (state, live) = deskState()
        var moved = live
        moved[2].frame = center(of: landscape)
        state.settle(displays: desk, live: moved)
        try expect(screen(of: state.windows[2].id, in: state.plan(displays: desk, live: moved), displays: desk) == "landscape")
    }),
    ("Parked windows don't count as drags", {
        var (state, live) = deskState()
        var parked = live
        parked[3].frame = DesktopState.parkingFrame(for: live[3].frame, on: laptop, among: desk)
        state.parkedByManager[state.windows[3].id] = live[3].frame
        state.settle(displays: desk, live: parked)
        try expect(state.windows[3].displays[DesktopState.topologyKey(desk)] == "laptop")
    }),
    ("A chosen layout survives reconnecting", {
        var (state, live) = deskState()
        state.setLayout(.vertical, on: landscape)
        state.settle(displays: [laptop], live: live)
        state.settle(displays: desk, live: live)
        try expect(state.layout(on: landscape) == .vertical)
        try expect(state.layout(on: portrait) == .vertical && state.layout(on: laptop) == .horizontal)
    }),
    ("Focus shows only the focused window and keeps everything else", {
        var (state, live) = deskState()
        let modes = state.windows.map(\.mode)
        state.solo = true
        state.focusedWindow = state.windows[1].id
        try expect(state.plan(displays: desk, live: live).filter { !$0.hidden }.map(\.id) == [state.windows[1].id])
        try expect(state.windows.map(\.mode) == modes)
    }),
    ("User-minimized windows stay minimized", {
        var (state, live) = deskState()
        live[0].minimized = true
        try expect(state.plan(displays: desk, live: live).first { $0.id == state.windows[0].id }?.hidden == true)
        state.minimizedByManager.insert(state.windows[0].id)
        try expect(state.plan(displays: desk, live: live).first { $0.id == state.windows[0].id }?.hidden == false)
    }),
    ("Apps open in the mode that claims them", {
        let config = SpaceyConfig.standard
        try expect(config.mode(for: "com.superlogical.rex") == nil)
        try expect(config.mode(for: "app.zen-browser.zen") == nil)
        try expect(config.mode(for: "com.example.unknown") == nil)
    }),
    ("A partial config keeps the rest of the defaults", {
        let partial = try JSONDecoder().decode(SpaceyConfig.self, from: Data(#"{"gap": 14}"#.utf8))
        try expect(partial.gap == 14 && partial.modes == SpaceyConfig.standard.modes && partial.dock)
        let mine = try JSONDecoder().decode(SpaceyConfig.self, from: Data(##"{"modes":[{"name":"Deep","icon":"moon","color":"#000000","apps":[]}]}"##.utf8))
        try expect(mine.modes.map(\.name) == ["Deep"])
    }),
    ("A window shown in every mode shares its screen with each mode", {
        var (state, live) = deskState()
        state.assign(window: state.windows[3].id, to: 0)
        for mode in [1, 3] {
            state.select(mode, count: 5)
            let plan = state.plan(displays: desk, live: live)
            try expect(plan.first { $0.id == state.windows[3].id }?.hidden == false)
        }
        state.select(1, count: 5)
        let onLaptop = state.plan(displays: desk, live: live).filter { p in
            p.frame.map { laptop.frame.contains(x: $0.midX, y: $0.midY) } == true }
        try expect(onLaptop.count == 2)
    }),
    ("State survives restart", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("desktop.json"))
        var (state, _) = deskState()
        state.select(3, count: 5)
        try store.save(state)
        try expect(try store.load() == state)
    }),
    ("Corrupt state remains untouched", {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("broken".utf8).write(to: file)
        var rejected = false
        do { _ = try StateStore(url: file).load() } catch { rejected = true }
        try expect(rejected)
        try expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    }),
]

let all = checks + navigationChecks() + rexChecks() + parkingChecks()
var failures = 0
for (name, run) in all {
    do { try run(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
if failures > 0 { exit(1) }
print("\(all.count) checks passed")
