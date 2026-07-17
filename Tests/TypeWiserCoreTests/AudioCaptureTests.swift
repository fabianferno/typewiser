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

// Regression test for the bug where `AudioCapture.stop()` called
// `pump?.cancel()` instead of awaiting the pump's drain: chunks already
// yielded into the stream but not yet delivered to `append` were dropped,
// silently truncating the tail of whatever the user just said.
//
// This drives `ChunkPump` directly — the exact type `AudioCapture.start()`/
// `stop()` delegate to for this buffering — rather than `AudioCapture`
// itself, deliberately: `AudioCapture` wraps a real `AVAudioEngine`, and in
// this sandboxed test environment merely *referencing*
// `AVAudioEngine().inputNode` (which `AudioCapture.stop()` does
// unconditionally) hangs indefinitely with no microphone/audio hardware
// present — confirmed by timing out a minimal repro script. `ChunkPump`
// never touches `AVAudioEngine`, so it can be exercised with no mic and no
// risk of hanging the suite, while still being the real production code that
// runs on every `stop()`.
@Test func finishDrainsBufferedChunksInsteadOfDroppingThem() async {
    let pump = ChunkPump()
    let continuation = await pump.start()
    // Yielded synchronously, before `finish()` is ever called: `pump`'s drain
    // task cannot run at all until this test's next `await` returns control to
    // the scheduler (a freshly created `Task` never preempts synchronous code),
    // so every one of these is guaranteed to still be sitting undrained in the
    // stream the moment `finish()` runs — making the race deterministic rather
    // than a matter of luck.
    continuation.yield([1, 2, 3])
    continuation.yield([4, 5, 6])
    continuation.yield([7, 8, 9])

    await pump.finish()

    #expect(await pump.buffer == [1, 2, 3, 4, 5, 6, 7, 8, 9],
            "chunks already yielded before finish() must survive, not be dropped by a cancelled pump")
}
