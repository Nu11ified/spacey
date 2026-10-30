import AppKit
import IOKit.ps
import Observation
import SwiftUI
import WorkspaceCore

// The top bar, one per screen: modes and what's in them on the left, the focused window in the
// middle, and Rex, suggestions, keep-awake, battery and the clock on the right. The macOS menu bar
// stays hidden until the pointer touches the top edge, like SketchyBar.
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

    struct ModeItem: Equatable {
        var number: Int
        var mode: SpaceyConfig.Mode
        var apps: [NSImage]
    }

    struct Suggestion: Equatable {
        var window: UUID
        var mode: Int
        var name: String
        var app: String
    }

    @MainActor @Observable
    final class Model {
        var modes: [ModeItem] = []
        var active = 1
        var enabled = true
        var solo = false
        var title = ""
        var appIcon: NSImage?
        var waiting = 0
        var working = 0
        var awake = false
        var battery: (percent: Int, charging: Bool)?
        var suggestion: Suggestion?
    }

    let model = Model()
    var onSelect: (Int) -> Void = { _ in }
    var onMenu: (NSView) -> Void = { _ in }
    var onRex: () -> Void = {}
    var onAwake: () -> Void = {}
    var onAccept: (Suggestion) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private var panels: [GlassPanel] = []
    private var timer: Timer?

    init() {
        readBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
    }

    // One bar per screen, flush with the top edge. Fullscreen Spaces don't get one: no
    // fullScreenAuxiliary. Status items (Rex, battery, clock) only appear on the main screen.
    func layout() {
        let screens = NSScreen.screens
        if panels.count != screens.count {
            panels.forEach { $0.orderOut(nil) }
            panels = screens.indices.map { index in
                let view = BarView(model: model, main: index == 0, notch: screens[index].safeAreaInsets.top > 0, select: { [weak self] in self?.onSelect($0) },
                                   menu: { [weak self] in self?.onMenu($0) }, rex: { [weak self] in self?.onRex() },
                                   awake: { [weak self] in self?.onAwake() },
                                   accept: { [weak self] in self?.onAccept($0) }, dismiss: { [weak self] in self?.onDismiss() })
                let panel = GlassPanel(view, fitsContent: false, behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle])
                panel.interactive = false
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
                return panel
            }
        }
        for (panel, screen) in zip(panels, screens) {
            panel.setFrame(Self.frame(on: screen), display: true)
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        }
    }

    func hide() { panels.forEach { $0.fadeOut() } }

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
            .frame(height: 22)
            .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(0.08)), in: .capsule)
    }
}

struct BarView: View {
    var model: Bar.Model
    var main: Bool
    // The notch hides whatever is centred, so the title moves next to the modes.
    var notch: Bool
    var select: (Int) -> Void
    var menu: (NSView) -> Void
    var rex: () -> Void
    var awake: () -> Void
    var accept: (Bar.Suggestion) -> Void
    var dismiss: () -> Void
    @Namespace private var chip

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.modes, id: \.number) { item in modeButton(item) }
                .fixedSize()
            Spacer(minLength: 16).frame(maxWidth: notch ? 16 : .infinity)
            focused
                .layoutPriority(-1)
                .frame(maxWidth: notch ? 260 : 560, alignment: notch ? .leading : .center)
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

    func modeButton(_ item: Bar.ModeItem) -> some View {
        let active = item.number == model.active && model.enabled
        let occupied = !item.apps.isEmpty
        return Button { select(item.number) } label: {
            HStack(spacing: 5) {
                if active {
                    Image(systemName: item.mode.icon).font(.system(size: 10.5, weight: .bold))
                    Text(item.mode.name).font(.system(size: 12, weight: .semibold))
                } else {
                    Text("\(item.number)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .opacity(occupied ? 0.85 : 0.35)
                }
            }
            .padding(.horizontal, active ? 9 : 6)
            .frame(minWidth: 22, minHeight: 20)
            .background {
                if active { Capsule().fill(Color(hex: item.mode.color)).matchedGeometryEffect(id: "mode", in: chip) }
            }
            .overlay(alignment: .bottom) {
                if occupied && !active { Circle().fill(Color(hex: item.mode.color)).frame(width: 3, height: 3).offset(y: 1) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .help("\(item.mode.name) — Option-\(item.number)")
        .animation(.easeOut(duration: 0.18), value: model.active)
    }

    var focused: some View {
        HStack(spacing: 6) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
            }
            Text(model.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(0.75)
            if model.solo {
                Image(systemName: "scope").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.yellow)
            }
        }
    }

    @ViewBuilder
    var status: some View {
        if let suggestion = model.suggestion {
            HStack(spacing: 0) {
                Button { accept(suggestion) } label: {
                    Chip(tint: .purple.opacity(0.55)) {
                        HStack(spacing: 5) {
                            Image(systemName: "apple.intelligence")
                            Text("\(suggestion.app) → \(suggestion.name)").lineLimit(1)
                        }
                    }
                }
                .buttonStyle(PressStyle())
                .help("Apple Intelligence thinks this window belongs in \(suggestion.name). Click to move it.")
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.6).frame(width: 18, height: 22)
                }
                .buttonStyle(PressStyle())
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
            MenuAnchor(open: menu)
        }
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
private struct MenuAnchor: View {
    var open: (NSView) -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .fixedSize()
        }
        .overlay(ClickTarget(open: open))
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
