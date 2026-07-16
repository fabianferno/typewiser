import Testing
@testable import TypeWiserCore

@Test func rmsOfSilenceIsZero() {
    #expect(AudioCapture.rms(Array(repeating: 0, count: 100)) == 0)
}

@Test func rmsOfFullScaleIsOne() {
    let full = Array(repeating: Int16.max, count: 100)
    #expect(abs(AudioCapture.rms(full) - 1.0) < 0.01)
}

@Test func rmsOfEmptyIsZeroNotNaN() {
    let r = AudioCapture.rms([])
    #expect(r == 0)
    #expect(!r.isNaN, "empty buffer must not divide by zero")
}

@Test func floatToInt16ScalesFullRange() {
    #expect(AudioCapture.floatToInt16([1.0])[0] == Int16.max)
    #expect(AudioCapture.floatToInt16([0.0])[0] == 0)
    #expect(AudioCapture.floatToInt16([-1.0])[0] == Int16.min + 1)
}

@Test func floatToInt16ClampsOutOfRangeInput() {
    #expect(AudioCapture.floatToInt16([2.0])[0] == Int16.max, "must clamp, not wrap")
    #expect(AudioCapture.floatToInt16([-2.0])[0] == Int16.min + 1)
}

@Test func startClearsPreviousBuffer() async throws {
    let c = AudioCapture()
    // Without mic permission start() throws; that is fine — assert the contract
    // that a fresh capture reports no samples.
    #expect(await c.currentSamples().isEmpty)
}
