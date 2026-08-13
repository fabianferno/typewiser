import Foundation
import Testing
@testable import TypeWiserCore

final class FakeAudio: AudioCapturing, @unchecked Sendable {
    /// Default sits in the window between `DictationSession`'s too-short guard
    /// (4000 samples — below it `end()` just pings and stops) and the interim
    /// loop's 8000-sample (~0.5s) guard, so tests reach the full transcribe
    /// path while still taking the interim sleep-and-retry branch. Tests
    /// exercising the interim *success* path swap this for a longer buffer,
    /// e.g. `Array(repeating: 0, count: 16000)`.
    var samples: [Int16] = Array(repeating: 3, count: 4_000)
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
    /// Artificial delay before `tryTranscribe` resolves, simulating an
    /// interim request that is still in flight when `end()`/`cancel()` runs.
    /// Used by `lateInterimAfterEndDoesNotReappearAfterTranscribing` to prove
    /// such a call can't resurrect `.recording(interim:)` after the session
    /// has already moved past it.
    var interimDelay: Duration = .zero
    var cancelCount = 0
    func transcribe(pcm16: [Int16]) async throws -> String {
        if let e = finalError { throw e }
        return finalText
    }
    func tryTranscribe(pcm16: [Int16]) async throws -> String? {
        if interimDelay > .zero {
            try? await Task.sleep(for: interimDelay)
        }
        return interimText
    }
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

/// Rewriter that records every `RewriteContext` it was handed, in addition
/// to producing a fixed result. Used to prove `DictationSession` passes the
/// factory's CURRENT output through to the rewriter on each cycle, not a
/// value captured once. `@unchecked Sendable` class like `FakeAudio`/
/// `FakeWhisper` above: mutated only from the sequentially-awaited
/// begin()/end() calls in a single test, never concurrently.
final class RecordingRewriter: Rewriter, @unchecked Sendable {
    let result: Result<String, RewriteError>
    private(set) var receivedContexts: [RewriteContext] = []

    init(result: Result<String, RewriteError> = .success("ok")) {
        self.result = result
    }

    func rewrite(_ t: String, options: RewriteOptions, context: RewriteContext) async throws -> String {
        receivedContexts.append(context)
        return try result.get()
    }
}

/// A `ContextReading` that always reads back whatever `value` was at
/// construction. Paired with `FakeContextFactory` below so each factory
/// invocation can hand back a different, independent snapshot.
private struct ClosureContext: ContextReading {
    let value: RewriteContext
    func read() -> RewriteContext { value }
}

/// Counts how many times its `make()` factory method is invoked and lets a
/// test change what it vends between calls. This is the crux of the
/// regression test for the `context:` factory fix: `AXContextReader`
/// captures `nameDictionary` at construction, so `DictationSession` must
/// call the factory FRESH on every `end()` rather than reuse one instance
/// captured at `init` — otherwise a name added in Settings mid-session would
/// never reach the rewriter without an app restart.
final class FakeContextFactory: @unchecked Sendable {
    private(set) var callCount = 0
    var current: RewriteContext = .empty

    func make() -> ContextReading {
        callCount += 1
        return ClosureContext(value: current)
    }
}

private func makeSession(audio: FakeAudio = FakeAudio(),
                         whisper: FakeWhisper = FakeWhisper(),
                         rewriter: Rewriter = FakeRewriter(result: .success("Let's meet at 3.")),
                         pb: FakePasteboard = FakePasteboard(),
                         keys: FakeKeys = FakeKeys(),
                         tooShortSound: SoundPlaying? = nil) -> DictationSession {
    keys.pb = pb
    return DictationSession(
        audio: audio,
        whisper: whisper,
        rewriter: { rewriter },
        context: { FakeContext() },
        injector: TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil),
        options: { .default },
        tooShortSound: tooShortSound
    )
}

/// Tapping the hotkey instead of holding it captures nothing worth
/// transcribing. The session must say so audibly and stop before spending a
/// transcription round-trip on a quarter-second of nothing.
@Test func releasingTooQuicklyPingsAndSkipsTranscription() async {
    let audio = FakeAudio(), whisper = FakeWhisper(), sound = FakeSound()
    let pb = FakePasteboard()
    audio.samples = Array(repeating: 3, count: 100)
    let s = makeSession(audio: audio, whisper: whisper, pb: pb, tooShortSound: sound)
    await s.begin()
    await s.end()
    #expect(sound.plays == 1)
    #expect(!pb.log.contains { $0.hasPrefix("set:") }, "nothing should be pasted")
}

@Test func normalDictationDoesNotPing() async {
    let sound = FakeSound()
    let s = makeSession(tooShortSound: sound)
    await s.begin()
    await s.end()
    #expect(sound.plays == 0)
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

// MARK: - Finding 4: a late interim result must not resurrect `.recording`
// after `end()` has moved on
//
// The interim loop only checked `Task.isCancelled` at the top of its `while`
// loop. If an iteration was already awaiting `tryTranscribe` when `end()`
// cancelled the loop, that in-flight call still ran to completion and still
// called `emitInterim` once it resolved — landing during `end()`'s own
// `await whisper.transcribe(...)` and flipping the HUD from "Transcribing…"
// back to red "Listening" for however long that stale call took. This test
// reproduces exactly that shape with `FakeWhisper.interimDelay`, then proves
// the fix (the `isEnding` flag checked inside `emitInterim`) means no
// `.recording` phase can appear after `.transcribing`, and the final phase
// is still `.inserted`.
@Test func lateInterimAfterEndDoesNotReappearAfterTranscribing() async {
    let audio = FakeAudio()
    audio.samples = Array(repeating: 0, count: 16000) // over the 8000-sample guard
    let whisper = FakeWhisper()
    whisper.interimText = "stale interim"
    whisper.interimDelay = .milliseconds(300) // still in flight when end() cancels
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(audio: audio, whisper: whisper, pb: pb, keys: keys)

    let collector = PhaseCollector()
    let stream = await s.phaseStream
    let consumer = Task {
        for await phase in stream { await collector.record(phase) }
    }
    defer { consumer.cancel() }

    await s.begin()
    // Give the interim loop a moment to actually be inside tryTranscribe's
    // artificial delay before end() cancels it out from under it.
    try? await Task.sleep(for: .milliseconds(50))
    await s.end()

    // Wait well past interimDelay so the stale tryTranscribe call has had
    // time to resolve and (pre-fix) reach emitInterim.
    try? await Task.sleep(for: .milliseconds(500))

    let phases = await collector.phases
    #expect(phases.last == .inserted("Let's meet at 3."),
            "end() must have the final word — no stale interim after it: \(phases)")

    if let transcribingIndex = phases.firstIndex(of: .transcribing) {
        let after = phases[(transcribingIndex + 1)...]
        let sawStaleRecording = after.contains { phase in
            if case .recording = phase { return true }
            return false
        }
        #expect(!sawStaleRecording, "no .recording phase may appear after .transcribing: \(phases)")
    } else {
        Issue.record(".transcribing was never emitted: \(phases)")
    }
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

// MARK: - `context:` factory freshness
//
// `DictationSession.init` takes `context: @escaping @Sendable () ->
// ContextReading` — a factory — specifically so `AppModel` can pass
// `{ AXContextReader(nameDictionary: settings.nameDictionary) }` and have
// each dictation cycle see the LATEST name dictionary. `AXContextReader`
// captures `nameDictionary` at construction, so a frozen `ContextReading`
// instance (the pre-fix shape) would freeze the dictionary at whatever it
// was when the session was built, requiring an app restart for a newly
// added name to take effect. This test fails if `context:` is ever reverted
// to a frozen instance: it asserts both that the factory is invoked once
// per cycle (not once ever) and that the rewriter receives the factory's
// CURRENT output on the second cycle, not the first cycle's snapshot.
//
// The factory is invoked from `begin()`, not `end()` — the read is a
// blocking AX call kept off the post-release critical path (see
// `DictationSession.capturedContext`). Per-cycle freshness is unaffected:
// a name added in Settings still takes effect on the very next dictation.
@Test func contextFactoryIsInvokedFreshEachCycle() async {
    let factory = FakeContextFactory()
    factory.current = RewriteContext(nameDictionary: ["Ada"])
    let rewriter = RecordingRewriter()
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = DictationSession(
        audio: FakeAudio(),
        whisper: FakeWhisper(),
        rewriter: { rewriter },
        context: { factory.make() },
        injector: TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil),
        options: { .default }
    )

    await s.begin()
    await s.end()

    // Change what the factory vends *between* cycles, mimicking a user
    // adding a name in Settings mid-session.
    factory.current = RewriteContext(nameDictionary: ["Grace"])

    await s.begin()
    await s.end()

    #expect(factory.callCount == 2, "the factory must be invoked once per cycle, not captured once at init")
    #expect(rewriter.receivedContexts.count == 2)
    #expect(rewriter.receivedContexts.first?.nameDictionary == ["Ada"],
            "the first cycle should see the factory's output at that time")
    #expect(rewriter.receivedContexts.last?.nameDictionary == ["Grace"],
            "the second cycle must see the UPDATED factory output, not a value frozen at session construction")
}

/// `ContextReading.read()` is a blocking Accessibility round-trip that can
/// stall for hundreds of ms in Electron/JVM hosts. Read from `end()` it sits
/// on the critical path, between the user releasing the key and their text
/// appearing; read from `begin()` it overlaps with them still speaking and is
/// free. Nothing it reads (focused element, frontmost app) changes during a
/// hold, so this costs nothing to move. Fails if it is ever moved back.
@Test func contextIsReadAtBeginNotOnThePostReleaseCriticalPath() async {
    let factory = FakeContextFactory()
    factory.current = RewriteContext(nameDictionary: ["Ada"])
    let rewriter = RecordingRewriter()
    let s = DictationSession(
        audio: FakeAudio(),
        whisper: FakeWhisper(),
        rewriter: { rewriter },
        context: { factory.make() },
        injector: TextInjector(pasteboard: FakePasteboard(), keys: FakeKeys(), restoreDelay: .milliseconds(1), sound: nil),
        options: { .default }
    )

    await s.begin()
    #expect(factory.callCount == 1, "the AX read must already have happened by the end of begin()")

    await s.end()
    #expect(factory.callCount == 1, "end() must reuse the context captured at begin(), never re-read it")
    #expect(rewriter.receivedContexts.first?.nameDictionary == ["Ada"],
            "the context captured at begin() must be the one handed to the rewriter")
}
