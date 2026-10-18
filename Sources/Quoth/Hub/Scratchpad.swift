import AppKit
import SwiftUI
import QuothCore

/// Floating rich-text notepad, toggled with ⌥S. Dictation works in it like any field.
@MainActor
final class ScratchpadController {
    private var panel: NSPanel?
    let store = NotesStore()

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            p.title = "Scratchpad"
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ScratchpadView(model: ScratchpadModel(store: store)))
            p.center()
            p.setFrameAutosaveName("QuothScratchpad")
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ScratchpadModel: ObservableObject {
    let store: NotesStore
    @Published var notes: [Note] = []
    @Published var selected: String?
    @Published var loaded = NSAttributedString()
    /// Bumped whenever `loaded` should replace the editor's content (note switch, version restore).
    @Published var loadToken = 0
    private var saveTask: Task<Void, Never>?

    init(store: NotesStore) {
        self.store = store
        reload()
        if notes.isEmpty { _ = newNote() } else { select(notes[0].id) }
    }

    func reload() { notes = store.list() }

    @discardableResult func newNote() -> String {
        let n = store.create()
        reload()
        select(n.id)
        return n.id
    }

    func select(_ id: String) {
        selected = id
        if let data = store.content(id), !data.isEmpty,
           let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            loaded = s
        } else {
            loaded = NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        }
        loadToken += 1
    }

    /// Debounced autosave.
    func changed(_ text: NSAttributedString) {
        guard let id = selected else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let range = NSRange(location: 0, length: text.length)
            if let rtf = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                self.store.save(id, rtf: rtf, plainText: text.string)
                self.reload()
            }
        }
    }

    func delete(_ id: String) {
        store.delete(id)
        reload()
        if let first = notes.first { select(first.id) } else { newNote() }
    }

    func restore(_ date: Date) {
        guard let id = selected, let data = store.version(id, at: date),
              let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return }
        loaded = s
        loadToken += 1
        changed(s)
    }
}

struct ScratchpadView: View {
    @ObservedObject var model: ScratchpadModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selected }, set: { if let id = $0 { model.select(id) } })) {
                ForEach(model.notes) { n in
                    VStack(alignment: .leading) {
                        Text(n.title).lineLimit(1)
                        Text(n.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(n.id)
                    .contextMenu { Button("Delete", role: .destructive) { model.delete(n.id) } }
                }
            }
            .toolbar { Button { model.newNote() } label: { Image(systemName: "square.and.pencil") }.help("New note") }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            RichTextEditor(text: model.loaded, token: model.loadToken, onChange: model.changed)
                .toolbar {
                    if let id = model.selected {
                        Menu {
                            let versions = model.store.versions(id)
                            if versions.isEmpty { Text("No earlier versions yet") }
                            ForEach(versions, id: \.self) { d in
                                Button(d.formatted(date: .abbreviated, time: .shortened)) { model.restore(d) }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Restore an earlier version")
                    }
                }
        }
    }
}

/// NSTextView wrapper: rich text with ⌘B/⌘I/⌘U, lists, links, images.
struct RichTextEditor: NSViewRepresentable {
    let text: NSAttributedString
    /// The content is replaced only when this changes.
    let token: Int
    let onChange: (NSAttributedString) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.delegate = context.coordinator
        tv.textStorage?.setAttributedString(text)
        context.coordinator.token = token
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard context.coordinator.token != token, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.token = token
        tv.textStorage?.setAttributedString(text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (NSAttributedString) -> Void
        var token = -1
        init(onChange: @escaping (NSAttributedString) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onChange(NSAttributedString(attributedString: tv.attributedString()))
        }
    }
}
