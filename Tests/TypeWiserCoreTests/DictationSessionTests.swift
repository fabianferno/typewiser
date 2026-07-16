import Foundation
import Testing
@testable import TypeWiserCore

final class FakeAudio: AudioCapturing, @unchecked Sendable {
    /// Default is 3 samples: well under the interim loop's 8000-sample
    /// (~0.5s) guard, so existing tests keep taking the sleep-and-retry
    /// branch unchanged. Tests exercising the interim *success* path swap
    /// this for a realistic buffer, e.g. `Array(repeating: 0, count: 16000)`.
    var samples: [Int16] = [1, 2, 3]
    /// When set, `start()` throws this instead of succeeding, simulating a
    /// microphone that's unavailable (permission denied, no input device, …).
    var startError: Error?
    var started = false, stopped = false
    func start() async throws {
        if let startError { throw startError }
        started = true
    }
    func stop() async { stopped = true }
    func currentSamples() async -> [Int16] { samples }
    func level() async -> Float { 0 }
}

final class FakeWhisper: Transcribing, @unchecked Sendable {
    var finalText = "let's meet at 2 actually 3"
    var finalError: Error?
    /// `tryTranscribe`'s return value. Default `nil` preserves the original
    /// fake's behavior (the interim loop always falls through to its
    /// sleep-and-retry branch); set to a real string to exercise the
    /// interim-success path that calls `emitInterim`.
    var interimText: String?
    var cancelCount = 0
    func transcribe(pcm16: [Int16]) async throws -> String {
        if let e = finalError { throw e }
        return finalText
    }
    func tryTranscribe(pcm16: [Int16]) async throws -> String? { interimText }
    func cancelInFlight() async { cancelCount += 1 }
}

/// Collects phases emitted onto a `DictationSession.phaseStream` so tests can
/// assert on them without racing the actor. Actor-isolated so it's safe to
/// mutate from the background consumer task while the test polls it.
private actor PhaseCollector {
    private(set) var phases: [SessionPhase] = []
    func record(_ phase: SessionPhase) { phases.append(phase) }
}

/// Bounded, non-flaky wait: polls `condition` until it returns true or
/// `timeout` elapses, then returns whatever the last check found. Unlike a
/// bare `for await` over an unbounded stream, this can never hang the test
/// suite — the loop is wall-clock bounded regardless of whether the
/// condition is ever satisfied.
private func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

struct FakeRewriter: Rewriter {
    let result: Result<String, RewriteError>
    func rewrite(_ t: String, options: RewriteOptions, context: RewriteContext) async throws -> String {
        try result.get()
    }
}

struct FakeContext: ContextReading {
    func read() -> RewriteContext { .empty }
}

private func makeSession(audio: FakeAudio = FakeAudio(),
                         whisper: FakeWhisper = FakeWhisper(),
                         rewriter: Rewriter = FakeRewriter(result: .success("Let's meet at 3.")),
                         pb: FakePasteboard = FakePasteboard(),
                         keys: FakeKeys = FakeKeys()) -> DictationSession {
    keys.pb = pb
    return DictationSession(
        audio: audio,
        whisper: whisper,
        rewriter: { rewriter },
        context: FakeContext(),
        injector: TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1)),
        options: { .default }
    )
}

@Test func happyPathInjectsRewrittenText() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(pb.log.contains("set:Let's meet at 3."))
    #expect(keys.sent == 1)
}

// Rule: never lose the user's words. ANY rewriter failure must degrade to
// the raw transcript and still emit `.inserted` — never `.error`. Covers all
// four `RewriteError` cases with identical (symmetric) assertions rather than
// four near-identical hand-written tests.
@Test(arguments: [
    RewriteError.unavailable,
    RewriteError.timedOut,
    RewriteError.badPayload,
    RewriteError.http(500),
])
func anyRewriterFailureStillInjectsRawTranscript(_ error: RewriteError) async {
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(rewriter: FakeRewriter(result: .failure(error)), pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(pb.log.contains("set:let's meet at 2 actually 3"),
            "never lose the user's words (error: \(error))")
    #expect(keys.sent == 1, "raw transcript must still be injected (error: \(error))")
}

@Test func whisperFailureInjectsNothing() async {
    let w = FakeWhisper(); w.finalError = WhisperError.http(503)
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(whisper: w, pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(keys.sent == 0)
    #expect(pb.log.isEmpty)
}

@Test func emptyTranscriptInjectsNothing() async {
    let w = FakeWhisper(); w.finalText = "   "
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(whisper: w, pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(keys.sent == 0)
}

@Test func endCancelsInFlightInterim() async {
    let w = FakeWhisper()
    let s = makeSession(whisper: w)
    await s.begin()
    await s.end()
    #expect(w.cancelCount >= 1, "the final pass must not queue behind an interim")
}

@Test func cancelInjectsNothing() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(pb: pb, keys: keys)
    await s.begin()
    await s.cancel()
    #expect(keys.sent == 0)
}

// MARK: - Interim loop success path (`emitInterim`)
//
// Every test above uses the default `FakeAudio.samples` (3 samples), which
// is well under the interim loop's `guard samples.count > 8000` line — so
// every one of them only ever exercises the sleep-and-retry branch. That
// left `emitInterim`, the call that actually drives the HUD while the user
// speaks, with zero coverage. This test gives `FakeAudio` a realistic 1s
// buffer and `FakeWhisper` a real interim string so the success branch
// actually runs, then proves the final `.inserted` phase still wins after
// `end()`.
//
// Hang-safety: `waitUntil` above is wall-clock bounded (2s default) and
// never awaits an unbounded stream directly — it only ever polls a
// snapshot of an actor-isolated array — so this test cannot hang even if
// the interim phase were never emitted. The background consumer task is
// cancelled in `defer`; because it isn't a structured child task, the test
// does not have to (and does not) await its completion, so a stream that
// never terminates cannot wedge the test either.
@Test func interimLoopEmitsRecordingWhileHeld() async {
    let audio = FakeAudio()
    audio.samples = Array(repeating: 0, count: 16000) // 1s @16kHz, comfortably over the 8000-sample guard
    let whisper = FakeWhisper()
    whisper.interimText = "meeting at three"
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(audio: audio, whisper: whisper, pb: pb, keys: keys)

    let collector = PhaseCollector()
    let stream = await s.phaseStream
    let consumer = Task {
        for await phase in stream {
            await collector.record(phase)
        }
    }
    defer { consumer.cancel() }

    await s.begin()

    let sawInterim = await waitUntil {
        await collector.phases.contains(.recording(interim: "meeting at three"))
    }
    #expect(sawInterim, "interim loop must emit .recording(interim:) once enough audio is buffered")

    await s.end()

    let sawInserted = await waitUntil {
        await collector.phases.contains(.inserted("Let's meet at 3."))
    }
    #expect(sawInserted, "the final rewrite must still win as .inserted after interim activity")
    #expect(pb.log.contains("set:Let's meet at 3."))
    #expect(keys.sent == 1)
}

// MARK: - begin()'s microphone-failure path

@Test func microphoneFailureEmitsErrorAndInjectsNothing() async {
    let audio = FakeAudio()
    audio.startError = AudioError.noInput
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(audio: audio, pb: pb, keys: keys)

    let collector = PhaseCollector()
    let stream = await s.phaseStream
    let consumer = Task {
        for await phase in stream {
            await collector.record(phase)
        }
    }
    defer { consumer.cancel() }

    await s.begin()

    let sawError = await waitUntil {
        await collector.phases.contains(.error("Microphone unavailable"))
    }
    #expect(sawError, "begin() must surface a microphone failure as .error")
    #expect(keys.sent == 0, "nothing should ever be injected when the mic never started")
    #expect(pb.log.isEmpty, "nothing should ever be injected when the mic never started")
}
