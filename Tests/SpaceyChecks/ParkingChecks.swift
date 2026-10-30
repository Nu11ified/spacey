import Foundation
import WorkspaceCore

func parkingChecks() -> [(String, () throws -> Void)] { [
    ("Parked windows never spill onto a neighbour", {
        let left = Display(id: "left", name: "L", frame: Frame(x: 0, y: 0, width: 1512, height: 982))
        let right = Display(id: "right", name: "R", frame: Frame(x: 1512, y: 0, width: 1920, height: 1080))
        let window = Frame(x: 100, y: 100, width: 800, height: 600)
        let parked = DesktopState.parkingFrame(for: window, on: left, among: [left, right])
        try expect(parked.x + parked.width <= 1512 + 1 || parked.y >= 982 - 1)
        try expect(parked.x < 0 || parked.y >= 981)
        let alone = DesktopState.parkingFrame(for: window, on: right, among: [left, right])
        try expect(alone.x == 1512 + 1920 - 1)
    }),
] }
