import AVFoundation
import AudioToolbox
import OSLog
import QuothCore

private let audioLog = Logger(subsystem: "app.quoth", category: "audio")

/// Captures 16 kHz mono Float audio from the chosen device, and streams a WAV
/// to disk while recording so a crash or quit never loses a dictation.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var currentDeviceID: AudioDeviceID?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let diskQueue = DispatchQueue(label: "quoth.audio.disk")
    private var file: FileHandle?
    private var fileBytes = 0
    private var configObserver: NSObjectProtocol?
    private var recentChanges: [Date] = []

    /// Called on the main queue with the RMS of each buffer.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the input device disappears mid-recording.
    var onDeviceLost: (() -> Void)?

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WAVEncoder.sampleRate),
                                       channels: 1, interleaved: false)!

    var isRecording: Bool { engine.isRunning }
    /// Off for long meeting recordings: audio only goes to disk, not memory.
    var keepInMemory = true

    /// Starts capture. Pass `keepSamples` when switching devices mid-dictation.
    func start(device: AudioInputDevice?, recordTo url: URL?, keepSamples: Bool = false) throws {
        if !keepSamples {
            lock.withLock { samples.removeAll(keepingCapacity: true) }
            openFile(url)
        }
        if let id = device?.id, id != currentDeviceID {
            // A fresh engine is the reliable way to switch the input device.
            engine = AVAudioEngine()
            var devID = id
            if let unit = engine.inputNode.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            currentDeviceID = id
        }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw QuothError.notConfigured("Microphone unavailable")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        observeConfigChanges()
        engine.prepare()
        try engine.start()
        audioLog.info("recording started: \(inFormat.sampleRate) Hz, \(inFormat.channelCount) ch, device \(device?.name ?? "default", privacy: .public)")
    }

    /// Stops capture and returns everything recorded.
    func stop() -> [Float] {
        teardown()
        closeFile()
        return lock.withLock { samples }
    }

    func cancel() {
        teardown()
        closeFile()
        lock.withLock { samples.removeAll() }
    }

    var duration: Double { lock.withLock { Double(samples.count) / Double(WAVEncoder.sampleRate) } }

    /// RMS over the first `seconds` of the recording (for the no-sound warning).
    func openingLevel(seconds: Double) -> Float {
        lock.withLock { AudioLevel.rms(samples.prefix(Int(seconds * Double(WAVEncoder.sampleRate)))) }
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    /// Re-registered on every start: a device switch creates a fresh engine, and the
    /// notification is posted per engine object.
    private func observeConfigChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            // Only rebuild the engine if our device actually went away; rebuilding when it's still
            // there triggers another configuration change (an endless loop).
            if let id = self.currentDeviceID, !MicrophoneManager.inputDevices().contains(where: { $0.id == id }) {
                self.currentDeviceID = nil
            }
            // Guard against rapid repeats.
            let now = Date()
            self.recentChanges = self.recentChanges.filter { now.timeIntervalSince($0) < 10 } + [now]
            audioLog.info("audio configuration changed (\(self.recentChanges.count) in 10 s)")
            guard self.recentChanges.count <= 5 else {
                audioLog.error("too many audio configuration changes; stopping")
                return
            }
            self.onDeviceLost?()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        if keepInMemory { lock.withLock { samples.append(contentsOf: chunk) } }
        writeToDisk(chunk)
        let level = AudioLevel.rms(chunk)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: crash-safe WAV on disk

    private func openFile(_ url: URL?) {
        diskQueue.sync {
            file = nil
            fileBytes = 0
            guard let url else { return }
            FileManager.default.createFile(atPath: url.path, contents: WAVEncoder.header(dataBytes: 0))
            file = try? FileHandle(forWritingTo: url)
            _ = try? file?.seekToEnd()
        }
    }

    private func writeToDisk(_ chunk: [Float]) {
        diskQueue.async { [weak self] in
            guard let self, let file = self.file else { return }
            let pcm = WAVEncoder.encode(chunk).dropFirst(44)
            try? file.write(contentsOf: pcm)
            self.fileBytes += pcm.count
        }
    }

    private func closeFile() {
        diskQueue.sync {
            guard let file else { return }
            try? file.seek(toOffset: 0)
            try? file.write(contentsOf: WAVEncoder.header(dataBytes: fileBytes))
            try? file.close()
            self.file = nil
        }
    }
}
