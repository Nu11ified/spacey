import AppKit
import Observation
import SwiftUI
import WorkspaceCore

// A borderless glass panel that can take keys without activating Spacey, so the app
// underneath keeps its focus state and nothing in the Dock or menu bar flickers.
final class GlassPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    var interactive = true

    init<Content: View>(_ content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func resignKey() { super.resignKey(); onResign?() }
    override func cancelOperation(_ sender: Any?) { onResign?() }

    func place(on screen: NSScreen, _ position: (NSRect, NSSize) -> NSPoint) {
        let size = contentView?.fittingSize ?? .zero
        setFrame(NSRect(origin: position(screen.visibleFrame, size), size: size), display: true)
    }

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        if interactive { makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func fadeOut(duration: Double = 0.12) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.alphaValue == 0 { self?.orderOut(nil) } }
        })
    }
}

@MainActor @Observable
final class OverlayModel {
    struct Row: Identifiable, Equatable {
        var pane: RexPane
        var session: String
        var id: String { pane.id }
    }

    var attention: [Row] = []
    var working: [Row] = []
    var selection = 0
    var connected = false
    var rexAvailable = true
    var shown = false

    var hud = 1
    var occupied: Set<Int> = []
    var rexWorkspace: Int?
    var hudShown = false

    var toast: Row?
    var toastShown = false

    var rows: [Row] { attention + working }

    func update(from board: RexBoard) {
        let selected = rows.indices.contains(selection) ? rows[selection].id : nil
        attention = board.attention.map { Row(pane: $0, session: board.label(for: $0)) }
        working = board.working.map { Row(pane: $0, session: board.label(for: $0)) }
        selection = rows.firstIndex { $0.id == selected } ?? min(selection, max(rows.count - 1, 0))
    }
}

struct StateGlyph: View {
    var pane: RexPane

    var body: some View {
        Group {
            switch pane.state {
            case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .working: ProgressView().controlSize(.small)
            case .idle: Image(systemName: "bell.fill").foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 20, height: 20)
    }
}

struct PaneRow: View {
    var row: OverlayModel.Row
    var index: Int
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            StateGlyph(pane: row.pane)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.pane.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text([row.pane.reason, row.pane.app, row.session].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.pane.updatedAt > .distantPast {
                Text(row.pane.updatedAt, style: .relative)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 70, alignment: .trailing)
            }
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }
}

struct InboxView: View {
    var model: OverlayModel
    var jump: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(.secondary)
                Text("Rex").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if model.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.connected ? "checkmark.seal" : "bolt.horizontal.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(emptyTitle).font(.system(size: 13, weight: .medium))
                    Text(emptyDetail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    section("Needs you", model.attention, offset: 0)
                    section("Working", model.working, offset: model.attention.count)
                }
                .padding(.horizontal, 6)
            }

            HStack(spacing: 14) {
                hint("↩", "Jump"); hint("↑↓", "Move"); hint("1–9", "Pick"); hint("esc", "Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 540)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .scaleEffect(model.shown ? 1 : 0.97)
        .animation(.easeOut(duration: 0.16), value: model.shown)
        .animation(.easeOut(duration: 0.12), value: model.selection)
    }

    var summary: String {
        if !model.connected { return model.rexAvailable ? "Connecting…" : "Rex isn’t running" }
        let waiting = model.attention.count, busy = model.working.count
        return [waiting > 0 ? "\(waiting) waiting" : nil, busy > 0 ? "\(busy) working" : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    var emptyTitle: String { model.connected ? "Nothing needs you" : "Not connected to Rex" }
    var emptyDetail: String {
        model.connected ? "Agents that finish or ask for input show up here." : "Open Rex and this fills in by itself."
    }

    @ViewBuilder
    func section(_ title: String, _ rows: [OverlayModel.Row], offset: Int) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                PaneRow(row: row, index: offset + index, selected: model.selection == offset + index)
                    .onTapGesture { jump(offset + index) }
            }
        }
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

struct WorkspaceHUD: View {
    var model: OverlayModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...9, id: \.self) { number in
                let current = number == model.hud
                ZStack(alignment: .topTrailing) {
                    Text("\(number)")
                        .font(.system(size: current ? 15 : 12, weight: current ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(current ? AnyShapeStyle(.white) : model.occupied.contains(number) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: current ? 34 : 24, height: 34)
                        .background(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                    if model.rexWorkspace == number && !model.attention.isEmpty {
                        Circle().fill(.orange).frame(width: 7, height: 7).offset(x: -2, y: 3)
                    }
                }
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .scaleEffect(model.hudShown ? 1 : 0.96)
        .animation(.easeOut(duration: 0.14), value: model.hud)
        .animation(.easeOut(duration: 0.16), value: model.hudShown)
    }
}

struct ToastView: View {
    var model: OverlayModel

    var body: some View {
        if let row = model.toast {
            HStack(spacing: 12) {
                StateGlyph(pane: row.pane)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.pane.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([row.pane.reason, row.session].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("⌥⇧`").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(width: 360, height: 58)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .offset(y: model.toastShown ? 0 : -8)
            .animation(.easeOut(duration: 0.18), value: model.toastShown)
        }
    }
}

@MainActor
final class Overlays {
    let model = OverlayModel()
    var onJump: (RexPane) -> Void = { _ in }
    private lazy var inbox = makeInbox()
    private lazy var hud = makePassive(WorkspaceHUD(model: model))
    private lazy var toast = makeToast()
    private var hudTimer: DispatchWorkItem?
    private var toastTimer: DispatchWorkItem?

    var inboxVisible: Bool { inbox.isVisible && inbox.alphaValue > 0 }

    private func makeInbox() -> GlassPanel {
        let panel = GlassPanel(InboxView(model: model) { [weak self] in self?.jump($0) })
        panel.onResign = { [weak self] in self?.hideInbox() }
        panel.onKey = { [weak self] event in self?.key(event) ?? false }
        return panel
    }

    private func makePassive<V: View>(_ view: V) -> GlassPanel {
        let panel = GlassPanel(view)
        panel.interactive = false
        panel.ignoresMouseEvents = true
        return panel
    }

    private func makeToast() -> GlassPanel {
        let panel = GlassPanel(ToastView(model: model).onTapGesture { [weak self] in
            guard let self, let row = self.model.toast else { return }
            self.dismissToast()
            self.onJump(row.pane)
        })
        panel.interactive = false
        return panel
    }

    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func toggleInbox() { inboxVisible ? hideInbox() : showInbox() }

    func showInbox() {
        dismissToast()
        model.selection = 0
        model.shown = false
        inbox.place(on: Self.activeScreen) { area, size in
            NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.22 - size.height)
        }
        inbox.fadeIn()
        DispatchQueue.main.async { self.model.shown = true }
    }

    func hideInbox() {
        guard inbox.isVisible else { return }
        model.shown = false
        inbox.fadeOut()
    }

    // The inbox grows and shrinks with its rows; keep its top edge where it was.
    func relayout() {
        guard inboxVisible, let size = inbox.contentView?.fittingSize else { return }
        let frame = inbox.frame
        inbox.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func key(_ event: NSEvent) -> Bool {
        let count = model.rows.count
        switch event.keyCode {
        case 53: hideInbox()
        case 125 where count > 0: model.selection = (model.selection + 1) % count
        case 126 where count > 0: model.selection = (model.selection - 1 + count) % count
        case 36, 76: jump(model.selection)
        default:
            guard let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) else { return false }
            jump(digit - 1)
        }
        return true
    }

    private func jump(_ index: Int) {
        guard model.rows.indices.contains(index) else { return }
        let pane = model.rows[index].pane
        hideInbox()
        onJump(pane)
    }

    func flashWorkspace(_ number: Int, on screen: NSScreen?) {
        model.hud = number
        hud.place(on: screen ?? Self.activeScreen) { area, size in
            NSPoint(x: area.midX - size.width / 2, y: area.minY + 90)
        }
        if hud.alphaValue < 1 || !hud.isVisible {
            model.hudShown = false
            hud.fadeIn()
            DispatchQueue.main.async { self.model.hudShown = true }
        }
        hudTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.model.hudShown = false
                self?.hud.fadeOut(duration: 0.22)
            }
        }
        hudTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func showToast(_ row: OverlayModel.Row) {
        guard !inboxVisible else { return }
        model.toast = row
        model.toastShown = false
        toast.place(on: Self.activeScreen) { area, size in
            NSPoint(x: area.maxX - size.width - 14, y: area.maxY - size.height - 10)
        }
        toast.fadeIn()
        DispatchQueue.main.async { self.model.toastShown = true }
        toastTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismissToast() } }
        toastTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func dismissToast() {
        toastTimer?.cancel()
        guard toast.isVisible else { return }
        model.toastShown = false
        toast.fadeOut(duration: 0.18)
    }
}
