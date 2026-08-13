import Foundation

/// Builds the speech-to-text backend from current settings, and rebuilds it
/// when those settings change.
///
/// Exists because the choice of transcriber used to be made once, in
/// `AppModel.init`: switching source, accent or name dictionary in Settings
/// wrote to `UserDefaults` and then did nothing until relaunch. `DictationSession`
/// asks this for a transcriber at the top of every dictation, so a change lands
/// on the next hotkey press.
///
/// Rebuilding is not free — `SFSpeechRecognizer(locale:)` in particular — so the
/// instance is cached and only replaced when the inputs that shaped it actually
/// differ. Steady state is a lock, four `UserDefaults` reads and a string
/// compare.
public final class TranscriberProvider: @unchecked Sendable {
    /// Everything `makeTranscriber` reads. Compared as a whole rather than
    /// field by field so that adding an input here cannot be forgotten in an
    /// equality check further down.
    private struct Signature: Equatable {
        let source: STTSource
        let locale: String
        let endpoint: String
        let vocabulary: [String]
    }

    private let settings: SettingsStore
    private let lock = NSLock()
    private var cached: (Signature, Transcribing)?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// The transcriber matching settings as they stand right now.
    public func current() -> Transcribing {
        let wanted = signature()
        lock.lock()
        defer { lock.unlock() }
        if let (sig, transcriber) = cached, sig == wanted { return transcriber }
        let transcriber = Self.make(wanted)
        cached = (wanted, transcriber)
        TWLog.stt.info(
            "transcriber: \(String(describing: wanted.source), privacy: .public) \(wanted.locale, privacy: .public)")
        return transcriber
    }

    private func signature() -> Signature {
        Signature(source: settings.sttSource,
                  locale: settings.sttLocale,
                  endpoint: settings.whisperEndpoint.trimmingCharacters(in: .whitespaces),
                  vocabulary: settings.nameDictionary)
    }

    /// Apple on-device is the default and the fallback: if Remote is selected
    /// but no endpoint is configured yet, dictation still works locally rather
    /// than failing.
    ///
    /// The name dictionary feeds both stages: `contextualStrings` here, so the
    /// recognizer is biased toward hearing the word at all, and the rewrite
    /// prompt later, so it is spelled the user's way once heard.
    private static func make(_ sig: Signature) -> Transcribing {
        switch sig.source {
        case .remote:
            if !sig.endpoint.isEmpty, let url = URL(string: sig.endpoint) {
                return WhisperClient(endpoint: url)
            }
            fallthrough
        case .apple:
            return AppleSpeechTranscriber(locale: Locale(identifier: sig.locale),
                                          vocabulary: sig.vocabulary)
        }
    }
}
