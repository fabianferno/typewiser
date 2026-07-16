import Foundation
import Testing
@testable import TypeWiserCore

final class FakeAudio: AudioCapturing, @unchecked Sendable {
    var samples: [Int16] = [1, 2, 3]
    var started = false, stopped = false
    func start() async throws { started = true }
    func stop() async { stopped = true }
    func currentSamples() async -> [Int16] { samples }
    func level() async -> Float { 0 }
}

final class FakeWhisper: Transcribing, @unchecked Sendable {
    var finalText = "let's meet at 2 actually 3"
    var finalError: Error?
    var cancelCount = 0
    func transcribe(pcm16: [Int16]) async throws -> String {
        if let e = finalError { throw e }
        return finalText
    }
    func tryTranscribe(pcm16: [Int16]) async throws -> String? { nil }
    func cancelInFlight() async { cancelCount += 1 }
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

private func makeSession(whisper: FakeWhisper = FakeWhisper(),
                         rewriter: Rewriter = FakeRewriter(result: .success("Let's meet at 3.")),
                         pb: FakePasteboard = FakePasteboard(),
                         keys: FakeKeys = FakeKeys()) -> DictationSession {
    keys.pb = pb
    return DictationSession(
        audio: FakeAudio(),
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

@Test func rewriterFailureStillInjectsRawTranscript() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(rewriter: FakeRewriter(result: .failure(.unavailable)), pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(pb.log.contains("set:let's meet at 2 actually 3"),
            "never lose the user's words")
    #expect(keys.sent == 1)
}

@Test func rewriterTimeoutStillInjectsRawTranscript() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    let s = makeSession(rewriter: FakeRewriter(result: .failure(.timedOut)), pb: pb, keys: keys)
    await s.begin()
    await s.end()
    #expect(pb.log.contains("set:let's meet at 2 actually 3"))
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
