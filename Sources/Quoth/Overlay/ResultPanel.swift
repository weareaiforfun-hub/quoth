import AppKit
import SwiftUI
import QuothCore

/// A floating card for Command Mode answers and Transform diffs. Esc or ✕ closes it.
@MainActor
final class ResultPanel {
    static let shared = ResultPanel()
    private var panel: NSPanel?

    enum Content {
        case answer(title: String, text: String)
        case diff(title: String, parts: [WordDiff.Part], result: String)
    }

    func show(_ content: Content) {
        close()
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                         styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                         backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ResultView(content: content) { [weak self] in self?.close() })
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 240, y: f.maxY - 320))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A non-activating panel that can still take key events (Esc, text selection).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

struct ResultView: View {
    let content: ResultPanel.Content
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") { TextInserter.copyToClipboard(copyText) }
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                body(for: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .padding(.top, 8)
        .frame(width: 480, height: 260)
    }

    private var title: String {
        switch content { case .answer(let t, _), .diff(let t, _, _): t }
    }

    private var copyText: String {
        switch content { case .answer(_, let t): t; case .diff(_, _, let r): r }
    }

    @ViewBuilder private func body(for c: ResultPanel.Content) -> some View {
        switch c {
        case .answer(_, let text):
            Text(text)
        case .diff(_, let parts, _):
            parts.reduce(Text("")) { acc, p in
                switch p {
                case .same(let s): acc + Text(s)
                case .removed(let s): acc + Text(s).strikethrough().foregroundColor(.red)
                case .added(let s): acc + Text(s).foregroundColor(.green).bold()
                }
            }
        }
    }
}
