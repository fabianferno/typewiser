import AVFoundation
import Foundation
import Speech

public enum AppleSpeechError: Error, Equatable {
    /// No recognizer for the locale, or the recognizer reports itself
    /// unavailable (e.g. the on-device model has not finished installing).
    case unavailable
    case notAuthorized
    case cancelled
    /// The recognizer read the audio and found nothing it could treat as
    /// speech. Distinguished from a generic failure because it is almost
    /// always a microphone problem rather than a software one, and so earns a
    /// different message — see `SessionPhase` construction in `DictationSession`.
    case noSpeechDetected
}

/// `kAFAssistantErrorDomain` 1110. Apple exposes no symbolic constant for it,
/// and it arrives as a plain `NSError` through the recognition callback.
private func isNoSpeechDetected(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
}

/// On-device speech-to-text via Apple's Speech framework — the default STT
/// source. No server to run, no model to download, and audio never leaves the
/// machine (`requiresOnDeviceRecognition = true`).
///
/// Unlike `WhisperClient`, this does not produce interim results: on-device
/// recognition is a one-shot over the whole utterance rather than a stream we
/// can poll, so `tryTranscribe` returns nil and the HUD simply shows the
/// waveform until the final transcript lands. The trade is deliberate — polling
/// would re-run the recognizer from scratch on every tick.
public actor AppleSpeechTranscriber: Transcribing {
    private let recognizer: SFSpeechRecognizer?
    /// The one recognition in flight, if any. Held so `cancelInFlight()` can
    /// stop it (recognition is otherwise fire-and-forget once started).
    private var active: SFSpeechRecognitionTask?

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Prompts for Speech authorization if not yet decided. On-device
    /// recognition still requires the user's grant even though it never
    /// touches the network. Returns whether recognition is now permitted.
    public static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    public static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Set by `cancelInFlight()` so a multi-segment recognition stops between
    /// segments instead of transcribing the rest of a recording the user has
    /// already abandoned.
    private var isCancelled = false

    public func cancelInFlight() {
        isCancelled = true
        active?.cancel()
        active = nil
    }

    public func transcribe(pcm16: [Int16]) async throws -> String {
        cancelInFlight()
        return try await recognize(pcm16)
    }

    public func tryTranscribe(pcm16: [Int16]) async throws -> String? { nil }

    /// Samples per buffer appended to the recognizer: 0.5s at 16 kHz.
    private static let appendFrameCount = 8_000
    private static let sampleRate = 16_000
    /// Delay between appended buffers — see `recognizeSegment`.
    private static let appendPacing = Duration.milliseconds(20)

    private func recognize(_ pcm16: [Int16]) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleSpeechError.notAuthorized
        }
        guard let recognizer, recognizer.isAvailable else { throw AppleSpeechError.unavailable }

        isCancelled = false
        let segments = SpeechChunking.segments(pcm16: pcm16, sampleRate: Self.sampleRate)
        if segments.count > 1 {
            TWLog.stt.info("long dictation split into \(segments.count, privacy: .public) segments")
        }

        var results: [Result<String, Error>] = []
        for (index, segment) in segments.enumerated() {
            do {
                let text = try await recognizeSegment(segment, recognizer: recognizer)
                // Per-segment counts, not content: a segment returning far less
                // text than its duration warrants is the signature of audio
                // being dropped, and is invisible in the combined total.
                TWLog.stt.info(
                    "segment \(index + 1)/\(segments.count): \(segment.count / Self.sampleRate)s -> \(text.count) chars")
                results.append(.success(text))
            } catch {
                TWLog.stt.error(
                    "segment \(index + 1)/\(segments.count) failed: \(String(describing: error), privacy: .public)")
                results.append(.failure(error))
            }
            // Checked after the segment rather than before: a cancel arriving
            // mid-segment already tore down that task, and there is no point
            // starting the next one.
            if isCancelled { throw AppleSpeechError.cancelled }
        }
        return try SpeechChunking.combine(results)
    }

    /// One recognition request over one sub-minute segment.
    ///
    /// Two details here are load-bearing, and both exist because
    /// `SFSpeechAudioBufferRecognitionRequest` is a *streaming* API. Handing it
    /// the whole recording as a single buffer transcribes only the leading part
    /// of it — the truncation this method's chunking exists to fix — so the
    /// audio goes in as a run of small buffers instead. And partial results are
    /// requested even though only the final one is wanted, so that a recognizer
    /// which errors out part-way (or is cancelled) still leaves us the words it
    /// had heard, rather than nothing.
    private func recognizeSegment(_ pcm16: [Int16],
                                  recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let once = ResumeGuard()
        let heard = TranscriptBox()

        // The `recognitionTask` call runs synchronously in the actor's
        // isolation, so storing the task in `active` needs no hop. The
        // completion handler runs off the actor but touches only `once`,
        // `heard` and the continuation, all Sendable.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            active = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    heard.set(text)
                    // The final result is authoritative, but a partial that saw
                    // more than it did is not worth discarding: prefer whichever
                    // is longer rather than assuming partials only ever grow.
                    if result.isFinal, once.claim() {
                        cont.resume(returning: text.count >= heard.value.count ? text : heard.value)
                    }
                } else if let error {
                    guard once.claim() else { return }
                    // Words already heard beat any error: a mid-stream failure
                    // on the tail of a segment should not throw away its head.
                    let partial = heard.value
                    if !partial.isEmpty {
                        cont.resume(returning: partial)
                    } else {
                        cont.resume(throwing: isNoSpeechDetected(error)
                            ? AppleSpeechError.noSpeechDetected
                            : error)
                    }
                }
            }
            // Paced, not dumped. The recognizer is built for audio arriving
            // from a live tap; appending a whole minute as fast as the loop can
            // run makes it discard all but the most recent window, which shows
            // up as a transcript containing only the tail of what was said.
            // 20ms per 0.5s frame is ~25x realtime — fast enough that a minute
            // of audio costs ~2.5s, slow enough that nothing is dropped.
            //
            // `request` is not `Sendable`, but the hand-off is safe: this actor
            // touches it nowhere else once the task owns it, and the recognizer
            // is documented to accept appends from another thread.
            let sink = AudioSink(request)
            let frames = SpeechChunking.frames(of: pcm16, frameCount: Self.appendFrameCount)
            let pacing = Self.appendPacing
            Task.detached {
                for frame in frames {
                    sink.append(Self.buffer(from: frame))
                    try? await Task.sleep(for: pacing)
                }
                sink.end()
            }
        }
    }

    /// Speech wants an `AVAudioPCMBuffer`; our pipeline carries 16 kHz mono
    /// Int16. Convert to the standard deinterleaved float format the recognizer
    /// expects.
    private static func buffer(from pcm16: [Int16]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(pcm16.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        if let dst = buffer.floatChannelData?[0] {
            for i in 0..<pcm16.count { dst[i] = Float(pcm16[i]) / 32_768.0 }
        }
        return buffer
    }
}

/// Carries the recognition request to the paced feeding task.
///
/// `SFSpeechAudioBufferRecognitionRequest` is not `Sendable`, but the hand-off
/// is safe: the transcriber touches the request nowhere else once the feeding
/// task owns it, so there is exactly one writer.
private final class AudioSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func end() { request.endAudio() }
}

/// Holds the fullest transcription seen for a segment, so a recognizer that
/// fails or is cancelled part-way still yields the words it did hear.
private final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        // Longest wins rather than latest. Partials usually grow, but a
        // recognizer that starts dropping its head emits shrinking ones, and
        // those must not overwrite what was already heard.
        if s.count > text.count { text = s }
    }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// One-shot guard so a recognition callback that fires more than once (a final
/// result followed by a late error, say) resumes the continuation exactly once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
