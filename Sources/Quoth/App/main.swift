import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // In the Dock and the menu bar. Dictation never activates Quoth (the Earshot pill is non-activating).
    app.setActivationPolicy(.regular)
    app.run()
}
