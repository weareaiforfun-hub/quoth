import AppKit
import SwiftUI

/// The floating pill. A non-activating panel so it never steals focus from the target field.
@MainActor
final class EarshotController {
    private let panel: NSPanel
    private let state: AppState
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenHub: (() -> Void)?
    private var hiddenUntil: Date?

    private static let size = NSSize(width: 220, height: 44)
    private static let offsetKey = "earshotOffset"

    init(state: AppState) {
        self.state = state
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let view = EarshotView(state: state,
                               stop: { [weak self] in self?.onStop?() },
                               cancel: { [weak self] in self?.onCancel?() },
                               menu: { [weak self] in self?.showMenu() })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
        applySettings()
    }

    func applySettings() {
        panel.sharingType = state.settings.hideEarshotFromScreenCapture ? .none : .readOnly
        refresh()
    }

    /// Shows or hides the bar for the current phase, on the screen the mouse is on.
    func refresh() {
        let active = state.phase != .idle
        let hidden = hiddenUntil.map { $0 > Date() } ?? false
        if active || (state.settings.earshotAlwaysVisible && !hidden) {
            if active { position() }
            if !panel.isVisible { position(); panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
    }

    private var isPositioning = false

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame   // keeps clear of the menu bar and Dock
        let saved = UserDefaults.standard.array(forKey: Self.offsetKey) as? [Double]
        let fx = saved?[0] ?? 0.5
        let dy = saved?[1] ?? 12
        let x = vf.minX + (vf.width - Self.size.width) * fx
        let y = vf.minY + min(max(dy, 0), vf.height - Self.size.height)
        isPositioning = true
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        isPositioning = false
    }

    private func rememberPosition() {
        guard !isPositioning, let screen = panel.screen else { return }
        let vf = screen.visibleFrame
        let fx = max(0, min(1, (panel.frame.minX - vf.minX) / max(1, vf.width - Self.size.width)))
        let dy = panel.frame.minY - vf.minY
        UserDefaults.standard.set([fx, dy], forKey: Self.offsetKey)
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Quoth", action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let hide = NSMenuItem(title: "Hide for 1 hour", action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let target = MenuTarget { [weak self] item in
            guard let self else { return }
            if item === open { self.onOpenHub?() }
            if item === hide { self.hiddenUntil = Date().addingTimeInterval(3600); self.refresh() }
        }
        for item in [open, hide] { item.target = target; menu.addItem(item) }
        objc_setAssociatedObject(menu, "target", target, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class MenuTarget: NSObject {
    let handler: (NSMenuItem) -> Void
    init(_ handler: @escaping (NSMenuItem) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSMenuItem) { handler(sender) }
}

struct EarshotView: View {
    @ObservedObject var state: AppState
    let stop: () -> Void
    let cancel: () -> Void
    let menu: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var pill: some View {
        switch state.phase {
        case .idle:
            Capsule()
                .fill(.black.opacity(0.55))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: 44, height: 10)
                .contextMenu { Button("Menu…", action: menu) }
                .onTapGesture(perform: menu)

        case .recording(let handsFree):
            HStack(spacing: 8) {
                if handsFree {
                    roundButton("xmark", action: cancel)
                }
                Waveform(levels: state.levels)
                    .frame(width: handsFree ? 96 : 120, height: 20)
                if handsFree {
                    roundButton("stop.fill", tint: .red, action: stop)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(state.commandActive ? Color.orange.opacity(0.9) : .black.opacity(0.85)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))

        case .processing:
            HStack(spacing: 6) {
                ForEach(0..<3) { i in Pulse(delay: Double(i) * 0.15) }
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(.black.opacity(0.85)))

        case .message(let text, let isError):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(isError ? Color(red: 0.75, green: 0.2, blue: 0.2) : .black.opacity(0.85)))
                .fixedSize()
        }
    }

    private func roundButton(_ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

struct Waveform: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: max(3, CGFloat(v) * 20))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

struct Pulse: View {
    let delay: Double
    @State private var on = false
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever().delay(delay)) { on = true }
            }
    }
}
