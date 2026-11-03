import Foundation

/// Tries `primary` (the remote whisper.cpp server) and, if it fails, transcribes
/// the same audio with `fallback` (Apple on-device).
///
/// Exists because a remote server going down — Cloudflare answering 502 for a
/// tunnel whose origin is offline — used to fail every dictation with a raw
/// `http(502)`, even though the Mac could transcribe the recording itself. The
/// audio is already captured; throwing it away over a server problem is the
/// worst outcome.
///
/// Cancellation is never retried: the user abandoned the dictation, and
/// running a second recognizer would resurrect it.
public actor FallbackTranscriber: Transcribing {
    private let primary: Transcribing
    private let fallback: Transcribing

    public init(primary: Transcribing, fallback: Transcribing) {
        self.primary = primary
        self.fallback = fallback
    }

    public func transcribe(pcm16: [Int16]) async throws -> String {
        do {
            return try await primary.transcribe(pcm16: pcm16)
        } catch {
            if Self.isCancellation(error) { throw error }
            TWLog.stt.error(
                "remote transcription failed, falling back to on-device: \(String(describing: error), privacy: .public)")
            do {
                return try await fallback.transcribe(pcm16: pcm16)
            } catch let fallbackError {
                if Self.isCancellation(fallbackError) { throw fallbackError }
                // If the fallback couldn't even start (no Speech permission,
                // no model for this accent), its error would send the user
                // to fix a setting they never chose. The server is what
                // they configured, so report the server. If the fallback
                // ran and heard nothing, that is the more useful message.
                try Self.rethrowPreferring(primary: error, fallback: fallbackError)
            }
        }
    }

    /// Interim results are a nicety polled while recording; only the remote
    /// server supports them (`AppleSpeechTranscriber` returns nil), so there is
    /// nothing to fall back to.
    public func tryTranscribe(pcm16: [Int16]) async throws -> String? {
        try await primary.tryTranscribe(pcm16: pcm16)
    }

    public func cancelInFlight() async {
        await primary.cancelInFlight()
        await fallback.cancelInFlight()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        switch error {
        case WhisperError.cancelled, AppleSpeechError.cancelled, is CancellationError: return true
        default: return false
        }
    }

    private static func rethrowPreferring(primary: Error, fallback: Error) throws -> Never {
        switch fallback {
        case AppleSpeechError.notAuthorized, AppleSpeechError.unavailable,
             AppleSpeechError.modelNotInstalled:
            throw primary
        default:
            throw fallback
        }
    }
}
