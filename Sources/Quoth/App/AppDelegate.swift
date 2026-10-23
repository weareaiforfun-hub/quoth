import AppKit
import OSLog
import SwiftUI
import QuothCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState.shared
    let hotkeys = HotkeyMonitor()
    let whisper = EngineProcess(.whisper)
    let llama = EngineProcess(.llama)
    private var termSignal: DispatchSourceSignal?
    var earshot: EarshotController!
    var controller: DictationController!
    let scratchpad = ScratchpadController()
    var meetings: MeetingController!
    private var statusItem: NSStatusItem!
    private var hubWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        earshot = EarshotController(state: state)
        controller = DictationController(state: state, hotkeys: hotkeys, earshot: earshot)
        earshot.onOpenHub = { [weak self] in self?.openHub() }
        controller.onScratchpad = { [weak self] in self?.scratchpad.toggle() }
        controller.onNeedsSetup = { [weak self] in self?.openHub() }
        meetings = MeetingController(state: state, dictation: controller)
        meetings.onMessage = { [weak self] text, isError in self?.controller.showMessage(text, isError: isError) }
        meetings.onChange = { [weak self] in self?.updateStatusIcon() }
        applyHotkeySettings()
        hotkeys.trigger = state.settings.hotkey
        setUpStatusItem()

        whisper.onStatus = { [weak self] s in self?.state.whisperStatus = s }
        llama.onStatus = { [weak self] s in self?.state.textEngineStatus = s }
        startBackends()
        stopEnginesOnSIGTERM()
        Updater.shared.start()
        // A finished model download: start (or switch) the engines that were waiting for it.
        DownloadCenter.shared.onInstalled = { [weak self] _ in self?.startBackends() }
        DownloadCenter.shared.resumePendingBundle()

        state.onSettingsChanged = { [weak self] old in self?.settingsChanged(from: old) }
        installDebugHooks()
        // Wake up the accessibility tree of Electron/Chromium apps as soon as they come to the front.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ContextCapture.prepare(app) }
        }
        ContextCapture.prepare(NSWorkspace.shared.frontmostApplication)

        Logger(subsystem: "app.quoth", category: "permissions").info(
            "launch: accessibility=\(Permissions.accessibility) inputMonitoring=\(Permissions.inputMonitoring) microphone=\(Permissions.microphone.rawValue) screen=\(SystemAudioRecorder.hasPermission)")
        if Permissions.allGranted {
            startHotkeys()
        } else {
            openHub()
            waitForPermissions()
        }
        if !state.settings.missingLocalModels.isEmpty { openHub() }
    }

    /// `open Quoth.app` while it is running: show the Hub instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisper.stop()
        llama.stop()
    }

    /// `pkill Quoth` (and logout) sends SIGTERM, which skips applicationWillTerminate: stop the engines first.
    private func stopEnginesOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.whisper.stop()
                self?.llama.stop()
            }
            exit(0)
        }
        source.resume()
        termSignal = source
    }

    private func startBackends() {
        let s = state.settings
        if s.speechProvider == .local {
            whisper.start(modelPath: s.whisperModelPath, port: s.whisperPort)
        } else {
            whisper.stop()
            state.whisperStatus = "Cloud"
        }
        if s.textProvider == .local && s.localTextEngine == .builtIn {
            llama.start(modelPath: s.llamaModelPath, port: s.llamaPort)
        } else {
            llama.stop()
            state.textEngineStatus = s.textProvider == .cloud ? "Cloud" : "Ollama"
        }
        if s.textProvider == .local && s.localTextEngine == .ollama, let url = URL(string: s.ollamaBaseURL) {
            Task.detached { await OllamaCleaner(baseURL: url, model: s.ollamaModel).warmUp() }
        }
    }

    private func settingsChanged(from old: QuothCore.Settings) {
        let s = state.settings
        applyHotkeySettings()
        earshot.applySettings()
        let whisperChanged = s.whisperModelPath != old.whisperModelPath || s.whisperPort != old.whisperPort
        let llamaChanged = s.llamaModelPath != old.llamaModelPath || s.llamaPort != old.llamaPort
        if whisperChanged && s.speechProvider == .local {
            whisper.start(modelPath: s.whisperModelPath, port: s.whisperPort)
        }
        if llamaChanged && s.textProvider == .local && s.localTextEngine == .builtIn {
            llama.start(modelPath: s.llamaModelPath, port: s.llamaPort)
        }
        if s.speechProvider != old.speechProvider || s.textProvider != old.textProvider || s.localTextEngine != old.localTextEngine
            || s.ollamaModel != old.ollamaModel || s.ollamaBaseURL != old.ollamaBaseURL {
            startBackends()
        }
        if s.retention != old.retention { controller.reloadHistory() }
    }

    private func applyHotkeySettings() {
        let s = state.settings
        hotkeys.trigger = s.hotkey
        hotkeys.transformHotkeys = s.transformHotkeys
        hotkeys.scratchpadHotkey = s.scratchpadHotkey
        hotkeys.mouseDictateButton = s.mouseDictateButton
        hotkeys.mouseEnterButton = s.mouseEnterButton
    }

    private func startHotkeys() {
        if !hotkeys.start() {
            controller.showMessage("Couldn't listen for the hotkey. Check permissions", isError: true)
        }
    }

    /// Polls until the user grants permissions in System Settings, then starts listening.
    private func waitForPermissions() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.state.objectWillChange.send()
                if Permissions.accessibility && Permissions.inputMonitoring && !self.hotkeys.isRunning {
                    self.startHotkeys()
                }
                if Permissions.allGranted { t.invalidate() }
            }
        }
    }

    /// Only when `defaults write app.quoth debugHooks -bool true`: lets scripts drive the app for testing.
    private func installDebugHooks() {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("app.quoth.debug.dictate"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.object as? String else { return }
            MainActor.assumeIsolated { self?.controller.simulateDictation(wavPath: path) }
        }
        center.addObserver(forName: .init("app.quoth.debug.command"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.object as? String else { return }
            MainActor.assumeIsolated { self?.controller.simulateDictation(wavPath: path, command: true) }
        }
        // "lab" with "cleanup|tag1,tag2", "speech|file1,file2", "download|file", "bundle|lite": writes lab-report.json.
        // "pause|file" and "cancelbundle|-" act without a report.
        center.addObserver(forName: .init("app.quoth.debug.lab"), object: nil, queue: .main) { [weak self] n in
            guard let self, let parts = (n.object as? String)?.components(separatedBy: "|"), parts.count == 2 else { return }
            let items = parts[1].components(separatedBy: ",")
            let out = AppPaths.support.appendingPathComponent("lab-report.json")
            MainActor.assumeIsolated {
                let lab = ModelLab(state: self.state)
                Task { @MainActor in
                    var report: [String: Any] = ["kind": parts[0]]
                    switch parts[0] {
                    case "download", "bundle":
                        // Through DownloadCenter, like the UI; waits until finished, failed or paused.
                        let center = DownloadCenter.shared
                        let files: [DownloadItem]
                        if parts[0] == "bundle" {
                            guard let b = ModelBundle(rawValue: items[0]) else { return }
                            files = b.downloads
                            center.install(b)
                        } else {
                            let all = ModelCatalog.speech.map(\.download) + ModelCatalog.gguf.map(\.download)
                            guard let item = all.first(where: { $0.file == items[0] }) else { return }
                            files = [item]
                            center.enqueue(files)
                        }
                        let t = Date()
                        while files.contains(where: { center.isBusy($0.file) }) { try? await Task.sleep(nanoseconds: 300_000_000) }
                        report["seconds"] = Int(Date().timeIntervalSince(t))
                        report["files"] = files.map { f -> [String: Any] in
                            var r: [String: Any] = ["file": f.file, "installed": center.isInstalled(f)]
                            if let res = center.results[f.file] { r["resumedFrom"] = res.resumedFrom; r["alreadyInstalled"] = res.alreadyInstalled }
                            if let st = center.status[f.file] { r["status"] = st.detail }
                            return r
                        }
                        report["pendingBundle"] = center.pendingBundle?.rawValue ?? ""
                        report["llamaModelAfter"] = self.state.settings.llamaModelPath
                    case "pause":
                        DownloadCenter.shared.pause(items[0])
                        return
                    case "cancelbundle":
                        DownloadCenter.shared.cancelBundle()
                        return
                    case "speech":
                        await lab.runSpeech(models: items, useRecordings: false)
                        report["results"] = lab.speech.map { ["sample": $0.sample, "model": $0.model, "text": $0.text, "ms": $0.ms, "wer": $0.wer ?? -1] }
                    default:
                        await lab.runCleanup(models: items, quick: true, includeRecent: false)
                        report["summary"] = items.map { m -> [String: Any] in
                            let s = lab.summary(m)
                            return ["model": m, "cases": s.cases, "exact": s.exact, "sameWords": s.sameWords, "serious": s.serious, "p50ms": s.p50ms]
                        }
                    }
                    report["whisperModelAfter"] = self.state.settings.whisperModelPath
                    try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: out)
                }
            }
        }
        // "update": check the feed in the background and download + install silently (installs on quit).
        center.addObserver(forName: .init("app.quoth.debug.update"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let u = Updater.shared.updater else { return }
                u.automaticallyChecksForUpdates = true
                u.automaticallyDownloadsUpdates = true
                u.checkForUpdatesInBackground()
            }
        }
        // "diagnostics": what Copy Diagnostics would copy → diagnostics.txt
        center.addObserver(forName: .init("app.quoth.debug.diagnostics"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? DiagnosticsCollector.report(state: self.state)
                    .write(to: AppPaths.support.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
            }
        }
        // "quit": a normal quit, as from the menu (Sparkle installs a downloaded update then).
        center.addObserver(forName: .init("app.quoth.debug.quit"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        // "axprobe": what Accessibility sees in the frontmost app → ax-probe.json
        center.addObserver(forName: .init("app.quoth.debug.axprobe"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let app = NSWorkspace.shared.frontmostApplication
                let ctx = ContextCapture.capture()
                let role: String? = ctx.element.flatMap { ContextCapture.attr($0, kAXRoleAttribute) }
                let report: [String: Any] = ["app": app?.bundleIdentifier ?? "?", "found": ctx.element != nil,
                                             "role": role ?? "", "fieldChars": ctx.fieldText?.count ?? -1,
                                             "fieldState": "\(TextInserter.focusedFieldState())"]
                try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
                    .write(to: AppPaths.support.appendingPathComponent("ax-probe.json"))
            }
        }
        center.addObserver(forName: .init("app.quoth.debug.meeting"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.meetingAction() }
        }
        center.addObserver(forName: .init("app.quoth.debug.scratchpad"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scratchpad.toggle() }
        }
        center.addObserver(forName: .init("app.quoth.debug.transform"), object: nil, queue: .main) { [weak self] n in
            guard let num = (n.object as? String).flatMap(Int.init) else { return }
            MainActor.assumeIsolated { _ = Task { await self?.controller.runTransform(number: num) } }
        }
    }

    /// Quoth is a menu-bar app, but its own windows (Hub, Scratchpad) still need ⌘C/⌘V/⌘Z,
    /// which AppKit routes through the main menu's key equivalents.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        check.target = self
        appMenu.addItem(check)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Quoth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b").tag = 2
        edit.addItem(withTitle: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i").tag = 1
        edit.addItem(withTitle: "Underline", action: #selector(NSText.underline(_:)), keyEquivalent: "u")
        edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = 1
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quoth")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state.settings
        let header = NSMenuItem(title: "Hold \(s.hotkey.title) to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if s.speechProvider == .local {
            let ws = NSMenuItem(title: "Speech model: \(state.whisperStatus)", action: nil, keyEquivalent: "")
            ws.isEnabled = false
            menu.addItem(ws)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Quoth…", #selector(openHubAction)))
        menu.addItem(item("Paste Last Transcript  ⌃⌘V", #selector(pasteLastAction), enabled: state.last != nil || !state.history.isEmpty))
        menu.addItem(item("Undo AI Edit (paste raw)", #selector(undoAIAction), enabled: state.last != nil))
        menu.addItem(item("Scratchpad  ⌥S", #selector(scratchpadAction)))
        menu.addItem(item(meetings.isRecording ? "Stop Meeting Notes" : "Start Meeting Notes", #selector(meetingAction)))
        menu.addItem(.separator())

        let cleanup = NSMenuItem(title: "Auto Cleanup", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for level in CleanupLevel.allCases {
            let i = item(level.title, #selector(setLevelAction(_:)))
            i.representedObject = level.rawValue
            i.state = s.cleanupLevel == level ? .on : .off
            sub.addItem(i)
        }
        cleanup.submenu = sub
        menu.addItem(cleanup)

        let provider = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        for (kind, title) in [(ProviderKind.local, "Local (free, private)"), (.cloud, "Cloud (your API key)")] {
            let i = item(title, #selector(setProviderAction(_:)))
            i.representedObject = kind.rawValue
            i.state = s.speechProvider == kind && s.textProvider == kind ? .on : .off
            psub.addItem(i)
        }
        provider.submenu = psub
        menu.addItem(provider)
        menu.addItem(.separator())
        if Updater.shared.isAvailable { menu.addItem(item("Check for Updates…", #selector(checkForUpdatesAction))) }
        menu.addItem(item("Quit Quoth", #selector(quitAction), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openHubAction() { openHub() }
    @objc private func checkForUpdatesAction() { Updater.shared.checkForUpdates() }
    @objc private func scratchpadAction() { scratchpad.toggle() }
    @objc private func meetingAction() {
        Task { meetings.isRecording ? await meetings.stop() : await meetings.start() }
    }

    func updateStatusIcon() {
        let name = meetings?.isRecording == true ? "record.circle" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Quoth")
    }
    @objc private func pasteLastAction() { controller.pasteLast() }
    @objc private func undoAIAction() { controller.undoAIEdit() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func setLevelAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = CleanupLevel(rawValue: raw) { state.settings.cleanupLevel = l }
    }
    @objc private func setProviderAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = ProviderKind(rawValue: raw) { state.settings.provider = p }
    }

    // MARK: Hub window

    func openHub() {
        if hubWindow == nil {
            let view = HubView(state: state, controller: controller, meetings: meetings)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Quoth"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("QuothHub")
            hubWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }
}
