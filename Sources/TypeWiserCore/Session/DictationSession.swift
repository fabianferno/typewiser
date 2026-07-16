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
    private let context: ContextReading
    private let injector: TextInjector
    private let makeOptions: @Sendable () -> RewriteOptions

    private var interimTask: Task<Void, Never>?
    private var continuation: AsyncStream<SessionPhase>.Continuation?
    public let phaseStream: AsyncStream<SessionPhase>

    public init(audio: AudioCapturing,
                whisper: Transcribing,
                rewriter: @escaping @Sendable () -> Rewriter,
                context: ContextReading,
                injector: TextInjector,
                options: @escaping @Sendable () -> RewriteOptions) {
        self.audio = audio
        self.whisper = whisper
        self.makeRewriter = rewriter
        self.context = context
        self.injector = injector
        self.makeOptions = options
        var cont: AsyncStream<SessionPhase>.Continuation!
        self.phaseStream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private func emit(_ p: SessionPhase) { continuation?.yield(p) }

    public func begin() async {
        do {
            try await audio.start()
        } catch {
            emit(.error("Microphone unavailable"))
            return
        }
        emit(.recording(interim: ""))
        startInterimLoop()
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

    private func emitInterim(_ text: String) { emit(.recording(interim: text)) }

    public func cancel() async {
        interimTask?.cancel()
        interimTask = nil
        await audio.stop()
        await whisper.cancelInFlight()
        emit(.idle)
    }

    public func end() async {
        interimTask?.cancel()
        interimTask = nil
        await audio.stop()
        await whisper.cancelInFlight()

        let samples = await audio.currentSamples()
        emit(.transcribing)

        let transcript: String
        do {
            transcript = try await whisper.transcribe(pcm16: samples)
        } catch {
            emit(.error("Transcription failed: \(error)"))
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            emit(.idle)
            return
        }

        emit(.rewriting)
        let ctx = context.read()
        // Any rewriter failure degrades to the raw transcript. Losing the user's
        // words is never an acceptable outcome.
        let final = (try? await makeRewriter().rewrite(trimmed, options: makeOptions(), context: ctx)) ?? trimmed

        await injector.insert(final)
        emit(.inserted(final))
    }
}
