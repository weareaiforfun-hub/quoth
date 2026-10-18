// End-to-end test target: opens a window with a text view, has Quoth "dictate" a WAV into it,
// optionally edits the result (to exercise auto-learn), then prints the field's final text.
//
//   swift scripts/dev/e2e-target.swift <file.wav|N> [initial text] [--edit FROM=TO] [--wait seconds]
//        [--hook dictate|command|transform] [--select-all]
// Requires: defaults write app.quoth debugHooks -bool true (and Quoth restarted)
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
let wav = args.removeFirst()
var edit: (String, String)?
var wait = 8.0
if let i = args.firstIndex(of: "--edit") {
    let parts = args[i + 1].components(separatedBy: "=")
    edit = (parts[0], parts[1]); args.removeSubrange(i...i + 1)
}
if let i = args.firstIndex(of: "--wait") { wait = Double(args[i + 1])!; args.removeSubrange(i...i + 1) }
var hook = "dictate"
if let i = args.firstIndex(of: "--hook") { hook = args[i + 1]; args.removeSubrange(i...i + 1) }
var selectAll = false
if let i = args.firstIndex(of: "--select-all") { selectAll = true; args.remove(at: i) }
let initial = args.first ?? ""

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// ⌘V/⌘Z only work through menu key equivalents.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Quoth E2E"
let scroll = NSTextView.scrollableTextView()
let text = scroll.documentView as! NSTextView
text.string = initial
text.isRichText = false
text.isAutomaticQuoteSubstitutionEnabled = false
text.isAutomaticTextReplacementEnabled = false
text.isAutomaticSpellingCorrectionEnabled = false
text.allowsUndo = true
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(text)
text.setSelectedRange(selectAll ? NSRange(location: 0, length: (initial as NSString).length)
                                : NSRange(location: (initial as NSString).length, length: 0))
app.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    DistributedNotificationCenter.default().postNotificationName(.init("app.quoth.debug.\(hook)"), object: wav, userInfo: nil, deliverImmediately: true)
}
if let (from, to) = edit {
    // Correct the pasted text a little after it lands, like a user fixing a misheard name.
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        text.string = text.string.replacingOccurrences(of: from, with: to)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + wait + (edit == nil ? 0 : 10)) {
    print("FIELD<<\(text.string)>>")
    exit(0)
}
app.run()
