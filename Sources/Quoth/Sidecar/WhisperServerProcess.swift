import Foundation
import QuothCore

/// Launches whisper.cpp's `whisper-server` on localhost and keeps it warm,
/// so the model is already loaded (and Metal kernels compiled) when you speak.
@MainActor
final class WhisperServerProcess {
    private var process: Process?
    private var wantRunning = false
    private(set) var port = 8178
    var onStatus: ((String) -> Void)?

    static func findBinary() -> String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(modelPath: String, port: Int) {
        self.port = port
        wantRunning = true
        Task { await launch(modelPath: modelPath) }
    }

    func stop() {
        wantRunning = false
        process?.terminate()
        process = nil
    }

    func restart(modelPath: String, port: Int) {
        stop()
        Task {
            // Give the old process time to release the port.
            try? await Task.sleep(nanoseconds: 800_000_000)
            start(modelPath: modelPath, port: port)
        }
    }

    private func launch(modelPath: String) async {
        let client = WhisperServerTranscriber(port: port)
        if await client.isReady() {
            // Something (e.g. a previous instance) already serves this port.
            onStatus?("Ready")
            return
        }
        guard let bin = Self.findBinary() else {
            onStatus?("whisper-server not found. Run scripts/setup.sh")
            return
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            onStatus?("Model missing. Run scripts/setup.sh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        let threads = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        p.arguments = ["-m", modelPath, "--host", "127.0.0.1", "--port", "\(port)", "-t", "\(threads)"]
        let log = AppPaths.support.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.wantRunning, self.process === proc else { return }
                self.onStatus?("Restarting…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.launch(modelPath: modelPath)
            }
        }
        do {
            try p.run()
        } catch {
            onStatus?("Failed to start: \(error.localizedDescription)")
            return
        }
        process = p
        onStatus?("Loading model…")
        for _ in 0..<120 {
            if await client.isReady() { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // Warm-up: the first inference compiles Metal kernels and is slow.
        onStatus?("Warming up…")
        _ = try? await client.transcribe(wav: WAVEncoder.encode([Float](repeating: 0, count: 16_000)), language: "en", prompt: nil)
        onStatus?("Ready")
    }
}
