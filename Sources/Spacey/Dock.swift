import AppKit
import Observation
import SwiftUI
import WorkspaceCore

@MainActor
final class Dock {
    struct App: Identifiable, Equatable {
        var id: String
        var name: String
        var icon: NSImage
        var running: Bool
        var badge: Int
    }

    // Space the main display gives up at the bottom: the dock plus its margin.
    static let reservedHeight = 80.0

    @MainActor @Observable
    final class Model {
        var modes: [SpaceyConfig.Mode] = []
        var active = 1
        var apps: [App] = []
        var waiting = 0
    }

    let model = Model()
    var onSelect: (Int) -> Void = { _ in }
    var onApp: (String) -> Void = { _ in }
    var onAttention: () -> Void = {}
    private lazy var panel = makePanel()

    private func makePanel() -> GlassPanel {
        let view = DockView(model: model, select: { [weak self] in self?.onSelect($0) },
                            open: { [weak self] in self?.onApp($0) }, attention: { [weak self] in self?.onAttention() })
        // No fullScreenAuxiliary: the dock stays out of fullscreen videos and apps.
        let panel = GlassPanel(view, behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle])
        panel.interactive = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        return panel
    }

    func update(modes: [SpaceyConfig.Mode], active: Int, apps: [App], waiting: Int, hidden: Bool) {
        withAnimation(.easeOut(duration: 0.2)) {
            model.modes = modes
            model.active = active
            model.apps = apps
            model.waiting = waiting
        }
        guard !hidden, let screen = NSScreen.screens.first else { hide(); return }
        DispatchQueue.main.async { [self] in
            panel.place(on: screen) { _, size in
                NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 10)
            }
            if !panel.isVisible { panel.fadeIn() }
        }
    }

    func hide() { if panel.isVisible { panel.fadeOut() } }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DockView: View {
    var model: Dock.Model
    var select: (Int) -> Void
    var open: (String) -> Void
    var attention: () -> Void
    @Namespace private var chip

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.modes.enumerated()), id: \.offset) { index, mode in
                modeChip(mode, number: index + 1)
            }
            if !model.apps.isEmpty {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 30).padding(.horizontal, 6)
                ForEach(model.apps) { app in appIcon(app) }
            }
            if model.waiting > 0 {
                Button(action: attention) {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill")
                        Text("\(model.waiting)").monospacedDigit()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.orange, in: .capsule)
                }
                .buttonStyle(PressStyle())
                .help("Rex: \(model.waiting) waiting — Option-Shift-`")
                .padding(.leading, 4)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    func modeChip(_ mode: SpaceyConfig.Mode, number: Int) -> some View {
        let active = number == model.active
        return Button { select(number) } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon).font(.system(size: 13, weight: .semibold))
                if active { Text(mode.name).font(.system(size: 13, weight: .semibold)).fixedSize() }
            }
            .foregroundStyle(active ? .white : .white.opacity(0.6))
            .padding(.horizontal, active ? 14 : 0)
            .frame(minWidth: 36, minHeight: 36)
            .background {
                if active {
                    Capsule().fill(Color(hex: mode.color)).matchedGeometryEffect(id: "active", in: chip)
                } else {
                    Circle().fill(.white.opacity(0.06))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .help("\(mode.name) — Option-\(number)")
    }

    func appIcon(_ app: Dock.App) -> some View {
        Button { open(app.id) } label: {
            VStack(spacing: 3) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .overlay(alignment: .topTrailing) {
                        if app.badge > 0 {
                            Text("\(app.badge)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.orange, in: .capsule)
                                .offset(x: 4, y: -3)
                        }
                    }
                Circle()
                    .fill(.white.opacity(app.running ? 0.8 : 0))
                    .frame(width: 4, height: 4)
            }
        }
        .buttonStyle(PressStyle())
        .help(app.name)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
