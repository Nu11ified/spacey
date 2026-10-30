import AppKit
import IOKit.ps
import Observation
import SwiftUI
import WorkspaceCore

// The top bar, one per screen. Each screen's bar lists the categories that live on it with their
// workspaces; the main screen also shows Rex, keep-awake, battery and the clock.
// The macOS menu bar stays hidden until the pointer touches the top edge.
@MainActor
final class Bar {
    static let height = 28.0

    // On a notched screen the bar fills the notch band; elsewhere it sits at the top of the visible
    // area, which is the very top while the macOS menu bar is hidden.
    static func frame(on screen: NSScreen) -> NSRect {
        let notch = screen.safeAreaInsets.top
        if notch > 0 { return NSRect(x: screen.frame.minX, y: screen.frame.maxY - notch, width: screen.frame.width, height: notch) }
        return NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - height, width: screen.frame.width, height: height)
    }

    struct Item: Equatable {
        var category: WorkspaceCore.Category
        var workspace: Int
        var used: Set<Int>
        var focused: Bool
        var showing: Bool
    }

    @MainActor @Observable
    final class Model {
        var screens: [String: [Item]] = [:]
        var enabled = true
        var solo = false
        var waiting = 0
        var working = 0
        var awake = false
        var battery: (percent: Int, charging: Bool)?
        var chord: String?
    }

    let model = Model()
    var onCategory: (String) -> Void = { _ in }
    var onWorkspace: (String, Int, String) -> Void = { _, _, _ in }
    var onMenu: (NSView) -> Void = { _ in }
    var onRex: () -> Void = {}
    var onAwake: () -> Void = {}
    var onSetup: () -> Void = {}
    private var panels: [String: GlassPanel] = [:]
    private var timer: Timer?

    init() {
        readBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
    }

    // One bar per screen. Fullscreen Spaces don't get one: no fullScreenAuxiliary.
    func layout(displays: [Display]) {
        var keep: Set<String> = []
        for display in displays {
            guard let screen = MacDesktop.screen(for: display) else { continue }
            keep.insert(display.id)
            let panel = panels[display.id] ?? {
                let view = BarView(model: model, display: display.id, main: screen == NSScreen.screens.first,
                                   category: { [weak self] in self?.onCategory($0) },
                                   workspace: { [weak self] in self?.onWorkspace($0, $1, display.id) },
                                   menu: { [weak self] in self?.onMenu($0) }, rex: { [weak self] in self?.onRex() },
                                   awake: { [weak self] in self?.onAwake() }, setup: { [weak self] in self?.onSetup() })
                let panel = GlassPanel(view, fitsContent: false, behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle])
                panel.interactive = false
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
                panels[display.id] = panel
                return panel
            }()
            let frame = Self.frame(on: screen)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        }
        for id in panels.keys where !keep.contains(id) { panels.removeValue(forKey: id)?.orderOut(nil) }
    }

    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            model.battery = (capacity, description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            return
        }
        model.battery = nil
    }
}

private struct Chip<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(0.08)), in: .capsule)
    }
}

struct BarView: View {
    var model: Bar.Model
    var display: String
    var main: Bool
    var category: (String) -> Void
    var workspace: (String, Int) -> Void
    var menu: (NSView) -> Void
    var rex: () -> Void
    var awake: () -> Void
    var setup: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.screens[display] ?? [], id: \.category.id) { item in categoryChip(item) }
                .fixedSize()
            Spacer(minLength: 16)
            HStack(spacing: 8) { status }
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.94))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    // [B] Browser 1 2 3: the letter, the name, and the workspaces that hold windows. The current
    // workspace is filled. While Option-B waits for a digit, all nine are offered.
    func categoryChip(_ item: Bar.Item) -> some View {
        let color = Color(hex: item.category.color)
        let armed = model.chord == item.category.id
        let numbers = armed ? Array(1...9) : item.used.union([item.workspace]).sorted()
        return HStack(spacing: 2) {
            Button { category(item.category.id) } label: {
                HStack(spacing: 5) {
                    Text(item.category.letter.uppercased())
                        .font(.system(size: 10, weight: .heavy).monospaced())
                        .frame(width: 15, height: 15)
                        .background(item.focused ? AnyShapeStyle(color) : AnyShapeStyle(.white.opacity(0.12)), in: .rect(cornerRadius: 4))
                    Text(item.category.name).font(.system(size: 12, weight: .semibold)).fixedSize()
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .help("\(item.category.name) — Option-\(item.category.letter.uppercased()), then a number")
            ForEach(numbers, id: \.self) { number in
                let current = number == item.workspace
                Button { workspace(item.category.id, number) } label: {
                    Text("\(number)")
                        .font(.system(size: 11, weight: current ? .bold : .medium).monospacedDigit())
                        .frame(width: 17, height: 17)
                        .background(current ? AnyShapeStyle(color.opacity(item.focused ? 1 : 0.45)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
                        .opacity(item.used.contains(number) || current ? 1 : 0.4)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(armed ? AnyShapeStyle(color.opacity(0.25)) : AnyShapeStyle(.white.opacity(item.focused ? 0.08 : 0)), in: .rect(cornerRadius: 7))
        .opacity(item.showing ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: armed)
        .animation(.easeOut(duration: 0.15), value: item.workspace)
    }

    @ViewBuilder
    var status: some View {
        if model.solo {
            Image(systemName: "scope").font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
                .help("Showing one window — Option-F to show the rest")
        }
        if model.waiting > 0 || model.working > 0 {
            Button(action: rex) {
                Chip(tint: model.waiting > 0 ? .orange : nil) {
                    HStack(spacing: 5) {
                        if model.waiting > 0 {
                            Image(systemName: "hand.raised.fill")
                            Text("\(model.waiting)").monospacedDigit()
                        } else {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text("\(model.working)").monospacedDigit()
                        }
                    }
                }
            }
            .buttonStyle(PressStyle())
            .help(model.waiting > 0 ? "Rex: \(model.waiting) waiting for you — Option-Shift-`" : "Rex: \(model.working) agents working — Option-`")
        }
        if main {
            Button(action: awake) {
                Image(systemName: model.awake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.awake ? AnyShapeStyle(.green) : AnyShapeStyle(.white.opacity(0.5)))
            }
            .buttonStyle(PressStyle())
            .help(model.awake ? "Keeping the Mac awake. Click to allow sleep." : "Keep the Mac awake")
            if let battery = model.battery {
                HStack(spacing: 3) {
                    Image(systemName: battery.charging ? "battery.100percent.bolt" : batterySymbol(battery.percent))
                    Text("\(battery.percent)%").monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(battery.percent <= 15 && !battery.charging ? AnyShapeStyle(.red) : AnyShapeStyle(.white.opacity(0.7)))
            }
        }
        Button(action: setup) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(PressStyle())
        .help("Set up Spacey — Option-Comma")
        Clock(open: menu)
    }

    func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// The clock. Clicking it opens Spacey's menu, anchored under it.
private struct Clock: View {
    var open: (NSView) -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .fixedSize()
        }
        .overlay(ClickTarget(open: open))
        .help("Spacey menu")
    }
}

private struct ClickTarget: NSViewRepresentable {
    var open: (NSView) -> Void

    final class View: NSView {
        var open: (NSView) -> Void = { _ in }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { open(self) }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) { view.open = open }
}
