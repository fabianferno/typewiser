import Foundation
import Testing
@testable import TypeWiserCore

private func str(_ d: Data, _ r: Range<Int>) -> String {
    String(decoding: d[r], as: UTF8.self)
}

@Test func headerIsCanonical44ByteRIFF() {
    let data = WAVEncoder.encode(pcm16: [1, -1, 2, -2])
    #expect(data.count == 44 + 8)
    #expect(str(data, 0..<4) == "RIFF")
    #expect(str(data, 8..<12) == "WAVE")
    #expect(str(data, 12..<16) == "fmt ")
    #expect(str(data, 36..<40) == "data")
}

@Test func declaresMono16BitAt16kHz() {
    let data = WAVEncoder.encode(pcm16: [0, 0])
    // fmt chunk size 16, PCM format 1, 1 channel
    #expect(data[16] == 16 && data[17] == 0)
    #expect(data[20] == 1 && data[21] == 0)   // format = PCM
    #expect(data[22] == 1 && data[23] == 0)   // channels = 1
    // sampleRate 16000 = 0x3E80 little-endian
    #expect(data[24] == 0x80 && data[25] == 0x3E)
    // byteRate = 16000 * 2 = 32000 = 0x7D00
    #expect(data[28] == 0x00 && data[29] == 0x7D)
    #expect(data[32] == 2 && data[33] == 0)   // blockAlign
    #expect(data[34] == 16 && data[35] == 0)  // bitsPerSample
}

@Test func sizeFieldsMatchPayload() {
    let data = WAVEncoder.encode(pcm16: Array(repeating: 0, count: 100))
    let dataBytes = 200
    // data chunk size at offset 40 (all 4 bytes of the 32-bit little-endian field)
    #expect(data[40] == UInt8(dataBytes & 0xFF))
    #expect(data[41] == UInt8((dataBytes >> 8) & 0xFF))
    #expect(data[42] == UInt8((dataBytes >> 16) & 0xFF))
    #expect(data[43] == UInt8((dataBytes >> 24) & 0xFF))
    // RIFF size at offset 4 == 36 + dataBytes (all 4 bytes)
    let riffSize = 36 + dataBytes
    #expect(data[4] == UInt8(riffSize & 0xFF))
    #expect(data[5] == UInt8((riffSize >> 8) & 0xFF))
    #expect(data[6] == UInt8((riffSize >> 16) & 0xFF))
    #expect(data[7] == UInt8((riffSize >> 24) & 0xFF))
}

@Test func samplesAreLittleEndian() {
    let data = WAVEncoder.encode(pcm16: [0x0102, -2])
    #expect(data[44] == 0x02 && data[45] == 0x01)
    // -2 as UInt16 = 0xFFFE
    #expect(data[46] == 0xFE && data[47] == 0xFF)
}

@Test func emptyInputStillProducesValidHeader() {
    let data = WAVEncoder.encode(pcm16: [])
    #expect(data.count == 44)
    #expect(str(data, 0..<4) == "RIFF")
}

@Test func nonDefaultSampleRateIsReflectedInHeader() {
    let data = WAVEncoder.encode(pcm16: [0, 0], sampleRate: 8000)
    // sampleRate 8000 = 0x1F40 little-endian
    #expect(data[24] == 0x40 && data[25] == 0x1F && data[26] == 0 && data[27] == 0)
    // byteRate = 8000 * 1 channel * 2 bytes/sample = 16000 = 0x3E80
    #expect(data[28] == 0x80 && data[29] == 0x3E && data[30] == 0 && data[31] == 0)
}
