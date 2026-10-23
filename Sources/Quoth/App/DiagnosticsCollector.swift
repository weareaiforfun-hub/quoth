import AppKit
import QuothCore

/// Gathers what "Copy diagnostics" reports (see `Diagnostics`), and opens a GitHub issue for a problem report.
@MainActor
enum DiagnosticsCollector {
    static let issuesURL = URL(string: "https://github.com/weareaiforfun-hub/quoth/issues/new")!

    static func report(state: AppState) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let downloads = DownloadCenter.shared.status.map { "\($0.key): \($0.value.detail)" }.sorted()
        let logs = ["whisper-server.log", "llama-server.log"].map { name in
            (name: name, text: tail(AppPaths.support.appendingPathComponent(name)))
        }
        let input = DiagnosticsInput(
            appVersion: Updater.shared.version,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            hardware: sysctl("hw.model") ?? "Mac",
            ramGB: ModelBundle.thisMacRAMGB,
            freeDiskBytes: ResumableDownloader.freeSpace(AppPaths.support),
            settings: state.settings,
            speechStatus: state.whisperStatus,
            textStatus: state.textEngineStatus,
            permissions: [("Microphone", Permissions.microphone == .authorized), ("Accessibility", Permissions.accessibility),
                          ("Input Monitoring", Permissions.inputMonitoring), ("Screen & System Audio", SystemAudioRecorder.hasPermission)],
            downloads: downloads,
            logs: logs)
        return Diagnostics.report(input)
    }

    static func copy(state: AppState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(state: state), forType: .string)
    }

    /// Copies the diagnostics and opens a new GitHub issue, whose text asks the user to paste them.
    /// Nothing is put in the URL but the fixed template, and nothing is sent until the user submits.
    static func reportProblem(state: AppState) {
        copy(state: state)
        let body = """
        **What happened?**


        **What did you expect?**


        **Diagnostics** (Quoth copied them to your clipboard: paste here with ⌘V, and check them first)

        """
        var c = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Opens a new email to the developer, with the diagnostics in it. Apple Mail is the default for
    /// email links even when no account is set up in it (common for people who use Gmail in a browser),
    /// so with Mail as the default, Quoth asks first and offers to copy the address and details instead.
    static func emailDeveloper(state: AppState) {
        let diagnostics = report(state: state)
        guard let url = Feedback.mailURL(diagnostics: diagnostics) else { return }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        if let handler, handler.lastPathComponent != "Mail.app", NSWorkspace.shared.open(url) { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Email the developer"
        alert.informativeText = """
        Write to \(Feedback.address). Quoth adds technical details (never what you dictated), and nothing is sent until you press Send.

        Use Apple Mail, or copy the address and details to write from Gmail or another email service.
        """
        alert.addButton(withTitle: handler == nil ? "Copy Address and Details" : "Open in Mail")
        if handler != nil { alert.addButton(withTitle: "Copy Address and Details") }
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        if handler != nil && choice == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        } else if choice == (handler == nil ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("To: \(Feedback.address)\nSubject: \(Feedback.subject)\n\n" + Feedback.body(diagnostics: diagnostics), forType: .string)
        }
    }

    /// The last 200 KB of a log file.
    private static func tail(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
