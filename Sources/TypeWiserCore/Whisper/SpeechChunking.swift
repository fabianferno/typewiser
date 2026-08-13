import Foundation

/// Audio splitting for `AppleSpeechTranscriber`.
///
/// `SFSpeechAudioBufferRecognitionRequest` is a streaming API: it expects audio
/// appended in small buffers as it arrives, and it will not reliably transcribe
/// a whole recording handed to it as one large buffer — long dictations come
/// back truncated after the first few sentences. On top of that, on-device
/// recognition quietly drops all but the tail of an over-long request — see
/// `maximumSegmentSeconds`.
///
/// So the transcriber does two things, both decided here: cut the recording
/// into sub-minute segments (preferring a natural pause over a hard cut), and
/// feed each segment to the recognizer frame by frame. Kept as pure functions
/// on `[Int16]` because the recognizer itself needs real hardware and a granted
/// Speech permission, and none of this logic should need either to be tested.
public enum SpeechChunking {
    /// Ceiling for one recognition request.
    ///
    /// Apple documents no figure, and the ~60s number quoted everywhere is
    /// wrong in the way that matters: a 60s request does not fail, it returns
    /// only the last couple of seconds of what was said, with no error. Measured
    /// on this pipeline, 16s/27s/28s requests each came back complete while a
    /// 60s one came back as two words. 25s sits below every length observed to
    /// work, with margin. The cost of a smaller ceiling is one extra request per
    /// 25s of speech — about a second each, and they are already sequential.
    public static let maximumSegmentSeconds = 25

    /// Fraction of a full window before which a pause is not worth cutting at.
    /// A pause three seconds into a ninety-second recording is a terrible split
    /// point: it yields a near-empty segment and leaves the remainder pressed
    /// against the ceiling again. Only pauses in the back half of the window
    /// are candidates.
    private static let earliestCutFraction = 0.5

    /// Mean-square threshold below which a frame counts as a pause. Compared
    /// against squared amplitude to keep the scan integer-only — a `sqrt` per
    /// frame over minutes of audio buys nothing here.
    private static let silenceMeanSquare = 500.0 * 500.0

    /// Frames the silence scan works in. 100ms is short enough to land inside a
    /// between-sentence pause and long enough that one quiet sample doesn't
    /// read as silence.
    private static let scanFrameSeconds = 0.1

    /// Splits `pcm16` into segments no longer than `maximumSegmentSeconds`,
    /// cutting at the last pause in the back half of each window when there is
    /// one and at the hard limit when there isn't. Concatenating the result
    /// reproduces the input exactly — no sample is dropped or reordered.
    public static func segments(pcm16: [Int16], sampleRate: Int) -> [[Int16]] {
        guard !pcm16.isEmpty else { return [] }
        let limit = maximumSegmentSeconds * sampleRate

        var result: [[Int16]] = []
        var start = 0
        while start < pcm16.count {
            let remaining = pcm16.count - start
            if remaining <= limit {
                result.append(Array(pcm16[start...]))
                break
            }
            let cut = start + cutOffset(in: pcm16[start..<(start + limit)], sampleRate: sampleRate)
            result.append(Array(pcm16[start..<cut]))
            start = cut
        }
        return result
    }

    /// Offset within a full-length window at which to cut: the end of the last
    /// pause in its back half, or the whole window if it contains no pause.
    private static func cutOffset(in window: ArraySlice<Int16>, sampleRate: Int) -> Int {
        let frame = max(1, Int(Double(sampleRate) * scanFrameSeconds))
        let earliest = Int(Double(window.count) * earliestCutFraction)

        var offset = earliest
        var lastSilentEnd: Int?
        while offset + frame <= window.count {
            let lower = window.startIndex + offset
            if isSilent(window[lower..<(lower + frame)]) { lastSilentEnd = offset + frame }
            offset += frame
        }
        return lastSilentEnd ?? window.count
    }

    private static func isSilent(_ samples: ArraySlice<Int16>) -> Bool {
        guard !samples.isEmpty else { return true }
        // Accumulate in Double: a 100ms frame of full-scale audio overflows
        // Int32 and would trap.
        let sum = samples.reduce(0.0) { acc, s in
            let v = Double(s)
            return acc + v * v
        }
        return sum / Double(samples.count) < silenceMeanSquare
    }

    /// Slices one segment into the fixed-size buffers appended to the
    /// recognition request. The final frame carries whatever remainder is left.
    public static func frames(of pcm16: [Int16], frameCount: Int) -> [[Int16]] {
        guard !pcm16.isEmpty, frameCount > 0 else { return [] }
        return stride(from: 0, to: pcm16.count, by: frameCount).map {
            Array(pcm16[$0..<min($0 + frameCount, pcm16.count)])
        }
    }

    /// Reduces per-segment outcomes to the one transcript the caller wanted.
    ///
    /// A failed segment is only fatal when *no* segment produced text: a pause
    /// long enough to be its own segment, or a cut landing on trailing silence,
    /// makes the recognizer report "no speech" for that stretch alone, and
    /// throwing then would discard a minute of correctly heard dictation. When
    /// nothing was heard anywhere, the first error stands so the caller still
    /// sees `noSpeechDetected` (and its microphone-specific message) rather
    /// than an empty string.
    public static func combine(_ results: [Result<String, Error>]) throws -> String {
        let text = join(results.compactMap { try? $0.get() })
        if text.isEmpty, let firstError = results.compactMap({ $0.failureError }).first {
            throw firstError
        }
        return text
    }

    /// Joins per-segment transcripts back into one. Segments that transcribed
    /// to nothing (a cut that landed on trailing silence, say) contribute no
    /// stray whitespace.
    public static func join(_ transcripts: [String]) -> String {
        transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private extension Result where Failure == Error {
    var failureError: Error? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
