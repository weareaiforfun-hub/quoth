import AVFoundation
import CoreMedia
import ScreenCaptureKit
import QuothCore

/// Records what the computer plays (the other meeting participants) via ScreenCaptureKit.
/// Needs the Screen & System Audio Recording permission; no video is kept.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: WAVFileWriter?
    private var startHostTime: Double = 0
    private let queue = DispatchQueue(label: "quoth.systemaudio")
    var onError: ((Error) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    func start(to url: URL, meetingStart: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw QuothError.notConfigured("No display to capture audio from") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = WAVEncoder.sampleRate
        config.channelCount = 1
        // Video is required by the API; keep it tiny and rare.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        writer = try WAVFileWriter(url: url)
        startHostTime = meetingStart
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        writer?.finish()
        writer = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let writer, sb.isValid else { return }
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = abl.mBuffers.mData else { return }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds - startHostTime
        writer.append(samples, at: max(0, t))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    /// Host-clock time (same clock as ScreenCaptureKit timestamps).
    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
