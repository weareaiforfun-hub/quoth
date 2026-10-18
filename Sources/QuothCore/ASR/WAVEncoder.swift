import Foundation

public enum WAVEncoder {
    public static let sampleRate = 16_000

    /// Encodes mono Float samples in [-1, 1] as 16-bit PCM WAV.
    public static func encode(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        return header(dataBytes: pcm.count, sampleRate: sampleRate) + pcm
    }

    /// A 44-byte canonical WAV header for 16-bit mono PCM.
    public static func header(dataBytes: Int, sampleRate: Int = sampleRate) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append("RIFF")
        u32(UInt32(36 + dataBytes))
        d.append("WAVEfmt ")
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)
        d.append("data")
        u32(UInt32(dataBytes))
        return d
    }

    /// Decodes a 16-bit mono WAV produced by `encode` (used to retry from History).
    public static func decode(_ data: Data) -> [Float]? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        let pcm = data.dropFirst(44)
        var out = [Float]()
        out.reserveCapacity(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            let n = raw.count / 2
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out.append(Float(v) / Float(Int16.max))
            }
        }
        return out
    }
}
