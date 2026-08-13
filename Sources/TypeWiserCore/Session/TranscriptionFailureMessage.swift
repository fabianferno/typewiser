import Foundation

/// Turns a transcription failure into something the user can act on.
///
/// The generic "Transcription failed: <error>" this replaced was actively
/// misleading for the most common failure: the recognizer reporting no speech
/// in audio that *sounded* fine and had healthy amplitude. That is a
/// microphone problem, and naming the device is what lets the user fix it —
/// especially for Bluetooth headsets, whose mic drops to a low-quality mode
/// the moment an app opens it.
///
/// Deliberately pure (device passed in, not read here) so every branch is
/// unit-testable without real audio hardware.
public enum TranscriptionFailureMessage {
    public static func text(for error: Error, input: InputDevice?) -> String {
        guard case AppleSpeechError.noSpeechDetected = error else {
            return generic(error)
        }
        guard let input else {
            return "Didn't catch any speech — check your microphone."
        }
        if input.isBluetooth {
            return "Didn't catch any speech from “\(input.name)”. Bluetooth mics are often too degraded to transcribe — try your built-in microphone in System Settings → Sound → Input."
        }
        return "Didn't catch any speech from “\(input.name)”. Check that it's picking up your voice."
    }

    /// "en_GB" -> "English (United Kingdom)". Falls back to the raw identifier
    /// rather than dropping the locale, which is the one detail that makes the
    /// message actionable.
    private static func displayName(_ locale: String) -> String {
        Locale.current.localizedString(forIdentifier: locale) ?? locale
    }

    private static func generic(_ error: Error) -> String {
        switch error {
        case AppleSpeechError.notAuthorized:
            return "Speech Recognition permission is off — enable it in System Settings → Privacy & Security."
        case AppleSpeechError.modelNotInstalled(let locale):
            return "The \(displayName(locale)) speech model isn't installed on this Mac. Pick a different accent in Settings, or add the language in System Settings → Keyboard → Dictation."
        case AppleSpeechError.unavailable:
            return "Speech recognition is unavailable — the on-device model may still be downloading."
        case AppleSpeechError.cancelled, WhisperError.cancelled:
            return "Transcription cancelled."
        default:
            return "Transcription failed: \(error)"
        }
    }
}
