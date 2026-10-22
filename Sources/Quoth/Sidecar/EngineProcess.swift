import Darwin
import Foundation
import QuothCore

/// Launches a local engine server on localhost and keeps it warm, so the model is already
/// loaded (and Metal kernels compiled) when you speak:
/// - `whisper-server` (whisper.cpp) for speech recognition,
/// - `llama-server` (llama.cpp) for the language model.
/// Both ship inside Quoth.app (`Contents/MacOS`); Homebrew builds are a fallback for development.
@MainActor
final class EngineProcess {
    struct Kind {
        let binary: String
        let arguments: (_ modelPath: String, _ port: Int) -> [String]
        /// True once the server on `port` has loaded `modelPath` and can answer.
        let isServing: (_ modelPath: String, _ port: Int) async -> Bool
        /// The first request compiles Metal kernels (and fills the prompt cache), so do it before the user speaks.
        let warmUp: (_ modelPath: String, _ port: Int) async -> Void
    }

    let kind: Kind
    private var process: Process?
    private var wantRunning = false
    /// Exits before the model finished loading, in a row; after a few, stop retrying and say so.
    private var failedStarts = 0
    private(set) var port = 0
    private var modelPath = ""
    /// Bumped by every start/stop, so a superseded launch gives up.
    private var generation = 0
    var onStatus: ((String) -> Void)?

    init(_ kind: Kind) { self.kind = kind }

    static func findBinary(_ name: String) -> String? {
        var candidates: [String] = []
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(dir.appendingPathComponent(name).path)
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts the server with this model, replacing one running with another model or port.
    /// Calling it again for what is already running (or starting) does nothing.
    func start(modelPath: String, port: Int) {
        if wantRunning && process != nil && self.modelPath == modelPath && self.port == port { return }
        let replacing = process != nil
        stop()
        self.modelPath = modelPath
        self.port = port
        wantRunning = true
        failedStarts = 0
        generation += 1
        let gen = generation
        Task {
            // Give the old process time to release the port.
            if replacing { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard gen == generation else { return }
            await launch(modelPath: modelPath)
        }
    }

    func stop() {
        wantRunning = false
        generation += 1
        guard let p = process else { return }
        p.terminate()
        process = nil
        // Only our own process's record: a leftover pid file still has to reach stopOrphans().
        try? FileManager.default.removeItem(at: pidFile)
    }

    private var pidFile: URL { AppPaths.support.appendingPathComponent("\(kind.binary).pid") }

    /// A previous Quoth that was force-quit leaves its server running, holding the port and maybe an old model.
    /// Found by the pid file it wrote, and, should that be gone, by being this app's engine with no parent left.
    private func stopOrphans() async {
        var pids: Set<pid_t> = []
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           Self.executablePath(pid).map({ ($0 as NSString).lastPathComponent == kind.binary }) == true {
            pids.insert(pid)
        }
        try? FileManager.default.removeItem(at: pidFile)
        if let ours = Self.findBinary(kind.binary) {
            pids.formUnion(Self.allPIDs().filter { Self.executablePath($0) == ours && Self.parentPID($0) == 1 })
        }
        for pid in pids { kill(pid, SIGTERM) }
        for _ in 0..<30 where pids.contains(where: { kill($0, 0) == 0 }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        if !pids.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }   // let the port go
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, n))))
    }

    private func launch(modelPath: String) async {
        let gen = generation
        guard wantRunning else { return }
        if process == nil { await stopOrphans() }
        guard gen == generation else { return }
        if await kind.isServing(modelPath, port) {
            // Something (e.g. a server started by hand) already serves this model on this port.
            onStatus?("Ready")
            return
        }
        guard let bin = Self.findBinary(kind.binary) else {
            onStatus?("Engine missing (\(kind.binary)). Reinstall Quoth.")
            return
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            onStatus?("Model not downloaded. Choose one in Models.")
            return
        }
        guard gen == generation, process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = kind.arguments(modelPath, port)
        let log = AppPaths.support.appendingPathComponent("\(kind.binary).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        var ready = false
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.wantRunning, self.process === proc else { return }
                self.process = nil
                if !ready { self.failedStarts += 1 }
                if self.failedStarts >= 3 {
                    self.onStatus?("Couldn't start. Details in \(log.lastPathComponent)")
                    return
                }
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
        try? "\(p.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)
        onStatus?("Loading model…")
        for _ in 0..<240 {
            if await kind.isServing(modelPath, port) { ready = true; break }
            guard p.isRunning else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard ready, process === p else { return }
        failedStarts = 0
        onStatus?("Warming up…")
        await kind.warmUp(modelPath, port)
        if process === p { onStatus?("Ready") }
    }
}

extension EngineProcess.Kind {
    static var threads: Int { max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)) }

    static let whisper = EngineProcess.Kind(
        binary: "whisper-server",
        arguments: { model, port in ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "-t", "\(threads)"] },
        isServing: { _, port in await WhisperServerTranscriber(port: port).isReady() },
        warmUp: { _, port in
            _ = try? await WhisperServerTranscriber(port: port)
                .transcribe(wav: WAVEncoder.encode([Float](repeating: 0, count: 16_000)), language: "en", prompt: nil)
        })

    /// One slot with a 16k context: dictation reuses the cached system prompt, and meeting summaries fit.
    static let llama = EngineProcess.Kind(
        binary: "llama-server",
        arguments: { model, port in
            ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "--alias", LlamaServer.alias(forModelPath: model),
             "-c", "16384", "-np", "1", "-ngl", "999", "-t", "\(threads)", "--no-webui", "--reasoning", "off"]
        },
        isServing: { model, port in await LlamaServer.loadedModel(port: port) == LlamaServer.alias(forModelPath: model) },
        warmUp: { model, port in
            _ = try? await LlamaServer.client(port: port, modelPath: model).clean("hello", level: .light, context: .init())
        })
}
