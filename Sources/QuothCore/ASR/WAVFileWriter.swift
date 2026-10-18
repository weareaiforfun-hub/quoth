import Foundation

/// Streams 16 kHz mono Float audio to a WAV file. Writes are placed by timestamp, so gaps
/// in delivery (e.g. no system audio playing) become silence and the timeline stays true.
public final class WAVFileWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var samplesWritten = 0
    private let sampleRate: Int

    public init(url: URL, sampleRate: Int = WAVEncoder.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: WAVEncoder.header(dataBytes: 0, sampleRate: sampleRate))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Appends samples. With `at` (seconds since the recording started), pads silence up to that point.
    public func append(_ samples: [Float], at time: Double? = nil) {
        lock.withLock {
            if let time {
                let target = Int(time * Double(sampleRate))
                let gap = target - samplesWritten
                // Fill gaps longer than ~20 ms; ignore tiny jitter.
                if gap > sampleRate / 50 {
                    try? handle.write(contentsOf: Data(count: gap * 2))
                    samplesWritten += gap
                }
            }
            try? handle.write(contentsOf: WAVEncoder.encode(samples, sampleRate: sampleRate).dropFirst(44))
            samplesWritten += samples.count
        }
    }

    public var duration: Double { lock.withLock { Double(samplesWritten) / Double(sampleRate) } }

    /// Writes the final header. Safe to call more than once.
    public func finish() {
        lock.withLock {
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: WAVEncoder.header(dataBytes: samplesWritten * 2, sampleRate: sampleRate))
            try? handle.seekToEnd()
            try? handle.synchronize()
        }
    }

    deinit { try? handle.close() }
}
