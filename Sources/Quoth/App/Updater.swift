import AppKit
import Sparkle

/// Automatic updates with Sparkle. The appcast is attached to each GitHub release and every update is
/// EdDSA-signed with the project's own key (no Apple account involved). Sparkle also requires the new
/// app to carry the same code signature as the installed one, so only "Quoth Dev"-signed builds install.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Only an app bundle with a feed and public key configured updates itself (not `swift run`).
    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app", info["SUFeedURL"] != nil,
              !((info["SUPublicEDKey"] as? String) ?? "").isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    var updater: SPUUpdater? { controller?.updater }

    /// "Check for Updates…": shows Sparkle's window with the result.
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Testing only (with the debug hooks on): read the appcast from another URL, e.g. a local server.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let d = UserDefaults.standard
        return d.bool(forKey: "debugHooks") ? d.string(forKey: "debugFeedURL") : nil
    }
}
