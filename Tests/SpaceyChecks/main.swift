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
    ("Taking a category off one monitor leaves the other as it was", {
        var (state, _, zen1, zen2, _) = deskState()
        state.add("browser", to: landscape, displays: desk)
        state.remove("browser", from: portrait, displays: desk)
        let plan = state.plan(displays: desk, live: live(state))
        let wide = try frame(zen2, plan).unwrap()
        try expect(landscape.frame.contains(x: wide.midX, y: wide.midY) && hidden(zen1, plan))
        state.remove("browser", from: landscape, displays: desk)
        try expect(state.hosts(of: "browser", displays: desk).map(\.id) == ["landscape"])
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
    ("Each monitor setup keeps its own profile", {
        var (state, slack, _, _, _) = deskState()
        state.ensureProfile(displays: [laptop])
        let alone = state.profile(for: [laptop])!
        try expect(alone.screens["laptop"]?.categories.count == state.categories.count)
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
        try expect(added?.letter == "o")
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

let all = checks + navigationChecks() + rexChecks() + parkingChecks()
var failures = 0
for (name, run) in all {
    do { try run(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
if failures > 0 { exit(1) }
print("\(all.count) checks passed")
