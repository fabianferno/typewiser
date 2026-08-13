import Foundation

public enum SessionPhase: Sendable, Equatable {
    case idle
    case recording(interim: String)
    case transcribing
    case rewriting
    case inserted(String)
    case error(String)
}

/// Orchestrates one dictation cycle. Identical whether the recording was held
/// or latched hands-free — that distinction lives entirely in
/// `HotkeyStateMachine` and the HUD label.
public actor DictationSession {
    private let audio: AudioCapturing
    /// Resolved once per dictation, at `begin()` — the same instance then
    /// serves the interim loop, `end()` and `cancel()` for that whole cycle,
    /// so a source switch mid-hold can never split one utterance across two
    /// transcribers. Re-resolving each cycle is what makes the Settings
    /// picker take effect on the very next dictation instead of at relaunch.
    ///
    /// Nil until the first `begin()`: building one at `init` would construct an
    /// `SFSpeechRecognizer` the app may never use, and would be built from
    /// settings as they stood at launch — the very thing this replaced.
    private let makeWhisper: @Sendable () -> Transcribing
    private var whisper: Transcribing?
    private let makeRewriter: @Sendable () -> Rewriter
    private let makeContext: @Sendable () -> ContextReading
    private let injector: TextInjector
    private let makeOptions: @Sendable () -> RewriteOptions
    private let tooShortSound: SoundPlaying?

    /// Below this, the hotkey was tapped rather than held: 16kHz mono, so this
    /// is a quarter-second. Nothing usable can be transcribed from it, and the
    /// recognizer would otherwise answer with either silence or a hallucinated
    /// word after a pointless round-trip.
    static let minimumSampleCount = 4_000

    private var interimTask: Task<Void, Never>?
    private var continuation: AsyncStream<SessionPhase>.Continuation?
    public let phaseStream: AsyncStream<SessionPhase>

    /// Set as the very first, synchronous statement of `end()`/`cancel()` —
    /// before either does its first `await` — so it is guaranteed to be
    /// `true` by the time any *later* actor turn runs, including an
    /// `emitInterim` call from an interim-loop iteration that was already
    /// mid-`tryTranscribe` when `end()`/`cancel()` was invoked. Without this,
    /// that in-flight call's result still reaches `emitInterim` once it
    /// resolves, landing during `end()`'s `await whisper.transcribe(...)` and
    /// flipping the HUD back to "Listening" after it had already moved on to
    /// "Transcribing…". Reset at the top of `begin()` for the next cycle.
    private var isEnding = false

    /// Read once at `begin()` rather than at `end()`, purely for latency.
    ///
    /// `ContextReading.read()` is a *synchronous, blocking* Accessibility
    /// round-trip into whatever app has focus. Called from `end()` it landed
    /// squarely on the critical path — the user has already released the key
    /// and is watching the HUD — and AX-hostile hosts (Electron, JVM apps) can
    /// stall it for tens to hundreds of ms with no timeout available to us.
    /// Called from `begin()`, the exact same work overlaps with the user still
    /// speaking and costs them nothing.
    ///
    /// Safe because nothing this reads changes during a hold: the focused
    /// element and frontmost app are fixed for the duration. Reading at
    /// `begin()` is arguably the more correct capture point anyway — it
    /// records where the user aimed the dictation, not wherever focus drifted
    /// to by the time transcription came back.
    ///
    /// Left `.empty` if `end()` somehow arrives before `begin()` captured
    /// (only reachable if the key is released while `audio.start()` is still
    /// awaiting). That degrades to a context-free rewrite — exactly what
    /// already happens in apps that expose nothing over AX — never a failure.
    private var capturedContext: RewriteContext = .empty

    public init(audio: AudioCapturing,
                whisper: @escaping @Sendable () -> Transcribing,
                rewriter: @escaping @Sendable () -> Rewriter,
                context: @escaping @Sendable () -> ContextReading,
                injector: TextInjector,
                options: @escaping @Sendable () -> RewriteOptions,
                tooShortSound: SoundPlaying? = SystemSoundPlayer(.tooShort)) {
        self.tooShortSound = tooShortSound
        self.audio = audio
        self.makeWhisper = whisper
        self.makeRewriter = rewriter
        self.makeContext = context
        self.injector = injector
        self.makeOptions = options
        var cont: AsyncStream<SessionPhase>.Continuation!
        self.phaseStream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private func emit(_ p: SessionPhase) { continuation?.yield(p) }

    public func begin() async {
        isEnding = false
        capturedContext = .empty
        // Before `audio.start()`: picking up the current source can never be
        // late for this dictation, and the old instance is finished with —
        // both `end()` and `cancel()` cancel in flight before returning.
        whisper = makeWhisper()
        do {
            try await audio.start()
        } catch {
            TWLog.session.error("audio.start failed: \(String(describing: error), privacy: .public)")
            emit(.error("Microphone unavailable"))
            return
        }
        TWLog.session.info("dictation began")
        emit(.recording(interim: ""))
        startInterimLoop()
        // Deliberately last: emitting `.recording` and arming the interim loop
        // first means the HUD is already up before this blocking AX read runs,
        // so a slow host delays neither. See `capturedContext`.
        capturedContext = makeContext().read()
    }

    /// Polls the single server slot without a timer: the next request is issued
    /// only once the previous returns. A fixed interval would queue up behind
    /// the ~3.5s latency and fall further behind the longer the user speaks.
    private func startInterimLoop() {
        interimTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let samples = await self.audio.currentSamples()
                guard samples.count > 8000 else {   // <0.5s of audio: not worth a slot
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                guard let whisper = await self.whisper else { return }
                if let text = try? await whisper.tryTranscribe(pcm16: samples) {
                    await self.emitInterim(text)
                } else {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    private func emitInterim(_ text: String) {
        guard !isEnding else { return }
        emit(.recording(interim: text))
    }

    public func cancel() async {
        isEnding = true
        interimTask?.cancel()
        interimTask = nil
        await audio.stop()
        await whisper?.cancelInFlight()
        emit(.idle)
    }

    public func end() async {
        isEnding = true
        interimTask?.cancel()
        interimTask = nil
        await audio.stop()
        await whisper?.cancelInFlight()

        let samples = await audio.currentSamples()
        // Loudness, not content: RMS and peak are the only way to tell a
        // "recognizer rejected real speech" failure apart from a "the mic
        // handed us silence" one. Both are scalars — nothing about *what* was
        // said can be recovered from them.
        let rms = AudioCapture.rms(samples)
        let peak = samples.map { abs(Int32($0)) }.max() ?? 0
        TWLog.session.info(
            "dictation ended: \(samples.count) samples (~\(samples.count / 16_000)s), rms \(rms, format: .fixed(precision: 5)), peak \(peak)/32767")
        CaptureDump.saveIfEnabled(samples)   // no-op unless the user opted in

        // A tap, not a hold. Say so with a sound: the HUD has already come and
        // gone by now, so silently returning to idle is indistinguishable from
        // dictation that failed.
        guard samples.count >= Self.minimumSampleCount else {
            TWLog.session.info("released too quickly (\(samples.count) samples), nothing captured")
            tooShortSound?.play()
            emit(.idle)
            return
        }

        emit(.transcribing)

        let transcript: String
        do {
            // `?? makeWhisper()` only for an `end()` with no preceding
            // `begin()` — unreachable through the hotkey, but transcribing is
            // still the right answer there rather than dropping the audio.
            transcript = try await (whisper ?? makeWhisper()).transcribe(pcm16: samples)
        } catch {
            let input = AudioDevice.currentInput()
            TWLog.stt.error(
                "transcription failed on \(input?.name ?? "unknown input", privacy: .public)\(input?.isBluetooth == true ? " (bluetooth)" : "", privacy: .public): \(String(describing: error), privacy: .public)")
            emit(.error(TranscriptionFailureMessage.text(for: error, input: input)))
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            TWLog.session.info("empty transcript, nothing to insert")
            emit(.idle)
            return
        }

        // Counts, not content: without a length either side of cleanup there is
        // no way to tell a transcriber that dropped words from a rewriter that
        // summarised them — the inserted length alone looks identical.
        TWLog.stt.info("transcript: \(trimmed.count) chars")

        emit(.rewriting)
        // Any rewriter failure degrades to the raw transcript. Losing the user's
        // words is never an acceptable outcome — but the failure itself must be
        // logged, or cleanup silently stops working with zero diagnostic trail.
        let final: String
        do {
            final = try await makeRewriter().rewrite(trimmed, options: makeOptions(), context: capturedContext)
        } catch {
            TWLog.rewrite.error("rewrite failed, falling back to raw transcript: \(String(describing: error), privacy: .public)")
            final = trimmed
        }

        await injector.insert(final)
        TWLog.session.info("inserted \(final.count) chars (from \(trimmed.count) transcribed)")
        emit(.inserted(final))
    }
}
