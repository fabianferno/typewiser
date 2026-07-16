import Foundation

/// Wraps raw PCM samples in a canonical 44-byte RIFF/WAVE container.
///
/// The whisper.cpp server accepts a file upload, not raw samples, so in-memory
/// capture buffers must be framed before they can be sent.
public enum WAVEncoder {
    public static func encode(pcm16: [Int16], sampleRate: Int = 16000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataBytes = pcm16.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var out = Data(capacity: 44 + dataBytes)

        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")

        ascii("fmt ")
        u32(16)                 // PCM fmt chunk size
        u16(1)                  // format = PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)

        ascii("data")
        u32(dataBytes)
        for sample in pcm16 {
            withUnsafeBytes(of: sample.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }
}
