import Foundation
import WorkspaceCore

let laptop = Display(id: "laptop", name: "MacBook", frame: Frame(x: 0, y: 0, width: 1512, height: 982))
let portrait = Display(id: "portrait", name: "External", frame: Frame(x: -1080, y: -1080, width: 1080, height: 1920))
let landscape = Display(id: "landscape", name: "External", frame: Frame(x: 0, y: -1080, width: 1920, height: 1080))

struct CheckFailure: Error { var message: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = #function) throws {
    if try !condition() { throw CheckFailure(message: message) }
}
func populated() -> DesktopState {
    var state = DesktopState()
    state.windows = (1...9).map { WindowRecord(appID: "test", title: "Window \($0)", workspace: $0) }
    return state
}

let checks: [(String, () throws -> Void)] = [
    ("Cable transitions never merge windows", {
        var state = populated()
        let memberships = state.windows
        for screens in [[portrait, landscape, laptop], [laptop], [portrait, laptop],
                        [landscape, laptop], [portrait, landscape, laptop], [], [laptop]] {
            state.reconcile(displays: screens)
            try expect(state.windows == memberships)
        }
        try expect(state.topologyProfiles[DesktopState.topologyKey([portrait, laptop])]?.values.filter { $0 == portrait.id }.count == 5)
    }),
    ("Portrait and landscape frames do not overlap", {
        var state = DesktopState()
        state.windows = (0..<2).map { WindowRecord(appID: "test", title: "\($0)", workspace: 1) }
        let live = state.windows.map { LiveWindow(id: $0.id, frame: laptop.frame) }
        state.reconcile(displays: [portrait])
        let vertical = state.plan(displays: [portrait], live: live).compactMap(\.frame)
        try expect(vertical.count == 2)
        try expect(vertical[0].x == vertical[1].x)
        try expect(vertical[0].y + vertical[0].height < vertical[1].y)
        state.reconcile(displays: [landscape])
        let horizontal = state.plan(displays: [landscape], live: live).compactMap(\.frame)
        try expect(horizontal[0].y == horizontal[1].y)
        try expect(horizontal[0].x + horizontal[0].width < horizontal[1].x)
    }),
    ("Dock profile restores after laptop fallback", {
        var state = populated()
        state.reconcile(displays: [portrait, landscape, laptop])
        state.select(3, displays: [portrait, landscape, laptop])
        let saved = state.topologyProfiles
        state.reconcile(displays: [laptop])
        state.reconcile(displays: [laptop, portrait, landscape])
        let key = DesktopState.topologyKey([portrait, landscape, laptop])
        try expect(state.topologyProfiles[key] == saved[key])
        try expect(state.activeByDisplay[portrait.id] == 3)
    }),
    ("Manual layout survives reconnect", {
        var state = populated()
        state.reconcile(displays: [portrait])
        state.setLayout(.horizontal, displays: [portrait])
        state.reconcile(displays: [laptop])
        state.reconcile(displays: [portrait])
        try expect(state.layoutOverrides[portrait.id]?[1] == .horizontal)
    }),
    ("Each screen restores its selected workspace", {
        var state = populated()
        let dock = [portrait, landscape, laptop]
        state.reconcile(displays: dock)
        state.select(9, displays: dock)
        state.select(6, displays: dock)
        state.select(3, displays: dock)
        state.reconcile(displays: [laptop])
        state.reconcile(displays: dock)
        try expect(state.activeByDisplay[laptop.id] == 9)
        try expect(state.activeByDisplay[landscape.id] == 6)
        try expect(state.activeByDisplay[portrait.id] == 3)
    }),
    ("User-minimized windows are not restored", {
        var state = populated()
        state.reconcile(displays: [laptop])
        let window = state.windows[0]
        let live = [LiveWindow(id: window.id, frame: laptop.frame, minimized: true)]
        try expect(state.plan(displays: [laptop], live: live).allSatisfy { $0.hidden })
        state.minimizedByManager.insert(window.id)
        try expect(state.plan(displays: [laptop], live: live).first?.hidden == false)
    }),
    ("Focus mode preserves memberships", {
        var state = populated()
        let original = state.windows
        state.reconcile(displays: [portrait, landscape, laptop])
        state.mode = .workspace
        let live = state.windows.map { LiveWindow(id: $0.id, frame: laptop.frame) }
        try expect(state.plan(displays: [portrait, landscape, laptop], live: live).filter { !$0.hidden }.count == 1)
        try expect(state.windows == original)
    }),
    ("State survives restart", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("desktop.json"))
        var state = populated()
        state.reconcile(displays: [portrait, landscape, laptop])
        state.select(6, displays: [portrait, landscape, laptop])
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
    })
]

var failures = 0
for (name, run) in checks {
    do { try run(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
if failures > 0 { exit(1) }
print("\(checks.count) checks passed")
