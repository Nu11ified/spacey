import AppKit
import Carbon
import WorkspaceCore

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    let store: StateStore
    var state: DesktopState
    var bindings: [UUID: MacDesktop.Window] = [:]
    var enabled = false
    var statusItem: NSStatusItem!
    var pending: DispatchWorkItem?
    var observers: [NSObjectProtocol] = []
    var axObservers: [pid_t: AXObserver] = [:]
    var hotKeys: [EventHotKeyRef] = []
    var hotKeyHandler: EventHandlerRef?
    var failedFrames: Set<UUID> = []
    var lastError: String?

    init(store: StateStore) throws {
        self.store = store
        self.state = try store.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "FocusWM")
        rebuildMenu()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failedFrames.removeAll()
                self?.schedule(delay: 0.8)
            }
        })
    }

    func item(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.tag = tag
        return item
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item(enabled ? "Pause and restore windows" : "Enable management", #selector(toggle)))
        menu.addItem(item("Accessibility permission...", #selector(requestAccess)))
        if !state.minimizedByManager.isEmpty && !enabled {
            menu.addItem(item("Restore windows from previous session", #selector(recover)))
        }
        menu.addItem(.separator())
        for number in 1...9 {
            let entry = item("\(number)  Workspace \(number)", #selector(selectMenu(_:)), tag: number)
            entry.state = state.focusedWorkspace == number ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (index, title) in ["All displays", "Focus workspace", "Focus one window"].enumerated() {
            let entry = item(title, #selector(focusMode(_:)), tag: index)
            entry.state = state.mode == FocusMode.allCases[index] ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(item("Side by side", #selector(horizontal)))
        menu.addItem(item("Top and bottom", #selector(vertical)))
        menu.addItem(item("Classify focused window locally...", #selector(classify)))
        menu.addItem(item("Retry refused window sizes", #selector(retry)))
        if let error = lastError { menu.addItem(item(String(error.prefix(120)), nil)) }
        menu.addItem(.separator())
        menu.addItem(item("Quit and restore windows", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.title = enabled ? " \(state.focusedWorkspace)" : " paused"
    }

    func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FocusWM"
        alert.informativeText = message
        alert.runModal()
    }

    @objc func requestAccess() { MacDesktop.requestAccess() }

    @objc func toggle() {
        if enabled { pause(); return }
        do {
            guard MacDesktop.trusted else { throw DesktopError.accessibility }
            guard !NSWorkspace.shared.runningApplications.contains(where: {
                $0.localizedName == "AeroSpace"
            }) else { throw DesktopError.conflict }
            try registerHotKeys()
            enabled = true
            lastError = nil
            reconcile()
        } catch { alert(error.localizedDescription) }
        rebuildMenu()
    }

    func schedule(delay: Double = 0.2) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile(adoptFocus: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reconcile(adoptFocus: Bool = false) {
        guard enabled else { return }
        guard MacDesktop.trusted else { lastError = DesktopError.accessibility.localizedDescription; pause(); return }
        let displays = MacDesktop.displays()
        guard !displays.isEmpty else { return }
        let observed = MacDesktop.windows()
        var current: [UUID: MacDesktop.Window] = [:]
        for window in observed {
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
                state.windows.append(WindowRecord(id: id, appID: window.appID, title: window.title,
                                                  accessibilityID: window.identifier, workspace: state.focusedWorkspace))
            }
            current[id] = window
        }
        bindings = current
        if let focused = MacDesktop.focusedElement(),
           let id = bindings.first(where: { CFEqual($0.value.element, focused) })?.key {
            if adoptFocus || state.focusedWindow == nil {
                state.focusedWindow = id
                if let workspace = state.windows.first(where: { $0.id == id })?.workspace {
                    state.focusedWorkspace = workspace
                }
            }
        }
        state.reconcile(displays: displays)
        let live = bindings.map { LiveWindow(id: $0.key, frame: $0.value.frame, minimized: $0.value.minimized) }
        do {
            try store.save(state)
            for placement in state.plan(displays: displays, live: live) {
                guard let window = bindings[placement.id] else { continue }
                if placement.hidden {
                    if !window.minimized {
                        state.minimizedByManager.insert(placement.id)
                        try store.save(state)
                        do { try MacDesktop.setMinimized(window, true) }
                        catch { state.minimizedByManager.remove(placement.id); lastError = error.localizedDescription }
                    }
                } else {
                    if window.minimized && state.minimizedByManager.contains(placement.id) {
                        try MacDesktop.setMinimized(window, false)
                        state.minimizedByManager.remove(placement.id)
                    }
                    if let target = placement.frame, !failedFrames.contains(placement.id) {
                        do { try MacDesktop.setFrame(window, target) }
                        catch { failedFrames.insert(placement.id); lastError = error.localizedDescription }
                    }
                }
            }
            try store.save(state)
        } catch {
            lastError = error.localizedDescription
            pause()
        }
        installAXObservers()
        rebuildMenu()
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
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                _ = AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObservers[pid] = observer
        }
    }

    func select(_ number: Int) {
        guard enabled else { return }
        state.select(number, displays: MacDesktop.displays())
        state.focusedWindow = state.windows.first(where: { $0.workspace == number && bindings[$0.id] != nil })?.id
        reconcile()
        if let record = state.windows.first(where: { $0.workspace == number && bindings[$0.id] != nil }),
           let window = bindings[record.id] { MacDesktop.raise(window) }
    }

    @objc func selectMenu(_ sender: NSMenuItem) { select(sender.tag) }
    @objc func horizontal() { state.setLayout(.horizontal, displays: MacDesktop.displays()); failedFrames.removeAll(); reconcile() }
    @objc func vertical() { state.setLayout(.vertical, displays: MacDesktop.displays()); failedFrames.removeAll(); reconcile() }
    @objc func focusMode(_ sender: NSMenuItem) { state.mode = FocusMode.allCases[sender.tag]; reconcile() }
    @objc func retry() { failedFrames.removeAll(); reconcile() }

    func handleKey(_ id: UInt32) {
        if (1...9).contains(id) { select(Int(id)) }
        else if (101...109).contains(id), let focused = MacDesktop.focusedElement(),
                let window = bindings.first(where: { CFEqual($0.value.element, focused) })?.key {
            state.assign(window: window, to: Int(id - 100)); reconcile()
        } else if id == 200 { horizontal() }
        else if id == 201 { vertical() }
        else if id == 202 { pause() }
        else if id == 203 {
            let records = state.windows.filter { $0.workspace == state.focusedWorkspace && bindings[$0.id] != nil }
            guard !records.isEmpty else { return }
            let index = records.firstIndex(where: { $0.id == state.focusedWindow }) ?? -1
            let target = records[(index + 1) % records.count]
            state.focusedWindow = target.id
            reconcile()
            if let window = bindings[target.id] { MacDesktop.raise(window) }
        }
    }

    func registerHotKeys() throws {
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
        let installed = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                                             Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard installed == noErr else { throw DesktopError.window("Keyboard handler registration failed (\(installed)).") }
        let keys: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        var requests: [(UInt32, UInt32, UInt32)] = []
        for (index, key) in keys.enumerated() {
            requests.append((UInt32(index + 1), key, UInt32(optionKey)))
            requests.append((UInt32(index + 101), key, UInt32(optionKey | shiftKey)))
        }
        requests += [(200, 1, UInt32(optionKey | shiftKey)), (201, 1, UInt32(optionKey)),
                     (202, 53, UInt32(optionKey | controlKey)), (203, 48, UInt32(optionKey))]
        for (id, key, modifiers) in requests {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x46574D31, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                unregisterHotKeys()
                throw DesktopError.window("Shortcut registration failed (\(status)). Another app may own Option-number.")
            }
            hotKeys.append(reference)
        }
    }

    func unregisterHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    func pause() {
        enabled = false
        pending?.cancel()
        unregisterHotKeys()
        for id in Array(state.minimizedByManager) {
            if let window = bindings[id] {
                do { try MacDesktop.setMinimized(window, false); state.minimizedByManager.remove(id) }
                catch { lastError = error.localizedDescription }
            }
        }
        do { try store.save(state) } catch { lastError = error.localizedDescription }
        for observer in axObservers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        axObservers.removeAll()
        rebuildMenu()
    }

    @objc func recover() {
        guard MacDesktop.trusted else { alert(DesktopError.accessibility.localizedDescription); return }
        let windows = MacDesktop.windows()
        for record in state.windows where state.minimizedByManager.contains(record.id) {
            let matches = windows.filter {
                $0.appID == record.appID &&
                ((!record.accessibilityID.isEmpty && $0.identifier == record.accessibilityID) ||
                 (!record.title.isEmpty && $0.title == record.title))
            }
            if matches.count == 1 { bindings[record.id] = matches[0] }
        }
        pause()
    }

    @objc func classify() {
        guard let element = MacDesktop.focusedElement(),
              let window = bindings.values.first(where: { CFEqual($0.element, element) }) else {
            alert("Enable management and focus a window first."); return
        }
        let prompt = NSAlert()
        prompt.messageText = "Classify this window on this Mac?"
        prompt.informativeText = "Uses only the app identifier and window title. Results are suggestions and do not move windows."
        prompt.addButton(withTitle: "Classify")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let result = try await LocalIntelligence.classify(app: window.appID, title: window.title)
                alert("\(result.category)\n\(result.attentionIndicated ? "Attention indicated" : "No attention signal established")\n\(result.explanation)")
            } catch { alert(error.localizedDescription) }
        }
    }

    @objc func quit() { pause(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if enabled { pause() } }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--inspect") {
    struct Inspection: Encodable {
        var accessibility: Bool
        var displays: [Display]
        var standardWindowCount: Int
        var intelligence: String
    }
    let report = Inspection(accessibility: MacDesktop.trusted, displays: MacDesktop.displays(),
                            standardWindowCount: MacDesktop.windows().count, intelligence: LocalIntelligence.status)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(report), encoding: .utf8)!)
} else {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusWM")
    do {
        let controller = try Controller(store: StateStore(url: directory.appendingPathComponent("desktop.json")))
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    } catch {
        let alert = NSAlert()
        alert.messageText = "FocusWM could not load saved state"
        alert.informativeText = "\(error.localizedDescription)\nThe existing file has been left untouched."
        alert.runModal()
    }
}
