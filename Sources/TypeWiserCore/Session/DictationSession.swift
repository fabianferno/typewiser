import Foundation

public enum SessionPhase: Sendable, Equatable {
    case idle
    case recording(interim: String)
    case transcribing
    case rewriting
    case inserted(String)
    case error(String)
}

/// Orchestrates one hold-to-talk cycle.
public actor DictationSession {
    private let audio: AudioCapturing
    private let whisper: Transcribing
    private let makeRewriter: @Sendable () -> Rewriter
    private let makeContext: @Sendable () -> ContextReading
    private let injector: TextInjector
    private let makeOptions: @Sendable () -> RewriteOptions

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
                whisper: Transcribing,
                rewriter: @escaping @Sendable () -> Rewriter,
                context: @escaping @Sendable () -> ContextReading,
                injector: TextInjector,
                options: @escaping @Sendable () -> RewriteOptions) {
        self.audio = audio
        self.whisper = whisper
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
                if let text = try? await self.whisper.tryTranscribe(pcm16: samples) {
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
        await whisper.cancelInFlight()
        emit(.idle)
    }

    public func end() async {
        isEnding = true
        interimTask?.cancel()
        interimTask = nil
        await audio.stop()
        await whisper.cancelInFlight()

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
        emit(.transcribing)

        let transcript: String
        do {
            transcript = try await whisper.transcribe(pcm16: samples)
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
        TWLog.session.info("inserted \(final.count) chars")
        emit(.inserted(final))
    }
}
