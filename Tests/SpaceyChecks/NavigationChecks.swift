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
    ("A partial config keeps the defaults", {
        let partial = try JSONDecoder().decode(SpaceyConfig.self, from: Data(#"{"gap": 14}"#.utf8))
        try expect(partial.gap == 14 && partial.dock && partial.categories == nil)
    }),
] }
