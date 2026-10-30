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
        var unplaced: [String] = []
        var categories: [WorkspaceCore.Category] = []
        var workspaces: [String: Int] = [:]
        // "category|displayID" → the workspace that screen shows.
        var shown: [String: Int] = [:]
        var windows: [Window] = []
        var intelligence = ""
        var intelligenceAvailable = false
        var error: String?
    }

    struct Actions {
        var place: (String, String) -> Void = { _, _ in }
        // Category, monitor, and the category to land in front of.
        var placeBefore: (String, String, String?) -> Void = { _, _, _ in }
        // Window, category, monitor, and workspace (nil: the next empty one).
        var moveToArea: (UUID, String, String, Int?) -> Void = { _, _, _, _ in }
        var add: (String, String) -> Void = { _, _ in }
        var removeFromScreen: (String, String) -> Void = { _, _ in }
        var split: (String, Bool) -> Void = { _, _ in }
        var move: (UUID, String, Int) -> Void = { _, _, _ in }
        var raise: (UUID) -> Void = { _ in }
        var showWorkspace: (String, Int) -> Void = { _, _ in }
        var rename: (String, String) -> Void = { _, _ in }
        var addCategory: (String) -> Void = { _ in }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Spacey"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
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
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }
}

// MARK: Drag and drop

// What's being dragged: "category:<id>" or "window:<uuid>".
enum Payload {
    case category(String)
    case window(UUID)

    init?(_ text: String) {
        if text.hasPrefix("category:") { self = .category(String(text.dropFirst(9))) }
        else if text.hasPrefix("window:"), let id = UUID(uuidString: String(text.dropFirst(7))) { self = .window(id) }
        else { return nil }
    }
}

extension Setup.Actions {
    // A category dropped on a monitor moves there; holding Option adds it and keeps it where it was.
    func drop(_ items: [String], on screen: String, before: String? = nil) -> Bool {
        guard let item = items.first, case .category(let id)? = Payload(item) else { return false }
        if NSEvent.modifierFlags.contains(.option) && before == nil { add(id, screen) } else { placeBefore(id, screen, before) }
        return true
    }
}

// A soft highlight on whatever a drag is hovering over.
struct DropHighlight: ViewModifier {
    var active: Bool
    var color: Color = .accentColor
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(color, lineWidth: active ? 2 : 0))
            .background(color.opacity(active ? 0.12 : 0), in: .rect(cornerRadius: radius))
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

// MARK: Screens

struct ScreensTab: View {
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var profileName = ""
    @State private var targeted: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            WindowTray(model: model)
                .frame(width: 250)
            Divider().opacity(0.5)
            board
        }
    }

    var board: some View {
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

                Arrangement(model: model, actions: actions)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                Text("Drag a window from the left onto a category on a monitor, or onto one of its workspace numbers. Drag a category onto a monitor to move it there; hold Option to show it there too.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)

                ForEach(model.screens) { screen in screenRow(screen) }
                if !model.unplaced.isEmpty { unplacedRow }
            }
            .padding(22)
        }
    }

    // Categories on no monitor. Their windows are parked; Option-letter brings one to where you are.
    var unplacedRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not on a monitor").font(.system(size: 13, weight: .semibold))
                Text("Option-letter brings one to you").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            ForEach(model.unplaced, id: \.self) { id in
                if let category = model.categories.first(where: { $0.id == id }) {
                    HStack(spacing: 2) {
                        CategoryLabel(category: category)
                            .draggable("category:\(id)") { CategoryLabel(category: category) }
                        Menu {
                            ForEach(model.screens) { screen in Button("Add to \(screen.name)") { actions.add(id, screen.id) } }
                        } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.025), in: .rect(cornerRadius: 10))
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
                                .draggable("category:\(id)") { CategoryLabel(category: category) }
                                .dropDestination(for: String.self) { items, _ in actions.drop(items, on: screen.id, before: id) }
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
                            let others = model.screens.filter { $0.categories.contains(id) }.count > 1
                            Button { actions.removeFromScreen(id, screen.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help(others ? "Take \(category.name) off this monitor. It stays on the others."
                                             : "Take \(category.name) off this monitor. Its windows wait until you add it back or press Option-\(category.letter.uppercased()).")
                        }
                    }
                }
                let missing = model.categories.filter { !screen.categories.contains($0.id) }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing) { category in
                            let elsewhere = model.screens.filter { $0.categories.contains(category.id) }.map(\.name)
                            Button(elsewhere.isEmpty ? category.name : "\(category.name) — also on \(elsewhere.joined(separator: ", "))") {
                                actions.add(category.id, screen.id)
                            }
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
        .modifier(DropHighlight(active: targeted == screen.id))
        .dropDestination(for: String.self) { items, _ in actions.drop(items, on: screen.id) } isTargeted: { on in
            targeted = on ? screen.id : (targeted == screen.id ? nil : targeted)
        }
    }
}

// Every window, grouped by category, ready to drag onto the board.
struct WindowTray: View {
    var model: Setup.Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("WINDOWS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(model.categories) { category in
                    let windows = model.windows.filter { $0.category == category.id }.sorted { $0.workspace < $1.workspace }
                    if !windows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            CategoryLabel(category: category)
                            ForEach(windows) { window in WindowRow(window: window, color: Color(hex: category.color)) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct WindowRow: View {
    var window: Setup.Window
    var color: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text("\(window.workspace)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .frame(width: 16, height: 16)
                .background(color.opacity(0.35), in: .rect(cornerRadius: 4))
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
            Text(window.title.isEmpty ? window.app : window.title)
                .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.white.opacity(hovering ? 0.08 : 0.03), in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
        .contentShape(.rect)
        .draggable("window:\(window.id.uuidString)") {
            HStack(spacing: 5) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(window.title.isEmpty ? window.app : window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.6), in: .capsule)
        }
        .help("Drag onto a category on a monitor")
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
            Text(category.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: category.color).opacity(0.18), in: .capsule)
    }
}

// The monitors drawn to scale, in their real positions, each split the way Spacey tiles it.
struct Arrangement: View {
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var targeted: String?
    @State private var targetedArea: String?
    @State private var targetedPill: String?

    // The workspaces that hold windows, plus a "+" for a new one. Drop a window on a number to put
    // it in that workspace.
    func pills(category: WorkspaceCore.Category, screen: String, current: Int) -> some View {
        let used = Set(model.windows.filter { $0.category == category.id }.map(\.workspace)).sorted()
        return HStack(spacing: 3) {
            ForEach(used + [0], id: \.self) { number in
                let key = "\(screen)|\(category.id)|\(number)"
                Text(number == 0 ? "+" : "\(number)")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .frame(width: 16, height: 16)
                    .background(number == current || targetedPill == key ? AnyShapeStyle(Color(hex: category.color)) : AnyShapeStyle(.white.opacity(0.12)),
                                in: .rect(cornerRadius: 4))
                    .scaleEffect(targetedPill == key ? 1.25 : 1)
                    .animation(.easeOut(duration: 0.12), value: targetedPill)
                    .dropDestination(for: String.self) { items, _ in
                        guard let item = items.first, case .window(let window)? = Payload(item) else { return false }
                        actions.moveToArea(window, category.id, screen, number == 0 ? nil : number)
                        return true
                    } isTargeted: { on in
                        targetedPill = on ? key : (targetedPill == key ? nil : targetedPill)
                    }
            }
        }
    }

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
                        let workspace = model.shown["\(id)|\(screen.id)"] ?? model.workspaces[id] ?? 1
                        let windows = model.windows.filter { $0.category == id && $0.workspace == workspace }
                        let area = "\(screen.id)|\(id)"
                        VStack(spacing: 3) {
                            Image(systemName: category.icon).font(.system(size: 13, weight: .semibold))
                            Text(category.name).font(.system(size: 11, weight: .semibold))
                            Text(windows.isEmpty ? "Empty" : "\(windows.first!.app) · \(workspace)")
                                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            pills(category: category, screen: screen.id, current: workspace)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: category.color).opacity(targetedArea == area ? 0.5 : 0.28), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: category.color), lineWidth: targetedArea == area ? 2 : 0))
                        .contentShape(.rect)
                        .draggable("category:\(id)") { CategoryLabel(category: category) }
                        // A window dropped on the area joins this category on this monitor, in a workspace of its own.
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first else { return false }
                            if case .window(let window)? = Payload(item) { actions.moveToArea(window, id, screen.id, nil); return true }
                            return actions.drop(items, on: screen.id, before: id)
                        } isTargeted: { on in
                            targetedArea = on ? area : (targetedArea == area ? nil : targetedArea)
                        }
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
        .modifier(DropHighlight(active: targeted == screen.id, radius: 9))
        .dropDestination(for: String.self) { items, _ in actions.drop(items, on: screen.id) } isTargeted: { on in
            targeted = on ? screen.id : (targeted == screen.id ? nil : targeted)
        }
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
                Text("Drag a window onto any workspace, in any category. Drop it on a workspace that has a window and they share it.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
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
        actions.addCategory(newName)
        newName = ""
    }
}

struct CategoryCard: View {
    var category: WorkspaceCore.Category
    var model: Setup.Model
    var actions: Setup.Actions
    @State private var name = ""
    @State private var targeted: Int?

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
        .modifier(DropHighlight(active: targeted == number, color: Color(hex: category.color), radius: 8))
        // Drop a window here to move it to this workspace; onto a window, they share it.
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, case .window(let id)? = Payload(item) else { return false }
            actions.move(id, category.id, number)
            return true
        } isTargeted: { on in
            targeted = on ? number : (targeted == number ? nil : targeted)
        }
    }

    // Click to bring the window forward; the menu moves it anywhere. A workspace can hold several.
    func windowChip(_ window: Setup.Window) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
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
        .contentShape(.rect)
        .draggable("window:\(window.id.uuidString)") {
            HStack(spacing: 5) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(window.title.isEmpty ? window.app : window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(hex: category.color).opacity(0.6), in: .capsule)
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
