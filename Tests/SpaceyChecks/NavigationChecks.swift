import Foundation
import WorkspaceCore

func navigationChecks() -> [(String, () throws -> Void)] { [
    ("Focus moves to the window in that direction, across screens", {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let left = Frame(x: 0, y: 0, width: 700, height: 900)
        let right = Frame(x: 720, y: 0, width: 700, height: 900)
        let above = Frame(x: 0, y: -1080, width: 1920, height: 1080)
        let windows = [(a, left), (b, right), (c, above)]
        try expect(DesktopState.neighbour(of: left, in: .right, among: windows) == b)
        try expect(DesktopState.neighbour(of: right, in: .left, among: windows) == a)
        try expect(DesktopState.neighbour(of: left, in: .up, among: windows) == c)
        try expect(DesktopState.neighbour(of: left, in: .left, among: windows) == nil)
    }),
    ("Swapping exchanges tiling order and screens", {
        var (state, live) = deskState()
        let (rex, code) = (state.windows[0].id, state.windows[1].id)
        state.swap(rex, code, displays: desk)
        let plan = state.plan(displays: desk, live: live)
        try expect(screen(of: rex, in: plan, displays: desk) == "landscape")
        try expect(screen(of: code, in: plan, displays: desk) == "portrait")
    }),
    ("Config rules move windows unless they were moved by hand", {
        var state = DesktopState()
        state.windows = [WindowRecord(appID: "com.tinyspeck.slackmacgap", title: "a", mode: 1),
                         WindowRecord(appID: "com.tinyspeck.slackmacgap", title: "b", mode: 1),
                         WindowRecord(appID: "net.imput.helium", title: "c", mode: 4)]
        state.assign(window: state.windows[1].id, to: 5)
        let rules = SpaceyConfig(modes: SpaceyConfig.standard.modes.enumerated().map { index, mode in
            var mode = mode
            if index == 2 { mode.apps = ["com.tinyspeck.slackmacgap"] }
            return mode
        })
        state.applyRules(rules)
        try expect(state.windows.map(\.mode) == [3, 5, 4])
    }),
    ("Launch keys can be replaced in config", {
        let config = try JSONDecoder().decode(SpaceyConfig.self, from: Data(#"{"launch": {"t": "com.mitchellh.ghostty"}}"#.utf8))
        try expect(config.launch == ["t": "com.mitchellh.ghostty"])
        try expect(SpaceyConfig.standard.launch["return"] == "com.mitchellh.ghostty")
    }),
] }
