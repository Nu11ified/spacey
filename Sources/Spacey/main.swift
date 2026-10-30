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
    var hotKeyHandler: EventHandlerRef?
    var failedFrames: Set<UUID> = []
    var applied: [UUID: Frame] = [:]
    var lastError: String?
    var accessTimer: Timer?
    var awake: IOPMAssertionID?
    var previousMode: Int?
    var launchKeys: [UInt32: String] = [:]
    let rex = RexBridge()
    let overlays = Overlays()
    let dock = Dock()
    let bar = Bar()
    var menu = NSMenu()
    var suggestionTimer: DispatchWorkItem?

    init(store: StateStore, configURL: URL) throws {
        self.store = store
        self.configURL = configURL
        self.state = try store.load()
        do { config = try SpaceyConfig.load(configURL) } catch {
            config = .standard
            lastError = "config.json is invalid; using defaults. \(error.localizedDescription)"
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        dock.onSelect = { [weak self] in self?.select($0) }
        dock.onApp = { [weak self] in self?.open(app: $0) }
        dock.onAttention = { [weak self] in self?.jumpToMostUrgent() }
        bar.onSelect = { [weak self] in self?.select($0) }
        bar.onMenu = { [weak self] view in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
        }
        bar.onRex = { [weak self] in
            guard let self else { return }
            if self.rex.board.attention.isEmpty { self.toggleInbox() } else { self.jumpToMostUrgent() }
        }
        bar.onAwake = { [weak self] in self?.toggleAwake() }
        bar.onAccept = { [weak self] suggestion in
            guard let self else { return }
            self.bar.model.suggestion = nil
            self.state.assign(window: suggestion.window, to: suggestion.mode)
            self.reconcile()
        }
        bar.onDismiss = { [weak self] in self?.bar.model.suggestion = nil }
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
                self?.refreshDock()
                self?.bar.layout()
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
        if state.mode > config.modes.count { state.mode = 1 }
        if enabled { unregisterHotKeys(); try? registerHotKeys() }
        reconcile()
        refresh()
    }

    @objc func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(config).write(to: configURL)
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc func quit() { pause(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if enabled { pause() } }

    // spacey://mode/2, spacey://move/3, spacey://solo, spacey://pause, spacey://resume, spacey://reload, spacey://inbox
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "spacey" else { return }
        let argument = Int(url.lastPathComponent)
        switch url.host {
        case "mode": if let argument { select(argument) }
        case "move": if let argument { moveFocused(to: argument) }
        case "solo": toggleSolo()
        case "pause": if enabled { pause() }
        case "resume": if !enabled { start() }
        case "reload": reloadConfig()
        case "inbox": toggleInbox()
        case "jump": jumpToMostUrgent()
        case "awake": toggleAwake()
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

    // The main display gives up its bottom edge to the dock.
    func displays() -> [Display] {
        let main = CGDisplayBounds(CGMainDisplayID())
        let mainHeight = main.height
        return MacDesktop.displays().map { display in
            var display = display
            // Windows start below the bar (CoreGraphics coordinates grow downward).
            if let screen = MacDesktop.screen(for: display) {
                let bottom = mainHeight - Bar.frame(on: screen).minY
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
        if MacDesktop.focusedIsFullscreen() { refreshDock(); return }
        let displays = displays()
        guard !displays.isEmpty else { return }
        var current: [UUID: MacDesktop.Window] = [:]
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
                // Apps a mode claims open there; anything else joins whatever you're doing now.
                state.windows.append(WindowRecord(id: id, appID: window.appID, title: window.title,
                                                  accessibilityID: window.identifier,
                                                  mode: config.mode(for: window.appID) ?? state.mode))
                if !bindings.isEmpty, config.mode(for: window.appID) == nil { suggest(for: id) }
            }
            current[id] = window
        }
        bindings = current
        state.applyRules(config)
        if let focused = MacDesktop.focusedElement(),
           let id = bindings.first(where: { CFEqual($0.value.element, focused) })?.key {
            if adoptFocus || state.focusedWindow == nil {
                state.focusedWindow = id
                // Focusing a window from another mode (Cmd-Tab, a link, a notification) follows it there.
                if let mode = state.record(id)?.mode, mode != state.mode, mode <= config.modes.count {
                    state.mode = mode
                }
            }
        }
        let live = bindings.map { LiveWindow(id: $0.key, frame: $0.value.frame, minimized: $0.value.minimized) }
        state.settle(displays: displays, live: live)
        do {
            try store.save(state)
            for placement in state.plan(displays: displays, live: live, gap: config.gap) {
                guard let window = bindings[placement.id] else { continue }
                if placement.hidden {
                    // User-minimized windows stay in the Dock; everything else parks offscreen instantly.
                    guard !window.minimized else { continue }
                    let onScreen = displays.contains { $0.frame.contains(x: window.frame.midX, y: window.frame.midY) }
                    if state.parkedByManager[placement.id] != nil && !onScreen { continue }
                    let home = state.record(placement.id).map { state.display(of: $0, displays: displays, live: window.frame) } ?? displays[0]
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
                        // Fixed-size windows (System Settings, dialogs) float, centred in their slot.
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

    func installAXObservers() {
        let pids = Set(bindings.values.map(\.pid))
        for pid in Array(axObservers.keys) where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObservers.removeValue(forKey: pid)!), .defaultMode)
        }
        for pid in pids where axObservers[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, context in
                guard let context else { return }
                let title = (notification as String) == kAXTitleChangedNotification
                MainActor.assumeIsolated {
                    let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
                    if title { controller.titleChanged() } else { controller.schedule() }
                }
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification,
                         kAXTitleChangedNotification] {
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

    func select(_ mode: Int) {
        guard enabled, (1...config.modes.count).contains(mode) else { return }
        if mode != state.mode { previousMode = state.mode }
        state.select(mode, count: config.modes.count)
        let first = state.windows.first { $0.mode == mode && bindings[$0.id] != nil }
        state.focusedWindow = first?.id
        reconcile()
        if let first, let window = bindings[first.id] { MacDesktop.raise(window) }
    }

    func moveFocused(to mode: Int) {
        guard enabled, (0...config.modes.count).contains(mode), let id = focusedID else { return }
        state.assign(window: id, to: mode)
        reconcile()
    }

    func moveFocused(by step: Int) {
        guard enabled, let id = focusedID, let record = state.record(id), let window = bindings[id] else { return }
        let displays = displays().sorted { $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x }
        let current = state.display(of: record, displays: displays, live: window.frame)
        guard let index = displays.firstIndex(where: { $0.id == current.id }), displays.count > 1 else { return }
        state.move(window: id, to: displays[(index + step + displays.count) % displays.count], displays: displays)
        reconcile()
        MacDesktop.raise(window)
    }

    func setLayout(_ layout: TileLayout) {
        guard enabled else { return }
        let displays = displays()
        let display = focusedID.flatMap { id in state.record(id).map { state.display(of: $0, displays: displays, live: bindings[id]?.frame) } }
            ?? displays[0]
        state.setLayout(layout, on: display)
        failedFrames.removeAll()
        applied.removeAll()
        reconcile()
    }

    @objc func toggleSolo() {
        state.solo.toggle()
        if state.solo { state.focusedWindow = focusedID ?? state.focusedWindow }
        reconcile()
        refresh()
    }

    func cycle() {
        let records = state.windows.filter { ($0.mode == state.mode || $0.mode == 0) && bindings[$0.id] != nil }
        guard !records.isEmpty else { return }
        let index = records.firstIndex(where: { $0.id == state.focusedWindow }) ?? -1
        let target = records[(index + 1) % records.count]
        state.focusedWindow = target.id
        reconcile()
        if let window = bindings[target.id] { MacDesktop.raise(window) }
    }

    var visibleWindows: [(UUID, Frame)] {
        state.windows.compactMap { record in
            guard record.mode == state.mode || record.mode == 0, state.parkedByManager[record.id] == nil, let window = bindings[record.id],
                  !window.minimized, let frame = MacDesktop.frame(window.element) else { return nil }
            return (record.id, frame)
        }
    }

    func focus(_ direction: Direction) {
        guard let id = focusedID, let origin = bindings[id].flatMap({ MacDesktop.frame($0.element) }),
              let target = DesktopState.neighbour(of: origin, in: direction, among: visibleWindows.filter { $0.0 != id }),
              let window = bindings[target] else { return }
        state.focusedWindow = target
        MacDesktop.raise(window)
    }

    func swap(_ direction: Direction) {
        guard let id = focusedID, let origin = bindings[id].flatMap({ MacDesktop.frame($0.element) }),
              let target = DesktopState.neighbour(of: origin, in: direction, among: visibleWindows.filter { $0.0 != id }) else { return }
        state.swap(id, target, displays: displays())
        applied.removeAll()
        reconcile()
    }

    func launch(_ bundleID: String) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { MacDesktop.newWindow() } else { open(app: bundleID) }
    }

    // Asks the on-device model where a window belongs and offers it in the bar. Nothing moves
    // unless the suggestion is clicked.
    func suggest(for id: UUID) {
        guard ModeAdvisor.available, let record = state.record(id) else { return }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.appID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? record.appID
        let modes = config.modes
        Task {
            guard let mode = await ModeAdvisor.suggest(app: app, title: record.title, modes: modes),
                  let current = state.record(id), current.pinned != true, current.mode != mode else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                bar.model.suggestion = .init(window: id, mode: mode, name: modes[mode - 1].name, app: app)
            }
            suggestionTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.bar.model.suggestion?.window == id { self?.bar.model.suggestion = nil } }
            }
            suggestionTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    @objc func suggestFocused() { if let id = focusedID { suggest(for: id) } }

    @objc func showEverywhere() {
        guard let id = focusedID, let record = state.record(id) else { return }
        state.assign(window: id, to: record.mode == 0 ? state.mode : 0)
        reconcile()
    }

    // Updates just the bar's title, without a full pass over every window.
    func titleChanged() {
        guard let app = NSWorkspace.shared.frontmostApplication, let element = MacDesktop.focusedElement() else { return }
        bar.model.title = MacDesktop.attribute(element, kAXTitleAttribute) as? String ?? app.localizedName ?? ""
        bar.model.appIcon = app.icon
    }

    func open(app bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // Prefer this mode's window of the app, so the dock never yanks you into another mode.
            if let record = state.windows.first(where: { $0.appID == bundleID && $0.mode == state.mode && bindings[$0.id] != nil }),
               let window = bindings[record.id] {
                MacDesktop.raise(window)
            } else {
                running.activate()
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Menu bar and dock

    func item(_ title: String, _ action: Selector?, tag: Int = 0, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    func refresh() {
        rebuildMenu()
        refreshDock()
        refreshBar()
        writeStatus()
    }

    // ~/Library/Application Support/Spacey/status.json, for scripts and debugging.
    func writeStatus() {
        struct Status: Encodable {
            var enabled: Bool, trusted: Bool, mode: String, solo: Bool, windows: Int, waiting: Int, error: String?
        }
        let mode = config.modes[min(state.mode, config.modes.count) - 1].name
        let status = Status(enabled: enabled, trusted: MacDesktop.trusted, mode: mode, solo: state.solo,
                            windows: bindings.count, waiting: rex.board.attention.count, error: lastError)
        let url = store.url.deletingLastPathComponent().appendingPathComponent("status.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(status) { try? data.write(to: url, options: .atomic) }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        for (index, mode) in config.modes.enumerated() {
            let entry = item(mode.name, #selector(selectMenu(_:)), tag: index + 1, symbol: mode.icon)
            entry.state = state.mode == index + 1 ? .on : .off
            entry.toolTip = "Option-\(index + 1)"
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let solo = item("Focus on one window", #selector(toggleSolo), symbol: "scope")
        solo.state = state.solo ? .on : .off
        menu.addItem(solo)
        let everywhere = item("Show this window in every mode", #selector(showEverywhere), symbol: "pin")
        everywhere.state = focusedID.flatMap { state.record($0) }?.mode == 0 ? .on : .off
        menu.addItem(everywhere)
        menu.addItem(item("Side by side", #selector(horizontal), symbol: "rectangle.split.2x1"))
        menu.addItem(item("Stacked", #selector(vertical), symbol: "rectangle.split.1x2"))
        menu.addItem(.separator())
        menu.addItem(item("Rex inbox", #selector(toggleInbox), symbol: "tray"))
        for (index, pane) in rex.board.attention.prefix(5).enumerated() {
            menu.addItem(item("\(pane.name) — \(pane.reason)", #selector(jumpMenu(_:)), tag: index, symbol: "arrow.turn.down.right"))
        }
        menu.addItem(.separator())
        let caffeinate = item("Keep Mac awake", #selector(toggleAwake), symbol: "cup.and.saucer")
        caffeinate.state = awake == nil ? .off : .on
        menu.addItem(caffeinate)
        menu.addItem(.separator())
        menu.addItem(item(enabled ? "Pause and restore windows" : "Resume", #selector(toggle)))
        if !(state.minimizedByManager.isEmpty && state.parkedByManager.isEmpty) && !enabled {
            menu.addItem(item("Restore windows from last session", #selector(recover)))
        }
        if !MacDesktop.trusted { menu.addItem(item("Grant Accessibility access…", #selector(requestAccess))) }
        let ai = item("Apple Intelligence: \(ModeAdvisor.status)", ModeAdvisor.available ? #selector(suggestFocused) : nil,
                      symbol: "apple.intelligence")
        if ModeAdvisor.available { ai.title = "Suggest a mode for this window" }
        menu.addItem(ai)
        menu.addItem(item("Edit modes…", #selector(openConfig)))
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

        // Like a focus mode: the mode's symbol and name, plus how many Rex panes are waiting.
        let mode = config.modes[min(state.mode, config.modes.count) - 1]
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let title = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: enabled ? mode.icon : "pause.circle", accessibilityDescription: mode.name)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            title.append(NSAttributedString(attachment: attachment))
        }
        title.append(NSAttributedString(string: " " + (enabled ? mode.name : "Paused") + (state.solo && enabled ? " · Focus" : ""),
                                        attributes: [.font: font, .baselineOffset: 0.5]))
        let waiting = rex.board.attention.count
        if waiting > 0 {
            title.append(NSAttributedString(string: "  ● \(waiting)", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))
        }
        statusItem.button?.attributedTitle = title
    }

    func refreshBar() {
        let model = bar.model
        model.modes = config.modes.enumerated().map { index, mode in
            var seen: Set<String> = []
            let icons = state.windows.filter { $0.mode == index + 1 && bindings[$0.id] != nil && seen.insert($0.appID).inserted }
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.appID) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return Bar.ModeItem(number: index + 1, mode: mode, apps: icons)
        }
        model.active = min(state.mode, config.modes.count)
        model.enabled = enabled
        model.solo = state.solo
        model.waiting = rex.board.attention.count
        model.working = rex.board.working.count
        model.awake = awake != nil
        titleChanged()
        bar.layout()
    }

    func refreshDock() {
        guard config.dock else { dock.hide(); return }
        let active = min(state.mode, config.modes.count)
        let claimed = config.modes[active - 1].apps
        let extras = state.windows.filter { $0.mode == active && bindings[$0.id] != nil && !claimed.contains($0.appID) }.map(\.appID)
        var seen: Set<String> = []
        let apps = (claimed + extras).filter { seen.insert($0).inserted }.compactMap { id -> Dock.App? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
            return Dock.App(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                            icon: NSWorkspace.shared.icon(forFile: url.path), running: running,
                            badge: id == RexBridge.bundleID ? rex.board.attention.count : 0)
        }
        dock.update(modes: config.modes, active: active, apps: apps, waiting: rex.board.attention.count,
                    hidden: enabled && MacDesktop.focusedIsFullscreen())
    }

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
    @objc func selectMenu(_ sender: NSMenuItem) { select(sender.tag) }
    @objc func horizontal() { setLayout(.horizontal) }
    @objc func vertical() { setLayout(.vertical) }
    @objc func retry() { failedFrames.removeAll(); applied.removeAll(); reconcile() }

    // MARK: Rex

    func startRex() {
        overlays.onJump = { [weak self] pane in self?.jump(to: pane) }
        rex.onChange = { [weak self] change in self?.rexChanged(change) }
        installHotKeyHandler()
        alwaysHotKeys = [(300, UInt32(optionKey)), (301, UInt32(optionKey | shiftKey))].compactMap { id, modifiers in
            register(id: id, key: 50, modifiers: modifiers)
        }
        if alwaysHotKeys.count < 2 { lastError = "Option-` is taken by another app; use the menu for the Rex inbox." }
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
            if let mode = state.record(id)?.mode, mode != state.mode { select(mode) }
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

    func handleKey(_ id: UInt32) {
        switch id {
        case 1...9: select(Int(id))
        case 100...109: moveFocused(to: Int(id - 100))
        case 200: horizontal()
        case 201: vertical()
        case 202: pause()
        case 203: cycle()
        case 204: toggleSolo()
        case 205: moveFocused(by: -1)
        case 206: moveFocused(by: 1)
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
        case 217: if let previousMode { select(previousMode) }
        case 400...499: if let app = launchKeys[id] { launch(app) }
        case 300: toggleInbox()
        case 301: jumpToMostUrgent()
        default: break
        }
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
        let keys: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        var requests: [(UInt32, UInt32, UInt32)] = []
        for (index, key) in keys.enumerated() {
            requests.append((UInt32(index + 1), key, option))
            requests.append((UInt32(index + 101), key, shift))
        }
        requests += [(100, 29, shift), (200, 1, shift), (201, 1, option), (202, 53, control), (203, 48, option),
                     (204, 3, option), (205, 123, control), (206, 124, control),
                     (207, 4, option), (208, 38, option), (209, 40, option), (210, 37, option),
                     (211, 4, shift), (212, 38, shift), (213, 40, shift), (214, 37, shift),
                     (215, 12, option), (216, 12, shift), (217, 49, option)]
        let codes: [String: UInt32] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                       "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
                                       "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "return": 36]
        launchKeys = [:]
        for (index, (key, app)) in config.launch.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let code = codes[key.lowercased()] else { continue }
            launchKeys[UInt32(400 + index)] = app
            requests.append((UInt32(400 + index), code, option))
        }
        var refused: [UInt32] = []
        for (id, key, modifiers) in requests {
            if let reference = register(id: id, key: key, modifiers: modifiers) { hotKeys.append(reference) } else { refused.append(id) }
        }
        // Mode switching is the one thing that must work; the rest degrade to the menu.
        if refused.contains(where: { (1...9).contains($0) }) {
            unregisterHotKeys()
            throw DesktopError.window("Another app owns Option-number. Quit it and choose Resume.")
        }
        if !refused.isEmpty { lastError = "\(refused.count) shortcut(s) are taken by another app." }
    }

    // Window keys only; the Rex inbox keys stay live while paused.
    func unregisterHotKeys() {
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
    // Read-only: displays, permission, config, and each managed window's app, mode and frame (no titles).
    struct Item: Encodable { var app: String; var mode: Int?; var frame: Frame; var minimized: Bool }
    struct Inspection: Encodable {
        var accessibility: Bool
        var displays: [Display]
        var modes: [String]
        var activeMode: Int?
        var windows: [Item]
    }
    let state = try? StateStore(url: support.appendingPathComponent("desktop.json")).load()
    let config = (try? SpaceyConfig.load(configURL)) ?? .standard
    let windows = MacDesktop.windows().map { window in
        let record = state?.windows.first { $0.appID == window.appID && (!window.title.isEmpty && $0.title == window.title) }
        return Item(app: window.appID, mode: record?.mode, frame: window.frame, minimized: window.minimized)
    }
    let report = Inspection(accessibility: MacDesktop.trusted, displays: MacDesktop.displays(),
                            modes: config.modes.map(\.name), activeMode: state?.mode, windows: windows)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(report), encoding: .utf8)!)
} else {
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
