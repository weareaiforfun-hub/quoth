import AppKit
import ApplicationServices
import QuothCore

/// What we read about the target field at keydown, via the Accessibility tree only:
/// no screenshots, nothing from secure fields or denylisted apps.
struct CapturedContext {
    var app: NSRunningApplication?
    var windowTitle: String?
    var element: AXUIElement?
    var fieldText: String?
    var before: String?
    var after: String?
    var selectedText: String?
    var isSecure = false
}

@MainActor
enum ContextCapture {
    /// Password managers, banking and auth apps: never read context there.
    static let denylist: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.apple.Passwords", "com.authy.authy",
    ]

    static let charsAroundCursor = 1500

    /// Chromium browsers expose their accessibility tree when a client sets AXEnhancedUserInterface.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static var accessibilityEnabled: Set<pid_t> = []

    /// Electron apps (Claude, Slack, VS Code, Cursor, Discord, Notion…) and Chromium keep their
    /// accessibility tree off until an assistive app asks for it, so the focused text field is invisible
    /// to Accessibility. Ask once per process; call early (on app activation) so the tree is ready in time.
    static func prepare(_ app: NSRunningApplication?) {
        guard let app, !accessibilityEnabled.contains(app.processIdentifier),
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        accessibilityEnabled.insert(app.processIdentifier)
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let id = app.bundleIdentifier, chromiumBrowsers.contains(id) {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// The focused UI element: system-wide first, then via the app itself (enabling its
    /// accessibility tree if needed). Nil means Accessibility can't see it, not that there's no field.
    static func focusedElement(of app: NSRunningApplication?) -> AXUIElement? {
        if let el: AXUIElement = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) { return el }
        guard let app else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let el: AXUIElement = attr(appEl, kAXFocusedUIElementAttribute) { return el }
        let firstTime = !accessibilityEnabled.contains(app.processIdentifier)
        prepare(app)
        guard firstTime else { return nil }
        // The tree is built asynchronously after enabling; give it a moment (only the first time).
        for _ in 0..<5 {
            usleep(30_000)
            if let el: AXUIElement = attr(appEl, kAXFocusedUIElementAttribute) { return el }
        }
        return nil
    }

    static func capture() -> CapturedContext {
        var c = CapturedContext(app: NSWorkspace.shared.frontmostApplication)
        if let bid = c.app?.bundleIdentifier, denylist.contains(bid) { return c }
        if let pid = c.app?.processIdentifier {
            let appEl = AXUIElementCreateApplication(pid)
            if let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) {
                c.windowTitle = attr(win, kAXTitleAttribute)
            }
        }
        guard let el = focusedElement(of: c.app) else { return c }
        c.element = el
        let role: String? = attr(el, kAXRoleAttribute)
        let subrole: String? = attr(el, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            c.isSecure = true
            return c
        }
        c.selectedText = attr(el, kAXSelectedTextAttribute)
        if let value: String = attr(el, kAXValueAttribute) {
            c.fieldText = value
            let ns = value as NSString
            var cursor = ns.length
            var selLen = 0
            if let rangeValue: AXValue = attr(el, kAXSelectedTextRangeAttribute) {
                var r = CFRange()
                if AXValueGetValue(rangeValue, .cfRange, &r) {
                    cursor = max(0, min(ns.length, r.location))
                    selLen = max(0, min(ns.length - cursor, r.length))
                }
            }
            let start = max(0, cursor - charsAroundCursor)
            c.before = ns.substring(with: NSRange(location: start, length: cursor - start))
            let afterStart = cursor + selLen
            let afterLen = min(charsAroundCursor, ns.length - afterStart)
            c.after = afterLen > 0 ? ns.substring(with: NSRange(location: afterStart, length: afterLen)) : nil
        }
        return c
    }

    static func currentValue(of el: AXUIElement) -> String? { attr(el, kAXValueAttribute) }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return CFGetTypeID(v) == AXUIElementGetTypeID() ? (v as! T) : nil }
        if T.self == AXValue.self { return CFGetTypeID(v) == AXValueGetTypeID() ? (v as! T) : nil }
        return v as? T
    }
}
