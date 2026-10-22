import Foundation
import QuothCore

/// Model downloads for the whole app: one file at a time, resumable and SHA-256-checked.
/// Progress survives switching tabs or closing the Hub. A bundle chosen on the Setup page
/// is remembered, so after a quit or crash its download resumes at the next launch.
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()

    struct Status: Equatable {
        enum Phase: Equatable { case queued, downloading, verifying, paused, failed(String) }
        var phase: Phase
        var done: Int64
        var total: Int64
        var bytesPerSecond: Double = 0
        /// e.g. "Connection lost, retrying (2)…"
        var note: String?

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        var secondsLeft: Double? { bytesPerSecond > 0 ? Double(total - done) / bytesPerSecond : nil }
    }

    /// By file name; a file without a status is either installed or untouched.
    @Published private(set) var status: [String: Status] = [:]
    /// The bundle being installed from the Setup page.
    @Published private(set) var pendingBundle: ModelBundle?
    /// Called after a file is downloaded and verified (and after a bundle's settings are applied).
    var onInstalled: ((DownloadItem) -> Void)?
    /// Results of finished downloads (for the debug report).
    private(set) var results: [String: DownloadResult] = [:]

    private var queue: [DownloadItem] = []
    private var current: (item: DownloadItem, downloader: ResumableDownloader)?
    private var lastSample: (time: Date, bytes: Int64)?
    private static let pendingKey = "pendingModelBundle"

    private init() {}

    // MARK: files

    func enqueue(_ items: [DownloadItem]) {
        for item in items where !isInstalled(item) && !queue.contains(item) && current?.item != item {
            queue.append(item)
            status[item.file] = Status(phase: .queued, done: partialBytes(item), total: item.bytes)
        }
        pump()
    }

    /// Stops a download but keeps what has arrived; `enqueue` resumes it.
    func pause(_ file: String) {
        if let i = queue.firstIndex(where: { $0.file == file }) {
            queue.remove(at: i)
            status[file]?.phase = .paused
        }
        if current?.item.file == file { current?.downloader.cancel() }
    }

    func isInstalled(_ item: DownloadItem) -> Bool {
        ResumableDownloader.fileSize(AppPaths.models.appendingPathComponent(item.file)) == item.bytes
    }

    func partialBytes(_ item: DownloadItem) -> Int64 {
        ResumableDownloader.fileSize(ResumableDownloader.partURL(for: item, in: AppPaths.models)) ?? 0
    }

    func isBusy(_ file: String) -> Bool {
        switch status[file]?.phase {
        case .queued, .downloading, .verifying: true
        default: false
        }
    }

    // MARK: bundles

    func install(_ bundle: ModelBundle) {
        pendingBundle = bundle
        UserDefaults.standard.set(bundle.rawValue, forKey: Self.pendingKey)
        enqueue(bundle.downloads)
        finishBundleIfReady()
    }

    /// Stops the bundle's downloads and deletes their partial files.
    func cancelBundle() {
        guard let b = pendingBundle else { return }
        pendingBundle = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        for item in b.downloads where !isInstalled(item) {
            pause(item.file)
            status[item.file] = nil
            // Our own half-downloaded file in Quoth's models folder.
            try? FileManager.default.removeItem(at: ResumableDownloader.partURL(for: item, in: AppPaths.models))
        }
    }

    /// At launch: continue a bundle download that a quit or crash interrupted.
    func resumePendingBundle() {
        guard let raw = UserDefaults.standard.string(forKey: Self.pendingKey), let b = ModelBundle(rawValue: raw) else { return }
        install(b)
    }

    private func finishBundleIfReady() {
        guard let b = pendingBundle, b.downloads.allSatisfy(isInstalled) else { return }
        pendingBundle = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        AppState.shared.settings.use(b)
    }

    // MARK: worker

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        let downloader = ResumableDownloader()
        current = (item, downloader)
        status[item.file] = Status(phase: .downloading, done: partialBytes(item), total: item.bytes)
        lastSample = nil
        Task {
            do {
                let r = try await downloader.download(item, into: AppPaths.models) { [weak self] e in
                    Task { @MainActor in self?.handle(e, for: item.file) }
                }
                results[item.file] = r
                status[item.file] = nil
                finishBundleIfReady()
                onInstalled?(item)
            } catch DownloadError.cancelled {
                status[item.file]?.phase = .paused
            } catch {
                status[item.file]?.phase = .failed(error.localizedDescription)
            }
            current = nil
            pump()
        }
    }

    private func handle(_ e: DownloadEvent, for file: String) {
        guard var s = status[file], current?.item.file == file else { return }
        switch e {
        case .progress(let done, let total):
            let now = Date()
            if let last = lastSample, now.timeIntervalSince(last.time) > 0.5 {
                let rate = Double(done - last.bytes) / now.timeIntervalSince(last.time)
                if rate >= 0 { s.bytesPerSecond = s.bytesPerSecond == 0 ? rate : 0.8 * s.bytesPerSecond + 0.2 * rate }
                lastSample = (now, done)
            } else if lastSample == nil {
                lastSample = (now, done)
            }
            s.done = done
            s.total = total
            if s.phase == .queued { s.phase = .downloading }
            if done > 0 && s.note != nil && s.phase == .downloading { s.note = nil }
        case .retrying(let attempt, _):
            s.note = "Connection lost, retrying (\(attempt))…"
            s.bytesPerSecond = 0
            lastSample = nil
        case .verifying:
            s.phase = .verifying
            s.note = nil
        }
        status[file] = s
    }
}

extension DownloadCenter.Status {
    /// "1.2 GB of 9.0 GB · 45 MB/s · about 3 min left"
    var detail: String {
        switch phase {
        case .queued: return "Waiting"
        case .verifying: return "Checking the file…"
        case .paused: return "Paused at \(DownloadError.size(done)) of \(DownloadError.size(total))"
        case .failed(let message): return message
        case .downloading:
            if let note { return note }
            var parts = ["\(DownloadError.size(done)) of \(DownloadError.size(total))"]
            if bytesPerSecond > 0 { parts.append("\(DownloadError.size(Int64(bytesPerSecond)))/s") }
            if let left = secondsLeft { parts.append(Self.timeLeft(left)) }
            return parts.joined(separator: " · ")
        }
    }

    static func timeLeft(_ s: Double) -> String {
        s < 60 ? "less than a minute left" : s < 3600 ? "about \(Int((s / 60).rounded())) min left"
            : String(format: "about %.1f h left", s / 3600)
    }
}
