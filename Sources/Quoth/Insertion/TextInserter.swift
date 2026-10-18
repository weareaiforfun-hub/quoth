import AppKit
import ApplicationServices
import Carbon.HIToolbox
import QuothCore

/// Per-app paste behaviour. Built-in table + optional
/// ~/Library/Application Support/Quoth/app-overrides.json so fixes need no rebuild.
struct AppOverride: Codable {
    /// Seconds to wait before restoring the user's clipboard.
    var restoreDelay: Double?
    /// Paste in chunks of at most this many characters (terminal AI tools collapse long pastes).
    var chunkSize: Int?
    /// Strip list formatting etc. for terminals and AI chat apps.
    var preferRawFormatting: Bool?
}

enum AppOverrides {
    static let builtIn: [String: AppOverride] = {
        let terminal = AppOverride(restoreDelay: 0.8, chunkSize: 400, preferRawFormatting: true)
        let aiChat = AppOverride(preferRawFormatting: true)
        let slow = AppOverride(restoreDelay: 3)
        return [
            "com.apple.Terminal": terminal,
            "com.googlecode.iterm2": terminal,
            "dev.warp.Warp-Stable": terminal,
            "com.mitchellh.ghostty": terminal,
            "net.kovidgoyal.kitty": terminal,
            "io.alacritty": terminal,
            "com.openai.chat": aiChat,
            "com.anthropic.claudefordesktop": aiChat,
            "com.microsoft.Word": slow,
            "com.microsoft.Outlook": slow,
            "net.whatsapp.WhatsApp": slow,
            "com.microsoft.rdc.macos": AppOverride(restoreDelay: 5),
            "com.citrix.receiver.icaviewer.mac": AppOverride(restoreDelay: 5),
        ]
    }()

    static func lookup(_ bundleID: String?) -> AppOverride {
        guard let bundleID else { return AppOverride() }
        let url = AppPaths.support.appendingPathComponent("app-overrides.json")
        if let data = try? Data(contentsOf: url),
           let user = try? JSONDecoder().decode([String: AppOverride].self, from: data),
           let o = user[bundleID] {
            return o
        }
        return builtIn[bundleID] ?? AppOverride()
    }
}

enum InsertResult {
    case pasted
    case secureField
}

@MainActor
enum TextInserter {
    /// Pastes `text` into the focused field of the frontmost app, restoring the clipboard afterwards.
    static func insert(_ text: String, bundleID: String?) async -> InsertResult {
        // Only a password field blocks pasting. If Accessibility can't see the field (common in
        // Electron apps), paste anyway: a paste with no field is harmless, a refused paste is not.
        if focusedFieldState() == .secure { return .secureField }
        let o = AppOverrides.lookup(bundleID)
        let chunks = chunk(text, size: o.chunkSize)
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)

        for (i, part) in chunks.enumerated() {
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(part, forType: .string)
            // Ask clipboard managers not to record our temporary contents.
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.writeObjects([item])
            sendCommandV()
            if i < chunks.count - 1 { try? await Task.sleep(nanoseconds: 120_000_000) }
        }
        let ourChange = pb.changeCount
        let delay = o.restoreDelay ?? 0.5
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            // Only restore if nobody copied something new in the meantime.
            if pb.changeCount == ourChange { restorePasteboard(pb, snapshot) }
        }
        return .pasted
    }

    static func sendCommandV() {
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    static func sendCommandZ() {
        postKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
    }

    static func sendCommandA() {
        postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
    }

    static func sendReturn() {
        postKey(CGKeyCode(kVK_Return), flags: [])
    }

    /// The current selection: via Accessibility, else by copying (⌘C) and restoring the clipboard.
    static func selectedText() async -> String? {
        if let el = ContextCapture.focusedElement(of: NSWorkspace.shared.frontmostApplication),
           let sel: String = ContextCapture.attr(el, kAXSelectedTextAttribute) {
            return sel.isEmpty ? nil : sel
        }
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pb.changeCount != before { break }
        }
        let copied = pb.changeCount != before ? pb.string(forType: .string) : nil
        restorePasteboard(pb, snapshot)
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    enum FieldState { case editable, secure, unknown }

    /// Uses Accessibility to find the focused element.
    static func focusedFieldState() -> FieldState {
        guard let element = ContextCapture.focusedElement(of: NSWorkspace.shared.frontmostApplication) else { return .unknown }
        if string(element, kAXRoleAttribute) == "AXSecureTextField" || string(element, kAXSubroleAttribute) == "AXSecureTextField" {
            return .secure
        }
        return .editable
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func chunk(_ text: String, size: Int?) -> [String] {
        guard let size, text.count > size else { return [text] }
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + word.count + 1 > size, !current.isEmpty {
                out.append(current + " ")
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: clipboard snapshot

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshotPasteboard(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restorePasteboard(_ pb: NSPasteboard, _ snapshot: Snapshot) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
