import SwiftUI
import QuothCore

/// Setup page: choose a model bundle sized to this Mac, download it, and see when Quoth is ready.
struct ModelSetupSection: View {
    @ObservedObject var state: AppState
    @ObservedObject private var downloads = DownloadCenter.shared
    @State private var choice = ModelBundle.recommended(ramGB: ModelBundle.thisMacRAMGB)
    private let ramGB = ModelBundle.thisMacRAMGB

    var body: some View {
        Section("AI models") {
            if let bundle = downloads.pendingBundle {
                progress(bundle)
            } else if state.settings.speechProvider == .cloud && state.settings.textProvider == .cloud {
                Label("Using your cloud API for speech and text, so nothing to download.", systemImage: "cloud")
                modelsLink("Change in Models")
            } else if state.settings.missingLocalModels.isEmpty {
                ready
            } else {
                chooser
            }
        }
    }

    // MARK: states

    private var ready: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Models ready")
                Text(readyDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            modelsLink("Change")
        }
    }

    private var readyDetail: String {
        let s = state.settings
        let speech = s.speechProvider == .cloud ? "Cloud speech" : ModelCatalog.speechInfo(forPath: s.whisperModelPath)?.name ?? "Whisper"
        let allLocal = s.speechProvider == .local && s.textProvider == .local
        return "\(speech) + \(s.textModelName)." + (allLocal ? " Everything runs on this Mac." : "")
    }

    private var chooser: some View {
        Group {
            Text("Quoth needs two AI models: one turns your voice into text, the other tidies it up. They download once (from Hugging Face), then everything runs on this Mac, even offline.")
                .foregroundStyle(.secondary)
            ForEach(ModelBundle.allCases) { b in bundleRow(b) }
            let free = ResumableDownloader.freeSpace(AppPaths.support)
            let needed = choice.downloads.filter { !downloads.isInstalled($0) }.reduce(Int64(0)) { $0 + $1.bytes - downloads.partialBytes($1) }
            let enoughSpace = free.map { $0 >= needed + ResumableDownloader.spaceMargin } ?? true
            HStack {
                Button("Download \(DownloadError.size(needed))") { downloads.install(choice) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enoughSpace)
                if let free {
                    Text(enoughSpace ? "\(DownloadError.size(free)) free on this Mac"
                                     : "Not enough space: \(DownloadError.size(free)) free. Free up some space or pick a smaller option.")
                        .font(.caption).foregroundStyle(enoughSpace ? Color.secondary : Color.red)
                }
            }
            HStack(spacing: 4) {
                Text("Prefer a cloud service, or already use Ollama?").font(.caption).foregroundStyle(.secondary)
                modelsLink("Set it up in Models")
            }
        }
    }

    private func bundleRow(_ b: ModelBundle) -> some View {
        let recommended = b == ModelBundle.recommended(ramGB: ramGB)
        return Button { choice = b } label: {
            HStack(alignment: .top) {
                Image(systemName: choice == b ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == b ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(b.title) · \(DownloadError.size(b.bytes))")
                        if recommended {
                            Text("Recommended for this Mac").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    Text("\(b.speech.name.replacingOccurrences(of: " (default)", with: "")) + \(b.text.name). \(b.summary)")
                        .font(.caption).foregroundStyle(.secondary)
                    if ramGB < b.minRAMGB {
                        Text("Made for \(b.minRAMGB) GB of memory; this Mac has \(ramGB) GB, so it may be slow.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progress(_ bundle: ModelBundle) -> some View {
        Group {
            Text("Downloading the \(bundle.title) models (\(DownloadError.size(bundle.bytes))). You can close this window; the download carries on, and continues after a restart.")
                .foregroundStyle(.secondary)
            ForEach(bundle.downloads, id: \.file) { item in fileRow(item, name: name(of: item)) }
            HStack {
                let files = bundle.downloads.map(\.file)
                if files.contains(where: { downloads.isBusy($0) }) {
                    Button("Pause") { files.forEach(downloads.pause) }
                } else {
                    Button("Resume") { downloads.install(bundle) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Cancel") { downloads.cancelBundle() }
            }
        }
    }

    private func fileRow(_ item: DownloadItem, name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                Spacer()
                if downloads.isInstalled(item) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let s = downloads.status[item.file] {
                ProgressView(value: s.fraction)
                let failed: Bool = { if case .failed = s.phase { return true } else { return false } }()
                Text(s.detail).font(.caption.monospacedDigit()).foregroundStyle(failed ? Color.red : Color.secondary)
            } else if !downloads.isInstalled(item) {
                ProgressView(value: 0)
            }
        }
    }

    private func name(of item: DownloadItem) -> String {
        let n = ModelCatalog.speech.first { $0.file == item.file }?.name ?? ModelCatalog.gguf.first { $0.file == item.file }?.name ?? item.file
        return n.replacingOccurrences(of: " (default)", with: "")
    }

    private func modelsLink(_ title: String) -> some View {
        Button(title) { state.hubSection = HubSection.models.rawValue }.buttonStyle(.link)
    }
}
