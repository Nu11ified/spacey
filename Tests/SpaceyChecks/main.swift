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

func live(_ state: DesktopState, minimized: Set<UUID> = []) -> [LiveWindow] {
    state.windows.map { LiveWindow(id: $0.id, frame: Frame(x: 0, y: 0, width: 400, height: 300), minimized: minimized.contains($0.id)) }
}

func frame(_ id: UUID, _ plan: [Placement]) -> Frame? { plan.first { $0.id == id }?.frame }
func hidden(_ id: UUID, _ plan: [Placement]) -> Bool { plan.first { $0.id == id }?.hidden == true }

// The setup from the request: Comms above Browser on the portrait monitor, Agents on the wide one.
func deskState() -> (DesktopState, slack: UUID, zen1: UUID, zen2: UUID, rex: UUID) {
    var state = DesktopState()
    state.profiles[DesktopState.topologyKey(desk)] = Profile(name: "Desk", screens: [
        "landscape": ScreenSetup(categories: ["agents"], split: true),
        "portrait": ScreenSetup(categories: ["comms", "browser"], split: true),
        "laptop": ScreenSetup(categories: ["notes", "media"], split: true),
    ])
    let slack = WindowRecord(appID: "com.tinyspeck.slackmacgap", title: "Slack", category: "comms", workspace: 1)
    let zen1 = WindowRecord(appID: "app.zen-browser.zen", title: "Docs", category: "browser", workspace: 1)
    let zen2 = WindowRecord(appID: "app.zen-browser.zen", title: "PR", category: "browser", workspace: 2)
    let rex = WindowRecord(appID: "com.superlogical.rex", title: "Rex", category: "agents", workspace: 1)
    state.windows = [slack, zen1, zen2, rex]
    return (state, slack.id, zen1.id, zen2.id, rex.id)
}

let checks: [(String, () throws -> Void)] = [
    ("Comms over Browser on the vertical monitor, each on its own workspace", {
        var (state, slack, zen1, zen2, rex) = deskState()
        state.select(workspace: 2, in: "browser", displays: desk)
        let plan = state.plan(displays: desk, live: live(state))
        let top = try frame(slack, plan).unwrap(), bottom = try frame(zen2, plan).unwrap()
        try expect(portrait.frame.contains(x: top.midX, y: top.midY) && portrait.frame.contains(x: bottom.midX, y: bottom.midY))
        try expect(top.y + top.height < bottom.y && abs(top.width - bottom.width) < 1)
        try expect(hidden(zen1, plan))
        let agents = try frame(rex, plan).unwrap()
        try expect(landscape.frame.contains(x: agents.midX, y: agents.midY))
    }),
    ("An empty category gives its share of the screen away", {
        var (state, slack, _, _, _) = deskState()
        state.select(workspace: 5, in: "browser", displays: desk)
        let plan = state.plan(displays: desk, live: live(state))
        try expect(try frame(slack, plan).unwrap().height > portrait.frame.height * 0.9)
    }),
    ("Browser on two monitors shows a different workspace on each", {
        var (state, _, zen1, zen2, _) = deskState()
        state.add("browser", to: landscape, displays: desk)
        var plan = state.plan(displays: desk, live: live(state))
        let left = try frame(zen1, plan).unwrap(), right = try frame(zen2, plan).unwrap()
        try expect(portrait.frame.contains(x: left.midX, y: left.midY))
        try expect(landscape.frame.contains(x: right.midX, y: right.midY))
        // Asking the wide monitor for workspace 1, which the vertical one shows, swaps them.
        state.select(workspace: 1, in: "browser", on: landscape, displays: desk)
        plan = state.plan(displays: desk, live: live(state))
        let swappedLeft = try frame(zen2, plan).unwrap(), swappedRight = try frame(zen1, plan).unwrap()
        try expect(portrait.frame.contains(x: swappedLeft.midX, y: swappedLeft.midY))
        try expect(landscape.frame.contains(x: swappedRight.midX, y: swappedRight.midY))
    }),
    ("A second copy of a category starts on a workspace that has a window", {
        var (state, _, _, _, _) = deskState()
        state.select(workspace: 2, in: "browser", displays: desk)
        state.add("browser", to: landscape, displays: desk)
        try expect(state.workspace(of: "browser", on: landscape, displays: desk) == 1)
    }),
    ("A monitor can be cleared, and the categories stay off until brought back", {
        var (state, _, _, _, _) = deskState()
        state.remove("notes", from: laptop, displays: desk)
        state.remove("media", from: laptop, displays: desk)
        state.ensureProfile(displays: desk)
        try expect(state.profile(for: desk)?.screens["laptop"]?.categories == [])
        try expect(state.isUnplaced("notes", displays: desk) && state.hosts(of: "notes", displays: desk).isEmpty)
        let notes = WindowRecord(appID: "com.apple.Notes", title: "Notes", category: "notes")
        state.windows.append(notes)
        try expect(hidden(notes.id, state.plan(displays: desk, live: live(state))))
        state.add("notes", to: laptop, displays: desk)
        try expect(!state.isUnplaced("notes", displays: desk))
        try expect(!hidden(notes.id, state.plan(displays: desk, live: live(state))))
    }),
    ("Each monitor's copy of a category gets its own key", {
        var (state, _, _, _, _) = deskState()
        state.add("browser", to: landscape, displays: desk)
        let keys = Dictionary(uniqueKeysWithValues: state.areas(displays: desk).map { ("\($0.display)|\($0.category)", $0.letter) })
        try expect(keys["portrait|browser"] == "b" && keys["landscape|browser"] == "r")
        try expect(keys["portrait|comms"] == "c" && keys["landscape|agents"] == "a" && keys["laptop|notes"] == "n")
        try expect(Set(keys.values).count == keys.count)
    }),
    ("Taking a category off one monitor leaves the other as it was", {
        var (state, _, zen1, zen2, _) = deskState()
        state.add("browser", to: landscape, displays: desk)
        state.remove("browser", from: portrait, displays: desk)
        let plan = state.plan(displays: desk, live: live(state))
        let wide = try frame(zen2, plan).unwrap()
        try expect(landscape.frame.contains(x: wide.midX, y: wide.midY) && hidden(zen1, plan))
        state.remove("browser", from: landscape, displays: desk)
        try expect(state.hosts(of: "browser", displays: desk).isEmpty && state.isUnplaced("browser", displays: desk))
    }),
    ("Focusing a hidden window on a shared category shows it where you are", {
        var (state, _, zen1, zen2, _) = deskState()
        state.add("browser", to: landscape, displays: desk)
        let zen3 = WindowRecord(appID: "app.zen-browser.zen", title: "Three", category: "browser", workspace: 3)
        state.windows.append(zen3)
        state.follow(zen3.id, displays: desk, preferred: landscape)
        let plan = state.plan(displays: desk, live: live(state))
        let shown = try frame(zen3.id, plan).unwrap()
        try expect(landscape.frame.contains(x: shown.midX, y: shown.midY))
        try expect(!hidden(zen1, plan) && hidden(zen2, plan))
    }),
    ("A window opened from elsewhere takes over the area you're in, and can go back", {
        var (state, slack, _, zen2, _) = deskState()
        // Working in Comms; a link opens Browser workspace 2, which isn't showing.
        state.summon(zen2, into: portrait, replacing: "comms")
        var plan = state.plan(displays: desk, live: live(state))
        let took = try frame(zen2, plan).unwrap()
        try expect(hidden(slack, plan) && took.y < portrait.frame.midY)
        try expect(state.focusedCategory == "browser")
        state.restore("comms", on: portrait)
        plan = state.plan(displays: desk, live: live(state))
        try expect(!hidden(slack, plan) && hidden(zen2, plan))
    }),
    ("Picking a workspace for an area ends its takeover", {
        var (state, slack, _, zen2, _) = deskState()
        state.summon(zen2, into: portrait, replacing: "comms")
        state.select(workspace: 1, in: "comms", on: portrait, displays: desk)
        try expect(state.overrides.isEmpty)
        try expect(!hidden(slack, state.plan(displays: desk, live: live(state))))
        state.summon(zen2, into: portrait, replacing: "comms")
        state.pruneOverrides(live: Set([slack]), displays: desk)
        try expect(state.overrides.isEmpty)
    }),
    ("Closing a window moves its area to the nearest workspace that still has one", {
        var (state, slack, zen1, zen2, rex) = deskState()
        state.select(workspace: 2, in: "browser", displays: desk)
        state.fallBack(from: "browser", workspace: 2, visible: [slack, zen1, rex], displays: desk)
        try expect(state.workspace(of: "browser") == 1)
        // Nothing left in Comms: the area gives its space to Browser.
        state.fallBack(from: "comms", workspace: 1, visible: [zen1, rex], displays: desk)
        var shown = state
        shown.windows.removeAll { $0.id == slack || $0.id == zen2 }
        let plan = shown.plan(displays: desk, live: live(shown))
        try expect(try frame(zen1, plan).unwrap().height > portrait.frame.height * 0.9)
    }),
    ("Dropping a window on an occupied workspace swaps the two", {
        var (state, slack, zen1, zen2, _) = deskState()
        let all = Set(state.windows.map(\.id))
        state.exchange(zen1, category: "browser", workspace: 2, live: all)
        try expect(state.record(zen1)?.workspace == 2 && state.record(zen2)?.workspace == 1)
        // Across categories, the other window takes the old category and workspace.
        state.exchange(slack, category: "browser", workspace: 2, live: all)
        try expect(state.record(slack)?.category == "browser" && state.record(slack)?.workspace == 2)
        try expect(state.record(zen1)?.category == "comms" && state.record(zen1)?.workspace == 1)
    }),
    ("Windows that land in the same workspace by accident get their own", {
        var (state, _, zen1, zen2, _) = deskState()
        let all = Set(state.windows.map(\.id))
        state.windows[state.windows.firstIndex { $0.id == zen2 }!].workspace = 1
        state.separate(live: all)
        try expect(state.record(zen1)?.workspace == 1 && state.record(zen2)?.workspace == 2)
        // Putting one there on purpose keeps them together.
        state.move(window: zen2, toWorkspace: 1, live: all)
        state.separate(live: all)
        try expect(state.record(zen2)?.workspace == 1 && state.record(zen2)?.together == true)
    }),
    ("Picking a workspace changes only that category", {
        var (state, slack, zen1, zen2, _) = deskState()
        state.select(workspace: 2, in: "browser", displays: desk)
        state.select(workspace: 1, in: "browser", displays: desk)
        let plan = state.plan(displays: desk, live: live(state))
        try expect(!hidden(slack, plan) && !hidden(zen1, plan) && hidden(zen2, plan))
        try expect(state.workspace(of: "comms") == 1 && state.focusedCategory == "browser")
    }),
    ("A new window takes its category's next empty workspace", {
        let (state, _, _, _, _) = deskState()
        try expect(state.freeWorkspace(in: "browser", live: Set(state.windows.map(\.id))) == 3)
        try expect(state.freeWorkspace(in: "notes", live: Set(state.windows.map(\.id))) == 1)
        try expect(state.home(for: "com.tinyspeck.slackmacgap") == "comms")
    }),
    ("Focusing a window brings its workspace forward", {
        var (state, _, _, zen2, _) = deskState()
        state.follow(zen2, displays: desk)
        try expect(state.workspace(of: "browser") == 2 && state.focusedCategory == "browser")
    }),
    ("Putting a category on a screen takes it off the others", {
        var (state, _, _, _, _) = deskState()
        state.place("notes", on: portrait, displays: desk)
        let profile = state.profile(for: desk)!
        try expect(profile.screens["portrait"]?.categories == ["comms", "browser", "notes"])
        try expect(profile.screens["laptop"]?.categories == ["media"])
    }),
    ("Dropping a category before another reorders a monitor", {
        var (state, _, _, _, _) = deskState()
        state.place("browser", on: portrait, before: "comms", displays: desk)
        try expect(state.profile(for: desk)?.screens["portrait"]?.categories == ["browser", "comms"])
        state.place("notes", on: portrait, before: "comms", displays: desk)
        try expect(state.profile(for: desk)?.screens["portrait"]?.categories == ["browser", "notes", "comms"])
        try expect(state.profile(for: desk)?.screens["laptop"]?.categories == ["media"])
    }),
    ("Each monitor setup keeps its own profile", {
        var (state, slack, _, _, _) = deskState()
        state.ensureProfile(displays: [laptop])
        let alone = state.profile(for: [laptop])!
        try expect(alone.screens["laptop"]?.categories.count == state.categories.filter { !$0.overlay }.count)
        try expect(alone.screens["laptop"]?.split == false)
        state.focus("comms", displays: [laptop])
        let plan = state.plan(displays: [laptop], live: live(state))
        try expect(plan.filter { !$0.hidden }.map(\.id) == [slack])
        state.ensureProfile(displays: desk)
        try expect(state.profile(for: desk)?.screens["portrait"]?.categories == ["comms", "browser"])
    }),
    ("Switching a screen to one at a time shows the focused category", {
        var (state, slack, _, zen2, _) = deskState()
        state.toggleSplit(on: portrait, displays: desk)
        state.select(workspace: 2, in: "browser", displays: desk)
        var plan = state.plan(displays: desk, live: live(state))
        try expect(!hidden(zen2, plan) && hidden(slack, plan))
        let full = try frame(zen2, plan).unwrap()
        try expect(full.height > portrait.frame.height * 0.9)
        state.focus("comms", displays: desk)
        plan = state.plan(displays: desk, live: live(state))
        try expect(!hidden(slack, plan) && hidden(zen2, plan))
    }),
    ("Moving a window teaches Spacey where its app belongs", {
        var (state, _, zen1, _, _) = deskState()
        state.move(window: zen1, to: "notes")
        try expect(state.home(for: "app.zen-browser.zen") == "notes")
        try expect(!state.category("browser")!.apps.contains("app.zen-browser.zen"))
    }),
    ("Swapping exchanges places across areas", {
        var (state, slack, zen1, _, _) = deskState()
        state.swap(slack, zen1)
        try expect(state.record(slack)?.category == "browser" && state.record(zen1)?.category == "comms")
    }),
    ("Apple Intelligence's categories re-sort windows and keep the screens", {
        var (state, slack, _, _, rex) = deskState()
        var proposal = DesktopState()
        proposal.categories = []
        proposal.addCategory(named: "Work", apps: ["com.superlogical.rex", "com.tinyspeck.slackmacgap"])
        proposal.addCategory(named: "Web", apps: ["app.zen-browser.zen"])
        state.adopt(proposal.categories, displays: desk)
        try expect(state.record(slack)?.category == "work" && state.record(rex)?.category == "work")
        let placed = state.profile(for: desk)!.screens.values.flatMap(\.categories).sorted()
        try expect(placed == ["web", "work"])
    }),
    ("Deleting a category keeps its windows", {
        var (state, slack, _, _, _) = deskState()
        state.removeCategory("comms", displays: desk)
        try expect(state.category("comms") == nil && state.record(slack)?.category == "agents")
        try expect(!state.profile(for: desk)!.screens.values.flatMap(\.categories).contains("comms"))
    }),
    ("Category letters avoid the ones Spacey uses", {
        var state = DesktopState()
        let added = state.addCategory(named: "Focus")
        // F is taken by Focus mode and O by Others.
        try expect(added?.letter == "c" || added?.letter == "u")
        try expect(state.addCategory(named: "Focus") == nil)
    }),
    ("Focus shows only the focused window, full screen", {
        var (state, _, _, _, rex) = deskState()
        state.solo = true
        state.focusedWindow = rex
        let plan = state.plan(displays: desk, live: live(state))
        try expect(plan.filter { !$0.hidden }.map(\.id) == [rex])
        try expect(try frame(rex, plan).unwrap().width > landscape.frame.width * 0.9)
    }),
    ("User-minimized windows stay minimized", {
        var (state, slack, _, _, _) = deskState()
        try expect(hidden(slack, state.plan(displays: desk, live: live(state, minimized: [slack]))))
        state.minimizedByManager.insert(slack)
        try expect(!hidden(slack, state.plan(displays: desk, live: live(state, minimized: [slack]))))
    }),
    ("State survives restart", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("desktop.json"))
        var (state, _, _, _, _) = deskState()
        state.select(workspace: 2, in: "browser", displays: desk)
        try store.save(state)
        try expect(try store.load() == state)
    }),
    ("An older state file starts fresh instead of failing", {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"schemaVersion":2,"windows":[],"mode":3}"#.utf8).write(to: file)
        try expect(try StateStore(url: file).load() == DesktopState())
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

extension Optional {
    func unwrap(_ message: String = #function) throws -> Wrapped {
        guard let self else { throw CheckFailure(message: "nil: \(message)") }
        return self
    }
}

let all = checks + navigationChecks() + rexChecks() + parkingChecks() + profileChecks() + othersChecks()
var failures = 0
for (name, run) in all {
    do { try run(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
if failures > 0 { exit(1) }
print("\(all.count) checks passed")
