import Foundation
import WorkspaceCore

func profileChecks() -> [(String, () throws -> Void)] { [
    ("The laptop alone, the work desk and a new desk each get their own profile", {
        var (state, _, _, _, _) = deskState()
        state.ensureProfile(displays: desk)
        state.profiles[DesktopState.topologyKey(desk)]?.name = "Work desk"
        let builtIn = Display(id: "laptop", name: "Built-in Retina Display", frame: laptop.frame)
        state.ensureProfile(displays: [builtIn])
        try expect(state.profile(for: [builtIn])?.name == "Laptop")
        // A home desk with one wide monitor shares nothing with the work desk.
        let home = Display(id: "home", name: "LG UltraFine", frame: Frame(x: 0, y: -1440, width: 2560, height: 1440))
        state.ensureProfile(displays: [laptop, home])
        try expect(state.profile(for: [laptop, home])?.name == "Desk")
        try expect(state.profile(for: desk)?.name == "Work desk")
        try expect(state.profiles.count == 3)
    }),
    ("A desk with the same kind of monitors starts from the matching profile", {
        var (state, _, _, _, _) = deskState()
        state.ensureProfile(displays: desk)
        state.profiles[DesktopState.topologyKey(desk)]?.name = "Work desk"
        // Same models in the same places, different units: a hot desk at the office.
        let other = [laptop,
                     Display(id: "portrait2", name: "External", frame: portrait.frame),
                     Display(id: "landscape2", name: "External", frame: landscape.frame)]
        state.ensureProfile(displays: other)
        let copy = try state.profile(for: other).unwrap()
        try expect(copy.name == "Work desk 2")
        try expect(copy.screens["portrait2"]?.categories == ["comms", "browser"])
        try expect(copy.screens["landscape2"]?.categories == ["agents"])
    }),
    ("Copying a profile moves its arrangement onto these monitors, and old profiles can be deleted", {
        var (state, _, _, _, _) = deskState()
        state.ensureProfile(displays: desk)
        let home = Display(id: "home", name: "LG UltraFine", frame: Frame(x: 1512, y: 0, width: 1080, height: 1920))
        state.ensureProfile(displays: [laptop, home])
        state.profiles[DesktopState.topologyKey([laptop, home])]?.name = "Home"
        state.copyProfile(DesktopState.topologyKey(desk), displays: [laptop, home])
        let copied = try state.profile(for: [laptop, home]).unwrap()
        try expect(copied.name == "Home")
        // The vertical home monitor takes the vertical work monitor's categories.
        try expect(Array(copied.screens["home"]?.categories.prefix(2) ?? []) == ["comms", "browser"])
        state.deleteProfile(DesktopState.topologyKey([laptop, home]), displays: [laptop, home])
        try expect(state.profile(for: [laptop, home]) != nil)
        state.deleteProfile(DesktopState.topologyKey(desk), displays: [laptop, home])
        try expect(state.profile(for: desk) == nil)
    }),
] }
