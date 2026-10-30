import AppKit
import Observation
import SwiftUI
import WorkspaceCore

// The setup window (Option-Comma, or the grid button in the bar): screens and what's on them,
// categories and the windows in each workspace, and every shortcut.
@MainActor
final class Setup {
    struct Screen: Identifiable, Equatable {
        var id: String
        var name: String
        var frame: Frame
        var split: Bool
        var categories: [String]
    }

    struct Window: Identifiable, Equatable {
        var id: UUID
        var app: String
        var title: String
        var icon: NSImage?
        var category: String
        var workspace: Int
    }

    @MainActor @Observable
    final class Model {
        var tab = 0
        var profile = ""
        var screens: [Screen] = []
        var categories: [WorkspaceCore.Category] = []
        var workspaces: [String: Int] = [:]
        var windows: [Window] = []
        var intelligence = ""
        var intelligenceAvailable = false
        var error: String?
    }

    struct Actions {
        var place: (String, String) -> Void = { _, _ in }
        var split: (String, Bool) -> Void = { _, _ in }
        var move: (UUID, String, Int) -> Void = { _, _, _ in }
        var raise: (UUID) -> Void = { _ in }
        var showWorkspace: (String, Int) -> Void = { _, _ in }
        var rename: (String, String) -> Void = { _, _ in }
        var add: (String) -> Void = { _ in }
        var remove: (String) -> Void = { _ in }
        var renameProfile: (String) -> Void = { _ in }
        var regroup: () -> Void = {}
    }

    let model = Model()
    var actions = Actions()
    private var window: NSWindow?

    var isOpen: Bool { window?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Spacey"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: SetupView(model: model, actions: { [weak self] in self?.actions ?? Actions() })
            .environment(\.colorScheme, .dark))
        return window
    }
}

struct SetupView: View {
    var model: Setup.Model
    var actions: () -> Setup.Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle").foregroundStyle(Color(hex: "#FFC93C")).font(.system(size: 15, weight: .bold))
                Text("Spacey").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    Text("Screens").tag(0)
                    Text("Categories").tag(1)
                    Text("Shortcuts").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
                Text("⌥,").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            Group {
                switch model.tab {
                case 0: ScreensTab(model: model, actions: actions())
                case 1: CategoriesTab(model: model, actions: actions())
                default: ShortcutsTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.bottom, 10)
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }
}

// MARK: Screens

struct ScreensTab: View {
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var profileName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("Profile").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("Name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { actions.renameProfile(profileName) }
                    Text("Saved for this set of monitors. Spacey switches profiles when monitors connect or disconnect.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                .onAppear { profileName = model.profile }
                .onChange(of: model.profile) { profileName = model.profile }

                Arrangement(model: model)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)

                ForEach(model.screens) { screen in screenRow(screen) }
            }
            .padding(22)
        }
    }

    func screenRow(_ screen: Setup.Screen) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name).font(.system(size: 13, weight: .semibold))
                Text(screen.frame.height > screen.frame.width ? "Vertical" : "Horizontal")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(screen.categories, id: \.self) { id in
                    if let category = model.categories.first(where: { $0.id == id }) {
                        HStack(spacing: 2) {
                            CategoryLabel(category: category)
                            Menu {
                                ForEach(model.screens.filter { $0.id != screen.id }) { other in
                                    Button("Move to \(other.name)") { actions.place(id, other.id) }
                                }
                            } label: {
                                Image(systemName: "arrow.left.arrow.right")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Move \(category.name) to another monitor")
                        }
                    }
                }
                let missing = model.categories.filter { !screen.categories.contains($0.id) }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing) { category in
                            Button("\(category.name)") { actions.place(category.id, screen.id) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Put another category on this monitor")
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { screen.split }, set: { actions.split(screen.id, $0) })) {
                Text("Side by side").tag(true)
                Text("One at a time").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(12)
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 10))
    }
}

struct CategoryLabel: View {
    var category: WorkspaceCore.Category

    var body: some View {
        HStack(spacing: 5) {
            Text(category.letter.uppercased())
                .font(.system(size: 10, weight: .heavy).monospaced())
                .frame(width: 16, height: 16)
                .background(Color(hex: category.color), in: .rect(cornerRadius: 4))
            Text(category.name).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: category.color).opacity(0.18), in: .capsule)
    }
}

// The monitors drawn to scale, in their real positions, each split the way Spacey tiles it.
struct Arrangement: View {
    var model: Setup.Model

    var body: some View {
        GeometryReader { geometry in
            let frames = model.screens.map(\.frame)
            let minX = frames.map(\.x).min() ?? 0, minY = frames.map(\.y).min() ?? 0
            let maxX = frames.map { $0.x + $0.width }.max() ?? 1, maxY = frames.map { $0.y + $0.height }.max() ?? 1
            let scale = min(geometry.size.width / max(1, maxX - minX), geometry.size.height / max(1, maxY - minY)) * 0.96
            let offsetX = (geometry.size.width - (maxX - minX) * scale) / 2
            let offsetY = (geometry.size.height - (maxY - minY) * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(model.screens) { screen in
                    monitor(screen)
                        .frame(width: screen.frame.width * scale - 6, height: screen.frame.height * scale - 6)
                        .offset(x: offsetX + (screen.frame.x - minX) * scale + 3, y: offsetY + (screen.frame.y - minY) * scale + 3)
                }
            }
        }
    }

    func monitor(_ screen: Setup.Screen) -> some View {
        let vertical = screen.frame.height > screen.frame.width
        let shown = screen.split ? screen.categories : Array(screen.categories.prefix(1))
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return VStack(alignment: .leading, spacing: 4) {
            Text(screen.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            layout {
                ForEach(shown, id: \.self) { id in
                    if let category = model.categories.first(where: { $0.id == id }) {
                        let workspace = model.workspaces[id] ?? 1
                        let windows = model.windows.filter { $0.category == id && $0.workspace == workspace }
                        VStack(spacing: 3) {
                            Image(systemName: category.icon).font(.system(size: 13, weight: .semibold))
                            Text(category.name).font(.system(size: 11, weight: .semibold))
                            Text(windows.isEmpty ? "Empty" : "\(windows.first!.app) · \(workspace)")
                                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: category.color).opacity(0.28), in: .rect(cornerRadius: 6))
                    }
                }
                if shown.isEmpty {
                    Text("Nothing here").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !screen.split && screen.categories.count > 1 {
                Text("+ \(screen.categories.count - 1) taking turns").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: Categories

struct CategoriesTab: View {
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("New category", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button {
                        actions.regroup()
                    } label: {
                        Label("Regroup with Apple Intelligence", systemImage: "apple.intelligence")
                    }
                    .disabled(!model.intelligenceAvailable)
                    .help(model.intelligence)
                }
                if !model.intelligenceAvailable {
                    Text("Apple Intelligence: \(model.intelligence). Built-in app knowledge sorts new windows until then.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                ForEach(model.categories) { category in CategoryCard(category: category, model: model, actions: actions) }
            }
            .padding(22)
        }
    }

    func add() {
        actions.add(newName)
        newName = ""
    }
}

struct CategoryCard: View {
    var category: WorkspaceCore.Category
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var name = ""

    var body: some View {
        let windows = model.windows.filter { $0.category == category.id }
        let current = model.workspaces[category.id] ?? 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(category.letter.uppercased())
                    .font(.system(size: 12, weight: .heavy).monospaced())
                    .frame(width: 22, height: 22)
                    .background(Color(hex: category.color), in: .rect(cornerRadius: 6))
                Image(systemName: category.icon).foregroundStyle(Color(hex: category.color))
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 180)
                    .onSubmit { actions.rename(category.id, name) }
                Text("⌥\(category.letter.uppercased()) then 1–9").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(windows.count) window\(windows.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(.secondary)
                if model.categories.count > 1 {
                    Button(role: .destructive) { actions.remove(category.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete \(category.name). Its windows move to \(model.categories.first { $0.id != category.id }?.name ?? "another category").")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(1...9, id: \.self) { number in
                    slot(number, windows: windows.filter { $0.workspace == number }, current: number == current)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 12))
        .onAppear { name = category.name }
        .onChange(of: category.name) { name = category.name }
    }

    func slot(_ number: Int, windows: [Setup.Window], current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { actions.showWorkspace(category.id, number) } label: {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .frame(width: 18, height: 18)
                    .background(current ? AnyShapeStyle(Color(hex: category.color)) : AnyShapeStyle(.white.opacity(0.08)), in: .rect(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Show workspace \(number)")
            if windows.isEmpty {
                Text("Empty").font(.system(size: 11)).foregroundStyle(.quaternary)
            }
            ForEach(windows) { window in windowChip(window) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(.white.opacity(current ? 0.06 : 0.025), in: .rect(cornerRadius: 8))
    }

    // Click to bring the window forward; the menu moves it anywhere. A workspace can hold several.
    func windowChip(_ window: Setup.Window) -> some View {
        HStack(spacing: 5) {
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
            Button { actions.raise(window.id) } label: {
                Text(window.title.isEmpty ? window.app : window.title)
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            Menu {
                ForEach(model.categories) { target in
                    Menu(target.name) {
                        ForEach(1...9, id: \.self) { number in
                            let taken = model.windows.filter { $0.category == target.id && $0.workspace == number && $0.id != window.id }
                            Button("Workspace \(number)" + (taken.isEmpty ? "" : " — with \(taken[0].app)")) {
                                actions.move(window.id, target.id, number)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to another category or workspace")
        }
    }
}

// MARK: Shortcuts

struct ShortcutsTab: View {
    var model: Setup.Model

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    section("Categories", model.categories.map { ("⌥\($0.letter.uppercased())", "\($0.name), then 1–9 for its workspace") })
                    section("Workspaces", [
                        ("⌥1 … ⌥9", "Workspace of the focused category"),
                        ("⌥⇧1 … ⌥⇧9", "Move the window to a workspace"),
                        ("⌥⇧ letter", "Move the window to a category"),
                        ("⌥Tab", "Next workspace with a window"),
                        ("⌥Space", "Back to where you were"),
                    ])
                    section("Monitors", [
                        ("⌥⌃ letter", "Put a category on this monitor"),
                        ("⌥⌃S", "Side by side, or one category at a time"),
                    ])
                }
                VStack(alignment: .leading, spacing: 14) {
                    section("Windows", [
                        ("⌥H ⌥J ⌥K ⌥L", "Focus left, down, up, right"),
                        ("⌥⇧H … ⌥⇧L", "Swap with the window there"),
                        ("⌥F", "Show only this window"),
                        ("⌥S / ⌥⇧S", "Stack / side by side"),
                        ("⌥Q / ⌥⇧Q", "Close window / quit app"),
                    ])
                    section("Rex and Spacey", [
                        ("⌥`", "Rex inbox"),
                        ("⌥⇧`", "Jump to what needs you"),
                        ("⌥,", "This window"),
                        ("⌥⌃Esc", "Pause and put windows back"),
                    ])
                }
            }
            .padding(22)
        }
    }

    func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 5))
                        .frame(width: 130, alignment: .leading)
                    Text(row.1).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 400, alignment: .leading)
    }
}
