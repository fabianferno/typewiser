import Foundation
import Testing
@testable import TypeWiserCore

/// Pure-function tests for the audio splitting that keeps long dictations from
/// being truncated by `SFSpeechRecognizer`. The recognizer itself needs real
/// hardware and a granted TCC permission, so `AppleSpeechTranscriber` keeps its
/// decisions here where they can be tested without either.
struct SpeechChunkingTests {
    private let rate = 16_000

    /// Loud enough to clear the silence threshold; alternating sign so the RMS
    /// of any window is the amplitude itself rather than a DC offset.
    private func speech(seconds: Double, amplitude: Int16 = 8_000) -> [Int16] {
        (0..<Int(Double(rate) * seconds)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(Double(rate) * seconds))
    }

    // MARK: - segments

    @Test func shortAudioStaysOneSegment() {
        let pcm = speech(seconds: 5)
        let segments = SpeechChunking.segments(pcm16: pcm, sampleRate: rate)
        #expect(segments.count == 1)
        #expect(segments[0] == pcm)
    }

    @Test func emptyAudioProducesNoSegments() {
        #expect(SpeechChunking.segments(pcm16: [], sampleRate: rate).isEmpty)
    }

    @Test func longAudioSplitsIntoSegmentsUnderTheRecognizerLimit() {
        let pcm = speech(seconds: 150)
        let segments = SpeechChunking.segments(pcm16: pcm, sampleRate: rate)
        #expect(segments.count > 1, "150s must not go to the recognizer as one request")
        for s in segments {
            #expect(s.count <= SpeechChunking.maximumSegmentSeconds * rate)
        }
    }

    @Test func splittingLosesNoSamplesAndPreservesOrder() {
        let pcm = speech(seconds: 150)
        let rejoined = SpeechChunking.segments(pcm16: pcm, sampleRate: rate).flatMap { $0 }
        #expect(rejoined == pcm, "every sample must reach the recognizer exactly once, in order")
    }

    @Test func splitsAtSilenceRatherThanMidWord() {
        // Speech, a clear pause just before the hard limit, then more speech.
        // Expressed relative to the limit so tuning it doesn't silently turn
        // this into a test of the hard-cut path instead.
        let limit = Double(SpeechChunking.maximumSegmentSeconds)
        let head = speech(seconds: limit - 3)
        let gap = silence(seconds: 2)
        let pcm = head + gap + speech(seconds: limit)

        let segments = SpeechChunking.segments(pcm16: pcm, sampleRate: rate)

        #expect(segments.count == 2)
        // The cut lands inside the pause, not at the 60s ceiling.
        let firstEnd = segments[0].count
        #expect(firstEnd >= head.count, "cut before the pause would clip the first sentence")
        #expect(firstEnd <= head.count + gap.count, "cut after the pause splits mid-word")
    }

    @Test func silenceOnlyBeforeTheWindowIsIgnored() {
        // A pause in the first seconds is a bad cut point — it would make a
        // near-empty segment and push the rest against the ceiling again.
        let limit = Double(SpeechChunking.maximumSegmentSeconds)
        let pcm = speech(seconds: 2) + silence(seconds: 1) + speech(seconds: limit * 2)
        let segments = SpeechChunking.segments(pcm16: pcm, sampleRate: rate)
        #expect(Double(segments[0].count) > limit * 0.5 * Double(rate),
                "must not cut at a pause in the first seconds")
    }

    // MARK: - frames

    @Test func framesSplitASegmentIntoIncrementalAppends() {
        let pcm = speech(seconds: 2)
        let frames = SpeechChunking.frames(of: pcm, frameCount: 8_000)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.count == 8_000 })
        #expect(frames.flatMap { $0 } == pcm)
    }

    @Test func framesKeepTheTrailingRemainder() {
        let pcm = speech(seconds: 1) + [Int16](repeating: 7, count: 3)
        let frames = SpeechChunking.frames(of: pcm, frameCount: 8_000)
        #expect(frames.count == 3)
        #expect(frames.last?.count == 3)
        #expect(frames.flatMap { $0 } == pcm)
    }

    @Test func framesOfEmptyAudioIsEmpty() {
        #expect(SpeechChunking.frames(of: [], frameCount: 8_000).isEmpty)
    }

    // MARK: - join

    @Test func joinConcatenatesSegmentTranscriptsWithASingleSpace() {
        #expect(SpeechChunking.join(["Hello there.", "How are you?"]) == "Hello there. How are you?")
    }

    @Test func joinSkipsSegmentsThatTranscribedToNothing() {
        #expect(SpeechChunking.join(["Hello.", "", "  ", "Bye."]) == "Hello. Bye.")
    }

    @Test func joinOfNothingIsEmpty() {
        #expect(SpeechChunking.join([]).isEmpty)
        #expect(SpeechChunking.join(["", " "]).isEmpty)
    }

    // MARK: - combine

    @Test func combineReturnsTheJoinedTranscriptWhenEverySegmentSucceeds() throws {
        let combined = try SpeechChunking.combine([.success("Hello there."), .success("How are you?")])
        #expect(combined == "Hello there. How are you?")
    }

    @Test func combineKeepsTranscribedSpeechWhenOneSegmentFindsNone() throws {
        // Trailing silence in the last segment must not throw away the words
        // the earlier segments did hear.
        let combined = try SpeechChunking.combine([
            .success("Hello there."),
            .failure(AppleSpeechError.noSpeechDetected),
        ])
        #expect(combined == "Hello there.")
    }

    @Test func combineRethrowsWhenNoSegmentProducedAnyText() {
        #expect(throws: AppleSpeechError.noSpeechDetected) {
            try SpeechChunking.combine([
                .failure(AppleSpeechError.noSpeechDetected),
                .failure(AppleSpeechError.noSpeechDetected),
            ])
        }
    }

    @Test func combineRethrowsTheFirstErrorWhenSegmentsFailedDifferently() {
        #expect(throws: AppleSpeechError.cancelled) {
            try SpeechChunking.combine([
                .failure(AppleSpeechError.cancelled),
                .failure(AppleSpeechError.noSpeechDetected),
            ])
        }
    }

    @Test func combineOfNothingIsEmpty() throws {
        #expect(try SpeechChunking.combine([]).isEmpty)
    }
}
