import AVFoundation
import Foundation
import Speech

public enum AppleSpeechError: Error, Equatable {
    /// No recognizer for the locale, or the recognizer reports itself
    /// unavailable (e.g. the on-device model has not finished installing).
    case unavailable
    case notAuthorized
    case cancelled
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

    public func cancelInFlight() {
        active?.cancel()
        active = nil
    }

    public func transcribe(pcm16: [Int16]) async throws -> String {
        cancelInFlight()
        return try await recognize(pcm16)
    }

    public func tryTranscribe(pcm16: [Int16]) async throws -> String? { nil }

    private func recognize(_ pcm16: [Int16]) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleSpeechError.notAuthorized
        }
        guard let recognizer, recognizer.isAvailable else { throw AppleSpeechError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(Self.buffer(from: pcm16))
        request.endAudio()

        let once = ResumeGuard()
        // This closure runs synchronously in the actor's isolation, so storing
        // the task in `active` needs no hop. The completion handler runs off
        // the actor but touches only `once` and the continuation, both Sendable.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            active = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() {
                        cont.resume(returning: result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } else if let error {
                    if once.claim() { cont.resume(throwing: error) }
                }
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
