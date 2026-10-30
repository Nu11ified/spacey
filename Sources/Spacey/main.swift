import AppKit
import Carbon
import SwiftUI
import IOKit.pwr_mgt
import WorkspaceCore

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    let store: StateStore
    let configURL: URL
    var config: SpaceyConfig
    var state: DesktopState
    var bindings: [UUID: MacDesktop.Window] = [:]
    var enabled = false
    var statusItem: NSStatusItem!
    var pending: DispatchWorkItem?
    var observers: [NSObjectProtocol] = []
    var axObservers: [pid_t: AXObserver] = [:]
    var hotKeys: [EventHotKeyRef] = []
    var alwaysHotKeys: [EventHotKeyRef] = []
    var chordKeys: [EventHotKeyRef] = []
    var chordCategory: String?
    var chordTimer: DispatchWorkItem?
    var hotKeyHandler: EventHandlerRef?
    var failedFrames: Set<UUID> = []
    var applied: [UUID: Frame] = [:]
    var lastError: String?
    var accessTimer: Timer?
    var awake: IOPMAssertionID?
    var previous: (category: String, workspace: Int)?
    var classifying: Set<UUID> = []
    // Windows on screen after the last pass, to tell a window coming from offscreen.
    var lastShown: Set<UUID> = []
    let rex = RexBridge()
    let overlays = Overlays()
    let dock = Dock()
    let bar = Bar()
    let setup = Setup()
    var menu = NSMenu()

    init(store: StateStore, configURL: URL) throws {
        self.store = store
        self.configURL = configURL
        self.state = try store.load()
        do { config = try SpaceyConfig.load(configURL) } catch {
            config = .standard
            lastError = "config.json is invalid; using defaults. \(error.localizedDescription)"
        }
        super.init()
        if let categories = config.categories { state.adopt(categories, displays: MacDesktop.displays()) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        dock.onSelect = { [weak self] in self?.focusCategory($0) }
        dock.onApp = { [weak self] in self?.open(app: $0) }
        dock.onAttention = { [weak self] in self?.jumpToMostUrgent() }
        bar.onCategory = { [weak self] in self?.focusCategory($0) }
        bar.onWorkspace = { [weak self] category, number, displayID in
            guard let self else { return }
            self.selectWorkspace(number, in: category, on: self.displays().first { $0.id == displayID })
        }
        bar.onMenu = { [weak self] view in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
        }
        bar.onRex = { [weak self] in
            guard let self else { return }
            if self.rex.board.attention.isEmpty { self.toggleInbox() } else { self.jumpToMostUrgent() }
        }
        bar.onAwake = { [weak self] in self?.toggleAwake() }
        bar.onRestore = { [weak self] category, displayID in self?.restore(category, onDisplay: displayID) }
        bar.onSetup = { [weak self] in self?.toggleSetup() }
        setup.actions = setupActions()
        startRex()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, RexBridge.appFrontmost else { return }
                self.rex.acknowledgeFocused()
                self.rexChanged(.updated)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failedFrames.removeAll()
                self?.applied.removeAll()
                self?.refresh()
                self?.schedule(delay: 0.8)
            }
        })
        refresh()
        start()
    }

    // MARK: Lifecycle

    // Starts managing as soon as it is allowed to, so a login launch needs no clicks.
    func start() {
        accessTimer?.invalidate()
        accessTimer = nil
        guard MacDesktop.trusted else {
            MacDesktop.requestAccess()
            retryStart()
            lastError = DesktopError.accessibility.localizedDescription
            refresh()
            return
        }
        // Two window managers moving the same windows fight forever. Wait for the other one to quit.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty {
            lastError = DesktopError.conflict.localizedDescription
            retryStart()
            refresh()
            return
        }
        do {
            try registerHotKeys()
            enabled = true
            lastError = nil
            reconcile()
        } catch { lastError = error.localizedDescription }
        refresh()
    }

    // Polling every two seconds is dull, but unlike notifications it can't be missed.
    func retryStart() {
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.enabled == false { self?.start() } }
        }
    }

    @objc func toggle() {
        if enabled { pause() } else { start() }
    }

    func pause() {
        enabled = false
        accessTimer?.invalidate()
        pending?.cancel()
        unregisterHotKeys()
        for id in Array(state.minimizedByManager) {
            if let window = bindings[id] {
                do { try MacDesktop.setMinimized(window, false); state.minimizedByManager.remove(id) }
                catch { lastError = error.localizedDescription }
            }
        }
        for (id, frame) in state.parkedByManager {
            guard let window = bindings[id] else { continue }
            MacDesktop.setPosition(window, frame)
            state.parkedByManager[id] = nil
        }
        do { try store.save(state) } catch { lastError = error.localizedDescription }
        for observer in axObservers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        axObservers.removeAll()
        applied.removeAll()
        refresh()
    }

    @objc func recover() {
        guard MacDesktop.trusted else { return }
        let windows = MacDesktop.windows()
        for record in state.windows where state.minimizedByManager.contains(record.id) || state.parkedByManager[record.id] != nil {
            let matches = windows.filter {
                $0.appID == record.appID &&
                ((!record.accessibilityID.isEmpty && $0.identifier == record.accessibilityID) ||
                 (!record.title.isEmpty && $0.title == record.title))
            }
            if matches.count == 1 { bindings[record.id] = matches[0] }
        }
        pause()
    }

    @objc func reloadConfig() {
        do {
            config = try SpaceyConfig.load(configURL)
            lastError = nil
        } catch { lastError = "config.json is invalid: \(error.localizedDescription)" }
        if let categories = config.categories { state.adopt(categories, displays: displays()) }
        if enabled { unregisterHotKeys(); try? registerHotKeys() }
        reconcile()
        refresh()
    }

    @objc func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(SpaceyConfig(gap: config.gap, dock: config.dock, categories: state.categories)).write(to: configURL)
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc func quit() { pause(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if enabled { pause() } }

    // spacey://focus/browser, spacey://workspace/browser/2, spacey://move/comms, spacey://solo,
    // spacey://pause, spacey://resume, spacey://reload, spacey://inbox, spacey://jump, spacey://awake,
    // spacey://setup/1 (0 screens, 1 categories, 2 shortcuts), spacey://add/browser/2, spacey://remove/browser/2,
    // spacey://restore
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "spacey" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "focus": if let category = parts.first { focusCategory(category) }
        case "workspace":
            if parts.count == 2, let number = Int(parts[1]) { selectWorkspace(number, in: parts[0]) }
            else if let number = parts.first.flatMap(Int.init), let category = state.focusedCategory { selectWorkspace(number, in: category) }
        case "move": if let category = parts.first { moveFocused(toCategory: category) }
        case "add", "remove":
            // spacey://add/browser/2 puts Browser on screen 2 (counting left to right) as well.
            let displays = displays().sorted { $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x }
            guard parts.count == 2, let index = Int(parts[1]), displays.indices.contains(index - 1) else { break }
            if url.host == "add" { state.add(parts[0], to: displays[index - 1], displays: self.displays()) }
            else { state.remove(parts[0], from: displays[index - 1], displays: self.displays()) }
            applied.removeAll()
            reconcile()
        case "restore":
            // Puts back every area that a window was brought into, like the ↩ buttons in the bar.
            for key in state.overrides.keys {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { restore(parts[1], onDisplay: parts[0]) }
            }
        case "solo": toggleSolo()
        case "pause": if enabled { pause() }
        case "resume": if !enabled { start() }
        case "reload": reloadConfig()
        case "inbox": toggleInbox()
        case "jump": jumpToMostUrgent()
        case "awake": toggleAwake()
        case "setup":
            if let tab = parts.first.flatMap(Int.init) { setup.model.tab = tab }
            if !setup.isOpen { toggleSetup() } else { refreshSetup() }
        default: break
        }
    }

    // MARK: Window management

    func schedule(delay: Double = 0.2) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile(adoptFocus: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var dockHeight: Double { config.dock ? Dock.reservedHeight : 0 }

    // Screens minus the bar at the top and, on the main screen, the dock at the bottom.
    func displays() -> [Display] {
        let main = CGDisplayBounds(CGMainDisplayID())
        return MacDesktop.displays().map { display in
            var display = display
            // Windows start below the bar (CoreGraphics coordinates grow downward).
            if let screen = MacDesktop.screen(for: display) {
                let bottom = main.height - Bar.frame(on: screen).minY
                let shift = max(0, bottom - display.usableFrame.y)
                display.usableFrame.y += shift
                display.usableFrame.height -= shift
            }
            if dockHeight > 0, display.frame.x == main.minX, display.frame.y == main.minY {
                display.usableFrame.height = max(200, display.usableFrame.height - dockHeight)
            }
            return display
        }
    }

    func reconcile(adoptFocus: Bool = false) {
        guard enabled else { return }
        guard MacDesktop.trusted else { lastError = DesktopError.accessibility.localizedDescription; pause(); return }
        // Never fight a drag or a resize in progress.
        if NSEvent.pressedMouseButtons != 0 { schedule(delay: 0.3); return }
        // A fullscreen window lives in its own Space; leave everything alone until it exits.
        if MacDesktop.focusedIsFullscreen() { refresh(); return }
        let displays = displays()
        guard !displays.isEmpty else { return }
        state.ensureProfile(displays: displays)
        var current: [UUID: MacDesktop.Window] = [:]
        var created: [UUID] = []
        for window in MacDesktop.windows() {
            let existing = bindings.first { CFEqual($0.value.element, window.element) }?.key
            let matches = state.windows.filter { record in
                record.appID == window.appID && current[record.id] == nil &&
                ((!window.identifier.isEmpty && record.accessibilityID == window.identifier) ||
                 (!window.title.isEmpty && record.title == window.title))
            }
            let id = existing ?? (matches.count == 1 ? matches.first?.id : nil) ?? UUID()
            if let index = state.windows.firstIndex(where: { $0.id == id }) {
                state.windows[index].title = window.title
            } else {
                let category = state.home(for: window.appID)
                let live = Set(current.keys).union(bindings.keys)
                state.windows.append(WindowRecord(id: id, appID: window.appID, title: window.title,
                                                  accessibilityID: window.identifier, category: category,
                                                  workspace: state.freeWorkspace(in: category, live: live)))
                created.append(id)
            }
            current[id] = window
        }
        let firstPass = bindings.isEmpty
        bindings = current
        if !firstPass { created.forEach(classify) }
        if adoptFocus, let id = focusedID, id != state.focusedWindow || state.focusedCategory != state.record(id)?.category {
            adopt(id, displays: displays)
        }
        state.pruneOverrides(live: Set(bindings.keys), displays: displays)
        let live = bindings.map { LiveWindow(id: $0.key, frame: $0.value.frame, minimized: $0.value.minimized) }
        let plan = state.plan(displays: displays, live: live, gap: config.gap)
        lastShown = Set(plan.filter { !$0.hidden }.map(\.id))
        do {
            try store.save(state)
            for placement in plan {
                guard let window = bindings[placement.id] else { continue }
                if placement.hidden {
                    // User-minimized windows stay in the Dock; everything else parks offscreen instantly.
                    guard !window.minimized else { continue }
                    let onScreen = displays.contains { $0.frame.contains(x: window.frame.midX, y: window.frame.midY) }
                    if state.parkedByManager[placement.id] != nil && !onScreen { continue }
                    let home = state.record(placement.id).flatMap { state.screen(of: $0.category, displays: displays) } ?? displays[0]
                    if state.parkedByManager[placement.id] == nil {
                        state.parkedByManager[placement.id] = window.frame
                        try store.save(state)
                    }
                    MacDesktop.setPosition(window, DesktopState.parkingFrame(for: window.frame, on: home, among: displays))
                    applied[placement.id] = nil
                } else {
                    if window.minimized && state.minimizedByManager.contains(placement.id) {
                        try MacDesktop.setMinimized(window, false)
                        state.minimizedByManager.remove(placement.id)
                    }
                    state.parkedByManager[placement.id] = nil
                    guard let target = placement.frame, !failedFrames.contains(placement.id) else { continue }
                    // Terminals snap to whole cells; once a target was applied, near enough is done.
                    if applied[placement.id] == target, MacDesktop.near(window.frame, target) { continue }
                    do { try MacDesktop.setFrame(window, target); applied[placement.id] = target }
                    catch {
                        // Fixed-size windows (System Settings, dialogs) float, centred in their area.
                        failedFrames.insert(placement.id)
                        if let actual = MacDesktop.frame(window.element) {
                            MacDesktop.setPosition(window, Frame(x: target.midX - actual.width / 2, y: max(target.y, target.midY - actual.height / 2),
                                                                 width: actual.width, height: actual.height))
                        }
                    }
                }
            }
            try store.save(state)
        } catch {
            lastError = error.localizedDescription
            pause()
        }
        installAXObservers()
        refresh()
    }

    // Focus moved to `id`. A window that was offscreen (a link opened from Slack, Cmd-Tab, a new
    // window) comes into the area you were working in; the bar then offers to put that area back.
    func adopt(_ id: UUID, displays: [Display]) {
        guard !lastShown.isEmpty, !lastShown.contains(id), let previous = state.focusedWindow, lastShown.contains(previous),
              let frame = bindings[previous].flatMap({ MacDesktop.frame($0.element) }),
              let display = displays.first(where: { $0.frame.contains(x: frame.midX, y: frame.midY) }),
              let record = state.record(previous), let window = state.record(id) else {
            state.follow(id, displays: displays, preferred: focusedDisplay)
            return
        }
        // The area the previous window was in: its own category's, or the one it had taken over.
        let area = state.visible(on: display, displays: displays).first { category in
            let slot = state.overrides["\(display.id)|\(category)"]
            return slot.map { $0.category == record.category && $0.workspace == record.workspace } ?? (category == record.category)
        } ?? record.category
        if window.category == area && state.overrides["\(display.id)|\(area)"] == nil {
            state.select(workspace: window.workspace, in: area, on: display, displays: displays)
            state.focusedWindow = id
        } else {
            state.summon(id, into: display, replacing: area)
        }
    }

    func restore(_ category: String, onDisplay displayID: String) {
        guard let display = displays().first(where: { $0.id == displayID }) else { return }
        state.restore(category, on: display)
        applied.removeAll()
        reconcile()
        raiseCurrent(in: category, on: display)
    }

    // A window from an app no category claims asks Apple Intelligence where it belongs. The answer
    // moves it (and teaches Spacey the app), but only if the window wasn't moved by hand meanwhile.
    func classify(_ id: UUID) {
        guard Advisor.available, let record = state.record(id),
              !state.categories.contains(where: { $0.apps.contains(record.appID) }), classifying.insert(id).inserted else { return }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.appID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? record.appID
        let categories = state.categories
        Task {
            defer { classifying.remove(id) }
            guard let category = await Advisor.classify(.init(app: app, bundleID: record.appID, title: record.title), into: categories),
                  let now = state.record(id), now.category == record.category, category != now.category else { return }
            state.move(window: id, to: category)
            state.move(window: id, toWorkspace: state.freeWorkspace(in: category, live: Set(bindings.keys).subtracting([id])))
            state.follow(id, displays: displays())
            reconcile()
        }
    }

    // Asks Apple Intelligence for a fresh set of categories from the windows that are open.
    @objc func regroup() {
        let windows = state.windows.filter { bindings[$0.id] != nil }.map { record in
            Advisor.Window(app: NSRunningApplication.runningApplications(withBundleIdentifier: record.appID).first?.localizedName ?? record.appID,
                           bundleID: record.appID, title: record.title)
        }
        Task {
            guard let categories = await Advisor.propose(from: windows) else {
                lastError = "Apple Intelligence couldn't group your windows. \(Advisor.status)"
                refresh()
                return
            }
            state.adopt(categories, displays: displays())
            if enabled { unregisterHotKeys(); try? registerHotKeys() }
            reconcile()
        }
    }

    func installAXObservers() {
        let pids = Set(bindings.values.map(\.pid))
        for pid in Array(axObservers.keys) where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObservers.removeValue(forKey: pid)!), .defaultMode)
        }
        for pid in pids where axObservers[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue().schedule()
                }
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification] {
                _ = AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObservers[pid] = observer
        }
    }

    var focusedID: UUID? {
        guard let focused = MacDesktop.focusedElement() else { return nil }
        return bindings.first { CFEqual($0.value.element, focused) }?.key
    }

    // The screen you're working on: the focused window's, else the one under the pointer.
    var focusedDisplay: Display? {
        let displays = displays()
        if let id = focusedID, let record = state.record(id), let display = state.screen(of: record.category, displays: displays) {
            return display
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return displays.first { display in screen.map { MacDesktop.screen(for: display) == $0 } ?? false } ?? displays.first
    }

    func remember() {
        if let category = state.focusedCategory { previous = (category, state.workspace(of: category)) }
    }

    // The screen a category key acts on: the one you're on if the category is there, else its first.
    func target(for category: String) -> Display? {
        let displays = displays()
        let hosts = state.hosts(of: category, displays: displays)
        return focusedDisplay.flatMap { here in hosts.first { $0.id == here.id } } ?? hosts.first
    }

    // Raises the window in the category's current workspace; an empty category opens its first app.
    func raiseCurrent(in category: String, on display: Display? = nil) {
        let displays = displays()
        let workspace = (display ?? target(for: category)).map { state.workspace(of: category, on: $0, displays: displays) }
            ?? state.workspace(of: category)
        if let record = state.windows.first(where: { $0.category == category && $0.workspace == workspace && bindings[$0.id] != nil }),
           let window = bindings[record.id] {
            state.focusedWindow = record.id
            MacDesktop.raise(window)
        } else if !state.windows.contains(where: { $0.category == category && bindings[$0.id] != nil }),
                  let app = state.category(category)?.apps.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
            open(app: app)
        }
    }

    func focusCategory(_ category: String) {
        guard enabled, state.category(category) != nil else { return }
        remember()
        // A category that's on no monitor comes to the one you're on.
        if state.isUnplaced(category, displays: displays()), let here = focusedDisplay {
            state.add(category, to: here, displays: displays())
            applied.removeAll()
        }
        let display = target(for: category)
        state.focus(category, on: display, displays: displays())
        reconcile()
        raiseCurrent(in: category, on: display)
    }

    // `display` picks which screen's copy of the category changes; by default the one you're on.
    func selectWorkspace(_ number: Int, in category: String, on display: Display? = nil) {
        guard enabled, state.category(category) != nil, (1...9).contains(number) else { return }
        remember()
        let screen = display ?? target(for: category)
        state.select(workspace: number, in: category, on: screen, displays: displays())
        reconcile()
        raiseCurrent(in: category, on: screen)
    }

    func moveFocused(toCategory category: String) {
        guard enabled, let id = focusedID, state.category(category) != nil else { return }
        state.move(window: id, to: category)
        state.move(window: id, toWorkspace: state.freeWorkspace(in: category, live: Set(bindings.keys).subtracting([id])))
        state.follow(id, displays: displays())
        reconcile()
        if let window = bindings[id] { MacDesktop.raise(window) }
    }

    func moveFocused(toWorkspace number: Int) {
        guard enabled, let id = focusedID else { return }
        state.move(window: id, toWorkspace: number)
        state.follow(id, displays: displays())
        reconcile()
        if let window = bindings[id] { MacDesktop.raise(window) }
    }

    func placeOnFocusedScreen(_ category: String) {
        guard enabled, let display = focusedDisplay else { return }
        state.place(category, on: display, displays: displays())
        state.focus(category, displays: displays())
        applied.removeAll()
        reconcile()
        raiseCurrent(in: category)
    }

    @objc func toggleSplit() {
        guard enabled, let display = focusedDisplay else { return }
        state.toggleSplit(on: display, displays: displays())
        applied.removeAll()
        reconcile()
    }

    func setLayout(_ layout: TileLayout) {
        guard enabled, let category = state.focusedCategory,
              let display = state.screen(of: category, displays: displays()) else { return }
        state.setLayout(layout, display: display, category: category)
        failedFrames.removeAll()
        applied.removeAll()
        reconcile()
    }

    @objc func toggleSolo() {
        state.solo.toggle()
        if state.solo { state.focusedWindow = focusedID ?? state.focusedWindow }
        applied.removeAll()
        reconcile()
    }

    // Option-Tab steps through the focused category's workspaces that have windows.
    func cycle() {
        guard let category = state.focusedCategory else { return }
        let used = Set(state.windows.filter { $0.category == category && bindings[$0.id] != nil }.map(\.workspace)).sorted()
        guard !used.isEmpty else { return }
        let here = target(for: category).map { state.workspace(of: category, on: $0, displays: displays()) } ?? state.workspace(of: category)
        let next = used.first { $0 > here } ?? used[0]
        selectWorkspace(next, in: category)
    }

    var visibleWindows: [(UUID, Frame)] {
        state.plan(displays: displays(), live: bindings.map { LiveWindow(id: $0.key, frame: $0.value.frame, minimized: $0.value.minimized) },
                   gap: config.gap).compactMap { placement in placement.frame.map { (placement.id, $0) } }
    }

    func focus(_ direction: Direction) {
        guard let id = focusedID, let origin = bindings[id].flatMap({ MacDesktop.frame($0.element) }),
              let target = DesktopState.neighbour(of: origin, in: direction, among: visibleWindows.filter { $0.0 != id }),
              let window = bindings[target] else { return }
        state.follow(target, displays: displays())
        MacDesktop.raise(window)
        refresh()
    }

    func swap(_ direction: Direction) {
        guard let id = focusedID, let origin = bindings[id].flatMap({ MacDesktop.frame($0.element) }),
              let target = DesktopState.neighbour(of: origin, in: direction, among: visibleWindows.filter { $0.0 != id }) else { return }
        state.swap(id, target)
        applied.removeAll()
        reconcile()
    }

    func open(app bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Menu, bar and dock

    func item(_ title: String, _ action: Selector?, tag: Int = 0, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func refresh() {
        refreshSetup()
        rebuildMenu()
        refreshBar()
        refreshDock()
        writeStatus()
    }

    // ~/Library/Application Support/Spacey/status.json, for scripts and debugging.
    func writeStatus() {
        struct Status: Encodable {
            var enabled: Bool, trusted: Bool, profile: String?, category: String?, workspace: Int?, solo: Bool
            var windows: Int, waiting: Int, intelligence: String, error: String?
        }
        let status = Status(enabled: enabled, trusted: MacDesktop.trusted, profile: state.profile(for: displays())?.name,
                            category: state.focusedCategory, workspace: state.focusedCategory.map(state.workspace(of:)),
                            solo: state.solo, windows: bindings.count, waiting: rex.board.attention.count,
                            intelligence: Advisor.status, error: lastError)
        let url = store.url.deletingLastPathComponent().appendingPathComponent("status.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(status) { try? data.write(to: url, options: .atomic) }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let displays = displays()
        let profile = state.profile(for: displays)
        menu.addItem(item("Set up Spacey…  ⌥,", #selector(toggleSetup), symbol: "square.grid.2x2"))
        menu.addItem(.separator())
        menu.addItem(header("Profile: \(profile?.name ?? "—")"))
        menu.addItem(item("Rename profile…", #selector(renameProfile), symbol: "pencil"))
        menu.addItem(.separator())

        menu.addItem(header("This screen"))
        if let display = focusedDisplay {
            let setup = profile?.screens[display.id]
            for category in state.categories {
                let here = setup?.categories.contains(category.id) == true
                let entry = item("\(category.name)", here ? nil : #selector(placeMenu(_:)), symbol: category.icon)
                entry.representedObject = category.id
                entry.state = here ? .on : .off
                entry.toolTip = here ? "On this screen" : "Move here (Option-Control-\(category.letter.uppercased()))"
                menu.addItem(entry)
            }
            let split = item((setup?.split ?? true) ? "Show one category at a time" : "Show categories side by side",
                             #selector(toggleSplit), symbol: "rectangle.split.2x1")
            menu.addItem(split)
        }
        menu.addItem(.separator())

        menu.addItem(header("Categories"))
        for category in state.categories {
            let count = state.windows.filter { $0.category == category.id && bindings[$0.id] != nil }.count
            let entry = item("\(category.letter.uppercased())  \(category.name) — \(count) window\(count == 1 ? "" : "s")",
                             #selector(focusMenu(_:)), symbol: category.icon)
            entry.representedObject = category.id
            entry.state = state.focusedCategory == category.id ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(item("New category…", #selector(newCategory), symbol: "plus"))
        if let focused = state.category(state.focusedCategory) {
            menu.addItem(item("Rename \(focused.name)…", #selector(renameCategory), symbol: "character.cursor.ibeam"))
        }
        let ai = item(Advisor.available ? "Regroup with Apple Intelligence" : "Apple Intelligence: \(Advisor.status)",
                      Advisor.available ? #selector(regroup) : nil, symbol: "apple.intelligence")
        menu.addItem(ai)
        menu.addItem(.separator())

        let solo = item("Focus on one window", #selector(toggleSolo), symbol: "scope")
        solo.state = state.solo ? .on : .off
        menu.addItem(solo)
        menu.addItem(item("Side by side", #selector(horizontal), symbol: "rectangle.split.2x1"))
        menu.addItem(item("Stacked", #selector(vertical), symbol: "rectangle.split.1x2"))
        menu.addItem(.separator())
        menu.addItem(item("Rex inbox", #selector(toggleInbox), symbol: "tray"))
        for (index, pane) in rex.board.attention.prefix(5).enumerated() {
            menu.addItem(item("\(pane.name) — \(pane.reason)", #selector(jumpMenu(_:)), tag: index, symbol: "arrow.turn.down.right"))
        }
        let caffeinate = item("Keep Mac awake", #selector(toggleAwake), symbol: "cup.and.saucer")
        caffeinate.state = awake == nil ? .off : .on
        menu.addItem(caffeinate)
        menu.addItem(.separator())
        menu.addItem(item(enabled ? "Pause and restore windows" : "Resume", #selector(toggle)))
        if !(state.minimizedByManager.isEmpty && state.parkedByManager.isEmpty) && !enabled {
            menu.addItem(item("Restore windows from last session", #selector(recover)))
        }
        if !MacDesktop.trusted { menu.addItem(item("Grant Accessibility access…", #selector(requestAccess))) }
        menu.addItem(item("Edit config…", #selector(openConfig)))
        menu.addItem(item("Reload config", #selector(reloadConfig)))
        if !failedFrames.isEmpty { menu.addItem(item("Retile fixed-size windows", #selector(retry))) }
        if let error = lastError {
            let entry = item(String(error.prefix(140)), nil)
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Spacey", #selector(quit), key: "q"))
        statusItem.menu = menu
        self.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: enabled ? "sparkle" : "pause.circle", accessibilityDescription: "Spacey")
    }

    func refreshBar() {
        let displays = displays()
        let live = Set(bindings.keys)
        var screens: [String: [Bar.Item]] = [:]
        for display in displays {
            guard let setup = state.profile(for: displays)?.screens[display.id] else { continue }
            let showing = Set(state.visible(on: display, displays: displays))
            screens[display.id] = setup.categories.compactMap { id in
                guard let category = state.category(id) else { return nil }
                let used = Set(state.windows.filter { $0.category == id && live.contains($0.id) }.map(\.workspace))
                return Bar.Item(category: category, workspace: state.workspace(of: id, on: display, displays: displays), used: used,
                                focused: state.focusedCategory == id && enabled, showing: showing.contains(id))
            }
        }
        let model = bar.model
        model.screens = screens
        model.enabled = enabled
        model.solo = state.solo
        model.waiting = rex.board.attention.count
        model.working = rex.board.working.count
        model.awake = awake != nil
        model.chord = chordCategory
        model.restores = [:]
        for (key, _) in state.overrides {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let category = state.category(parts[1]),
                  let display = displays.first(where: { $0.id == parts[0] }) else { continue }
            model.restores[parts[0], default: []].append(Bar.Restore(category: category,
                                                                     workspace: state.workspace(of: category.id, on: display, displays: displays)))
        }
        bar.layout(displays: displays)
    }

    func refreshDock() {
        guard config.dock else { dock.hide(); return }
        let category = state.category(state.focusedCategory) ?? state.categories[0]
        let running = state.windows.filter { $0.category == category.id && bindings[$0.id] != nil }.map(\.appID)
        var seen: Set<String> = []
        let apps = (running + category.apps).filter { seen.insert($0).inserted }.compactMap { id -> Dock.App? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return Dock.App(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                            icon: NSWorkspace.shared.icon(forFile: url.path),
                            running: !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
                            badge: id == RexBridge.bundleID ? rex.board.attention.count : 0)
        }.prefix(10)
        dock.update(categories: state.categories, active: category.id, apps: Array(apps), waiting: rex.board.attention.count,
                    hidden: enabled && MacDesktop.focusedIsFullscreen())
    }

    // MARK: Setup window

    @objc func toggleSetup() {
        refreshSetup(force: true)
        setup.toggle()
    }

    func refreshSetup(force: Bool = false) {
        guard force || setup.isOpen else { return }
        let displays = displays()
        let profile = state.profile(for: displays)
        let model = setup.model
        model.profile = profile?.name ?? ""
        model.screens = displays.map { display in
            let screen = profile?.screens[display.id]
            return Setup.Screen(id: display.id, name: display.name, frame: display.frame, split: screen?.split ?? true,
                                categories: screen?.categories ?? [])
        }
        model.categories = state.categories
        model.workspaces = Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, state.workspace(of: $0.id)) })
        model.shown = [:]
        for display in displays {
            for id in profile?.screens[display.id]?.categories ?? [] {
                model.shown["\(id)|\(display.id)"] = state.workspace(of: id, on: display, displays: displays)
            }
        }
        model.unplaced = profile?.unplaced ?? []
        model.windows = state.windows.filter { bindings[$0.id] != nil }.map { record in
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: record.appID).first
            return Setup.Window(id: record.id, app: app?.localizedName ?? record.appID, title: record.title, icon: app?.icon,
                                category: record.category, workspace: record.workspace)
        }
        model.intelligence = Advisor.status
        model.intelligenceAvailable = Advisor.available
        model.error = lastError
    }

    func setupActions() -> Setup.Actions {
        var actions = Setup.Actions()
        actions.place = { [weak self] category, displayID in
            guard let self, let display = self.displays().first(where: { $0.id == displayID }) else { return }
            self.state.place(category, on: display, displays: self.displays())
            self.applied.removeAll()
            self.reconcile()
        }
        actions.add = { [weak self] category, displayID in
            guard let self, let display = self.displays().first(where: { $0.id == displayID }) else { return }
            self.state.add(category, to: display, displays: self.displays())
            self.applied.removeAll()
            self.reconcile()
        }
        actions.removeFromScreen = { [weak self] category, displayID in
            guard let self, let display = self.displays().first(where: { $0.id == displayID }) else { return }
            self.state.remove(category, from: display, displays: self.displays())
            self.applied.removeAll()
            self.reconcile()
        }
        actions.split = { [weak self] displayID, split in
            guard let self else { return }
            let key = DesktopState.topologyKey(self.displays())
            self.state.profiles[key]?.screens[displayID]?.split = split
            self.applied.removeAll()
            self.reconcile()
        }
        actions.move = { [weak self] id, category, workspace in
            guard let self else { return }
            self.state.move(window: id, to: category)
            self.state.move(window: id, toWorkspace: workspace)
            self.state.follow(id, displays: self.displays())
            self.applied.removeAll()
            self.reconcile()
        }
        actions.raise = { [weak self] id in
            guard let self, let window = self.bindings[id] else { return }
            self.state.follow(id, displays: self.displays())
            self.reconcile()
            MacDesktop.raise(window)
        }
        actions.showWorkspace = { [weak self] category, number in self?.selectWorkspace(number, in: category) }
        actions.rename = { [weak self] id, name in
            guard let self, let index = self.state.categories.firstIndex(where: { $0.id == id }),
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.state.categories[index].name = name.trimmingCharacters(in: .whitespaces)
            try? self.store.save(self.state)
            self.refresh()
        }
        actions.addCategory = { [weak self] name in
            guard let self else { return }
            guard self.state.addCategory(named: name, color: Advisor.colors[self.state.categories.count % Advisor.colors.count]) != nil else {
                self.lastError = "Couldn't add \(name): the name is taken or no letter is free."
                self.refresh()
                return
            }
            self.lastError = nil
            self.state.ensureProfile(displays: self.displays())
            if self.enabled { self.unregisterHotKeys(); try? self.registerHotKeys() }
            self.reconcile()
        }
        actions.remove = { [weak self] id in
            guard let self else { return }
            self.state.removeCategory(id, displays: self.displays())
            if self.enabled { self.unregisterHotKeys(); try? self.registerHotKeys() }
            self.applied.removeAll()
            self.reconcile()
        }
        actions.renameProfile = { [weak self] name in
            guard let self, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.state.profiles[DesktopState.topologyKey(self.displays())]?.name = name
            try? self.store.save(self.state)
            self.refresh()
        }
        actions.regroup = { [weak self] in self?.regroup() }
        return actions
    }

    func ask(_ title: String, value: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @objc func renameProfile() {
        let key = DesktopState.topologyKey(displays())
        guard let name = ask("Name this monitor setup", value: state.profiles[key]?.name ?? "") else { return }
        state.profiles[key]?.name = name
        try? store.save(state)
        refresh()
    }

    @objc func newCategory() {
        guard let name = ask("New category", value: "") else { return }
        guard let category = state.addCategory(named: name, color: Advisor.colors[state.categories.count % Advisor.colors.count]) else {
            lastError = "Couldn't add \(name): the name is taken or no letter is free."
            refresh()
            return
        }
        state.ensureProfile(displays: displays())
        if enabled { unregisterHotKeys(); try? registerHotKeys() }
        focusCategory(category.id)
    }

    @objc func renameCategory() {
        guard let id = state.focusedCategory, let index = state.categories.firstIndex(where: { $0.id == id }),
              let name = ask("Rename \(state.categories[index].name)", value: state.categories[index].name) else { return }
        state.categories[index].name = name
        try? store.save(state)
        refresh()
    }

    @objc func placeMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { placeOnFocusedScreen(id) } }
    @objc func focusMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { focusCategory(id) } }

    // Like `caffeinate -di`: no idle sleep for the display or the Mac until turned off.
    // Closing the lid still sleeps; macOS doesn't let an app prevent that.
    @objc func toggleAwake() {
        if let awake {
            IOPMAssertionRelease(awake)
            self.awake = nil
        } else {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), "Spacey: Keep Mac awake" as CFString,
                                           &id) == kIOReturnSuccess { awake = id }
        }
        refresh()
    }

    @objc func requestAccess() { MacDesktop.requestAccess() }
    @objc func horizontal() { setLayout(.horizontal) }
    @objc func vertical() { setLayout(.vertical) }
    @objc func retry() { failedFrames.removeAll(); applied.removeAll(); reconcile() }

    // MARK: Rex

    func startRex() {
        overlays.onJump = { [weak self] pane in self?.jump(to: pane) }
        rex.onChange = { [weak self] change in self?.rexChanged(change) }
        installHotKeyHandler()
        alwaysHotKeys = [(300, 50, UInt32(optionKey)), (301, 50, UInt32(optionKey | shiftKey)), (219, 43, UInt32(optionKey))]
            .compactMap { id, key, modifiers in register(id: id, key: key, modifiers: modifiers) }
        if alwaysHotKeys.count < 3 { lastError = "Option-` is taken by another app; use the menu for the Rex inbox." }
        rex.start()
    }

    func rexChanged(_ change: RexChange) {
        overlays.model.connected = rex.connected
        overlays.model.rexAvailable = RexBridge.appRunning
        overlays.model.update(from: rex.board)
        overlays.relayout()
        if case .needsUser(let block) = change, !RexBridge.appFrontmost,
           let pane = rex.board.panes[block], pane.state == .blocked || pane.state == .error {
            overlays.showToast(.init(pane: pane, session: rex.board.label(for: pane)))
        }
        refresh()
    }

    func jump(to pane: RexPane) {
        overlays.dismissToast()
        if enabled, let (id, window) = bindings.first(where: { $0.value.appID == RexBridge.bundleID }) {
            state.follow(id, displays: displays())
            reconcile()
            MacDesktop.raise(window)
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: RexBridge.bundleID).first?.activate()
        }
        Task { await rex.jump(to: pane) }
    }

    @objc func toggleInbox() {
        overlays.model.update(from: rex.board)
        overlays.toggleInbox()
    }

    @objc func jumpMenu(_ sender: NSMenuItem) {
        let attention = rex.board.attention
        if attention.indices.contains(sender.tag) { jump(to: attention[sender.tag]) }
    }

    func jumpToMostUrgent() {
        if let pane = rex.board.attention.first { jump(to: pane) } else { toggleInbox() }
    }

    // MARK: Keys

    static let letterCodes: [Character: UInt32] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                                   "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31,
                                                   "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    static let digitCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func handleKey(_ id: UInt32) {
        switch id {
        case 1...9: if let category = state.focusedCategory { selectWorkspace(Int(id), in: category) }
        case 101...109: moveFocused(toWorkspace: Int(id - 100))
        case 200: horizontal()
        case 201: vertical()
        case 202: pause()
        case 203: cycle()
        case 204: toggleSolo()
        case 207: focus(.left)
        case 208: focus(.down)
        case 209: focus(.up)
        case 210: focus(.right)
        case 211: swap(.left)
        case 212: swap(.down)
        case 213: swap(.up)
        case 214: swap(.right)
        case 215: if let id = focusedID, let window = bindings[id] { MacDesktop.close(window) }
        case 216: NSWorkspace.shared.frontmostApplication?.terminate()
        case 217: if let previous { selectWorkspace(previous.workspace, in: previous.category) }
        case 218: toggleSplit()
        case 219: toggleSetup()
        case 300: toggleInbox()
        case 301: jumpToMostUrgent()
        case 500..<600:
            let index = Int(id - 500)
            guard state.categories.indices.contains(index) else { return }
            focusCategory(state.categories[index].id)
            armChord(state.categories[index].id)
        case 600..<700:
            let index = Int(id - 600)
            if state.categories.indices.contains(index) { moveFocused(toCategory: state.categories[index].id) }
        case 700..<800:
            let index = Int(id - 700)
            if state.categories.indices.contains(index) { placeOnFocusedScreen(state.categories[index].id) }
        case 801...809:
            if let category = chordCategory { selectWorkspace(Int(id - 800), in: category) }
            endChord()
        default: break
        }
    }

    // After Option-<letter>, a bare digit within 1.2 seconds picks that category's workspace.
    func armChord(_ category: String) {
        endChord()
        chordCategory = category
        chordKeys = Self.digitCodes.enumerated().compactMap { index, code in register(id: UInt32(801 + index), key: code, modifiers: 0) }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endChord() } }
        chordTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        refreshBar()
    }

    func endChord() {
        chordTimer?.cancel()
        chordKeys.forEach { UnregisterEventHotKey($0) }
        chordKeys.removeAll()
        if chordCategory != nil { chordCategory = nil; refreshBar() }
    }

    func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            MainActor.assumeIsolated { Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue().handleKey(id.id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    func register(id: UInt32, key: UInt32, modifiers: UInt32) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x53504359, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? reference : nil
    }

    func registerHotKeys() throws {
        installHotKeyHandler()
        guard hotKeyHandler != nil else { throw DesktopError.window("Keyboard handler registration failed.") }
        let option = UInt32(optionKey), shift = UInt32(optionKey | shiftKey), control = UInt32(optionKey | controlKey)
        var requests: [(UInt32, UInt32, UInt32)] = []
        for (index, code) in Self.digitCodes.enumerated() {
            requests.append((UInt32(index + 1), code, option))
            requests.append((UInt32(index + 101), code, shift))
        }
        requests += [(200, 1, shift), (201, 1, option), (202, 53, control), (203, 48, option), (204, 3, option),
                     (207, 4, option), (208, 38, option), (209, 40, option), (210, 37, option),
                     (211, 4, shift), (212, 38, shift), (213, 40, shift), (214, 37, shift),
                     (215, 12, option), (216, 12, shift), (217, 49, option), (218, 1, control)]
        for (index, category) in state.categories.enumerated().prefix(99) {
            guard let letter = category.letter.lowercased().first, let code = Self.letterCodes[letter] else { continue }
            requests += [(UInt32(500 + index), code, option), (UInt32(600 + index), code, shift), (UInt32(700 + index), code, control)]
        }
        var refused: [UInt32] = []
        for (id, key, modifiers) in requests {
            if let reference = register(id: id, key: key, modifiers: modifiers) { hotKeys.append(reference) } else { refused.append(id) }
        }
        if refused.contains(where: { (500..<600).contains($0) }) {
            unregisterHotKeys()
            throw DesktopError.window("Another app owns Option-letter keys. Quit it and choose Resume.")
        }
        if !refused.isEmpty { lastError = "\(refused.count) shortcut(s) are taken by another app." }
    }

    // Window keys only; the Rex inbox keys stay live while paused.
    func unregisterHotKeys() {
        endChord()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }
}

let app = NSApplication.shared
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spacey")
let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/spacey/config.json")

if CommandLine.arguments.contains("--rex") {
    // Read-only: prints what the Rex inbox would show, then exits.
    let bridge = RexBridge()
    Task { @MainActor in
        await bridge.seed()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Report: Encodable { var connected: Bool; var attention: [RexPane]; var working: [RexPane] }
        let report = Report(connected: bridge.connected, attention: bridge.board.attention, working: bridge.board.working)
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
        exit(0)
    }
    app.run()
} else if CommandLine.arguments.contains("--inspect") {
    // Read-only: displays, permission, profiles, and each window's app, category, workspace and frame (no titles).
    struct Item: Encodable { var app: String; var category: String?; var workspace: Int?; var frame: Frame; var minimized: Bool }
    struct Inspection: Encodable {
        var accessibility: Bool
        var displays: [Display]
        var categories: [String]
        var profile: Profile?
        var workspaces: [String: Int]
        var windows: [Item]
    }
    let state = (try? StateStore(url: support.appendingPathComponent("desktop.json")).load()) ?? DesktopState()
    let displays = MacDesktop.displays()
    let windows = MacDesktop.windows().map { window in
        let record = state.windows.first { $0.appID == window.appID && (!window.title.isEmpty && $0.title == window.title) }
        return Item(app: window.appID, category: record?.category, workspace: record?.workspace, frame: window.frame, minimized: window.minimized)
    }
    let report = Inspection(accessibility: MacDesktop.trusted, displays: displays, categories: state.categories.map(\.id),
                            profile: state.profile(for: displays), workspaces: state.workspaces, windows: windows)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(report), encoding: .utf8)!)
} else {
    // Two copies would fight over every window. The first one wins.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.nu11ified.spacey")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if Bundle.main.bundleIdentifier != nil, !others.isEmpty { exit(0) }
    do {
        let controller = try Controller(store: StateStore(url: support.appendingPathComponent("desktop.json")), configURL: configURL)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    } catch {
        let alert = NSAlert()
        alert.messageText = "Spacey could not load saved state"
        alert.informativeText = "\(error.localizedDescription)\nThe existing file has been left untouched."
        alert.runModal()
    }
}
