import AppKit
import Foundation
import Observation
import TypeWiserCore

/// Used when Cloud mode is selected but no AWS credentials are saved yet.
/// Fails immediately with `.unavailable` rather than attempting a network
/// call — there's nothing to call. `DictationSession.end()`'s existing
/// `?? trimmed` fallback still guarantees the raw transcript is pasted (never
/// lose the user's words); the visible signal that cleanup didn't run lives
/// in the menu bar text and HUD note (see `AppModel.hasCloudCredentials()`).
private struct NoCredentialsRewriter: Rewriter {
    func rewrite(_ transcript: String, options: RewriteOptions, context: RewriteContext) async throws -> String {
        throw RewriteError.unavailable
    }
}

@MainActor
@Observable
final class AppModel {
    var phase: SessionPhase = .idle
    /// Whether the current recording was latched by a double-tap rather than
    /// held. Purely presentational — the session behaves identically either
    /// way — but a latch the user didn't mean to trigger would otherwise
    /// record indefinitely while looking exactly like a normal hold.
    var handsFree = false
    var mode: EngineMode {
        didSet {
            settings.mode = mode
            Task { await applyMode() }
        }
    }
    var engineState: EngineState = .stopped
    /// Live Accessibility trust state, read at launch and refreshed once
    /// permission is granted (see the polling `Task` in `init`). The menu
    /// and Settings→Setup read this instead of calling
    /// `AXIsProcessTrusted()` inline so they actually re-render when it
    /// changes — an inline call in a view body wouldn't be observed.
    var hasAccessibility: Bool

    let settings = SettingsStore()
    private let credentials = KeychainCredentialStore()
    private let openAIKey = KeychainAPIKeyStore(provider: .openai)
    private let anthropicKey = KeychainAPIKeyStore(provider: .anthropic)
    private let engine: EngineManager
    private let audio = AudioCapture()
    private let transcribers: TranscriberProvider
    private var session: DictationSession!
    private var monitor: HotkeyMonitor!
    private let hud: HUDController
    /// Pending auto-hide scheduled after `.inserted`/`.error`. Cancelled the
    /// instant another phase arrives so a new dictation started inside the
    /// 1.5s window can't have this stale timer yank the HUD back down.
    private var hudHideTask: Task<Void, Never>?

    init() {
        let trusted = HotkeyMonitor.hasAccessibilityPermission()
        self.hasAccessibility = trusted
        TWLog.app.info("launched — accessibility: \(trusted), speech authorized: \(AppleSpeechTranscriber.isAuthorized)")

        // Engine (llama-server) paths and the transcriber are both built from
        // saved settings so a fresh clone can retarget them without a rebuild.
        // The engine config is injected into `EngineManager` once, here, and so
        // still takes a relaunch to change; the transcriber does not — the
        // provider is re-asked at the top of every dictation. See
        // `TranscriberProvider`.
        let engineConfig = settings.engineConfig
        self.engine = EngineManager(config: engineConfig)
        self.transcribers = TranscriberProvider(settings: settings)

        // On-device recognition still needs the user's Speech grant; ask at
        // launch (a no-op once already decided) so the first dictation isn't
        // the thing that trips the prompt.
        if settings.sttSource == .apple {
            Task { _ = await AppleSpeechTranscriber.requestAuthorization() }
        }

        // The HUD waveform polls this while recording. `audio` is an actor and
        // `level()` is cheap (RMS over the last 100ms of the buffer), so the
        // hop is affordable at the poll rate; it returns 0 when not recording.
        let audio = self.audio
        self.hud = HUDController(level: { await audio.level() })

        // A previous run that crashed or was force-quit never got to run
        // `stop()`, so its ~17GB llama-server child may still be resident.
        // Reap it before we possibly spawn a fresh one below. Uses the same
        // config we launch with so the pid-file/model-path match holds even
        // when the user has retargeted the model.
        EngineManager.terminateOrphanedProcessIfPresent(config: engineConfig)

        // This is NOT a backup — on a normal quit in Local mode, this is the
        // ONLY thing that reaps the ~17GB `llama-server` child. There is no
        // `deinit` on this class, and `applyMode()` only calls `engine.stop()`
        // when switching mode TO Cloud, never on quit. Reaping here works
        // even though nothing else does because this fires synchronously as
        // part of app termination, with no MainActor/actor hop to race
        // against the process exiting — do not delete this thinking it is
        // redundant with some other cleanup path; there isn't one.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            EngineManager.terminateOrphanedProcessIfPresent(config: engineConfig)
        }

        self.mode = settings.mode
        let settings = self.settings
        let credentials = self.credentials
        let openAIKey = self.openAIKey
        let anthropicKey = self.anthropicKey

        session = DictationSession(
            audio: audio,
            whisper: { [transcribers] in transcribers.current() },
            rewriter: {
                switch settings.mode {
                case .local:
                    return LocalLlamaRewriter()
                case .cloud:
                    // Cloud mode already killed llama-server (see `applyMode()`), so
                    // falling back to `LocalLlamaRewriter()` here would just point at a
                    // dead port: every dictation would silently degrade to the raw
                    // transcript via the `?? trimmed` fallback in `DictationSession.end()`
                    // — HUD still green, zero signal that cleanup stopped happening. Fail
                    // fast instead (no doomed network call), and let the menu bar / HUD
                    // note (see `hasCloudCredentials()` / `observePhases()`) make the
                    // missing configuration visible to the user.
                    switch settings.cloudProvider {
                    case .bedrock:
                        guard let c = credentials.load() else { return NoCredentialsRewriter() }
                        return BedrockRewriter(credentials: c)
                    case .openai:
                        guard let k = openAIKey.load() else { return NoCredentialsRewriter() }
                        return OpenAIRewriter(apiKey: k, model: settings.openAIModel)
                    case .anthropic:
                        guard let k = anthropicKey.load() else { return NoCredentialsRewriter() }
                        return AnthropicRewriter(apiKey: k, model: settings.anthropicModel)
                    }
                }
            },
            context: { AXContextReader(nameDictionary: settings.nameDictionary) },
            injector: TextInjector(sound: SystemSoundPlayer(.paste, isEnabled: { settings.soundsEnabled })),
            options: { settings.options },
            tooShortSound: SystemSoundPlayer(.tooShort, isEnabled: { settings.soundsEnabled })
        )

        monitor = HotkeyMonitor { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }

        Task { await observePhases() }
        Task { await applyMode() }

        if hasAccessibility {
            monitor.start()
        } else {
            // First launch (or permission revoked since): ask now, at
            // launch, rather than waiting for the user to find the menu.
            // If macOS already showed this prompt once and was denied, this
            // call is a silent no-op; the menu bar / Setup tab UI is what
            // carries the "grant it manually in System Settings" message for
            // that case.
            HotkeyMonitor.requestAccessibilityPermission()
            watchForAccessibilityGrant()
        }
    }

    /// Polls every 2s (not tighter — there's no urgency, and this must not
    /// spin) until Accessibility is granted, then starts the hotkey
    /// monitor and stops polling. Safe to leave running indefinitely if the
    /// user never grants permission during this run.
    private func watchForAccessibilityGrant() {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if HotkeyMonitor.hasAccessibilityPermission() {
                    TWLog.app.info("accessibility granted; starting hotkey monitor")
                    self.hasAccessibility = true
                    self.monitor.start()
                    return
                }
            }
        }
    }

    /// Whether Cloud mode currently has usable AWS credentials in the
    /// Keychain. Read fresh (not cached) on every call — a Keychain lookup is
    /// cheap, and this way saving/deleting credentials in Settings → Cloud is
    /// reflected immediately, without needing to observe the Keychain for
    /// changes. Used by the menu bar status text and the HUD note so the user
    /// can always tell whether Cloud cleanup is actually configured.
    func hasCloudCredentials() -> Bool {
        switch settings.cloudProvider {
        case .bedrock: return credentials.load() != nil
        case .openai: return openAIKey.load() != nil
        case .anthropic: return anthropicKey.load() != nil
        }
    }

    private func handle(_ action: HotkeyAction) async {
        switch action {
        case .start(let handsFree):
            // Set before `begin()`, because `begin()` publishes `.recording`
            // and `observePhases` reads this flag when it forwards that phase
            // to the HUD.
            self.handsFree = handsFree
            await session.begin()
        case .stop: await session.end()
        case .cancel: await session.cancel()
        }
    }

    private func observePhases() async {
        // `phaseStream` is a stored property of the `DictationSession` actor;
        // reading it across the actor boundary needs `await` even though the
        // stream itself never changes after init (the brief's reference code
        // omitted this and does not compile).
        let stream = await session.phaseStream
        for await p in stream {
            self.phase = p
            // The gesture only describes a recording. Clear it as soon as one
            // ends so a later phase can't inherit a stale "hands-free".
            if case .recording = p {} else { self.handsFree = false }
            // Cloud-with-no-credentials degrades every dictation to the raw
            // transcript with no rewriter error visible anywhere else (see
            // `NoCredentialsRewriter` above) — surface it here so the HUD
            // itself tells the user cleanup isn't happening, rather than
            // looking identical to a successful cleaned-up paste.
            let note: String? = (p != .idle && mode == .cloud && !hasCloudCredentials())
                ? "Cloud has no credentials — pasting the raw transcript, unedited"
                : nil
            hud.update(p, note: note, handsFree: handsFree)

            // Any new phase invalidates a previously scheduled auto-hide:
            // without this, starting a fresh dictation right after an
            // `.inserted`/`.error` would let that stale 1.5s timer hide the
            // HUD while the new recording is still in progress.
            hudHideTask?.cancel()
            hudHideTask = nil

            switch p {
            case .recording, .transcribing, .rewriting:
                hud.show()
            case .inserted, .error:
                hud.show()
                hudHideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self, !Task.isCancelled else { return }
                    self.hud.hide()
                }
            case .idle:
                hud.hide()
            }
        }
    }

    /// Called when Settings switches the speech-to-text source. The switch
    /// itself needs no work — the next dictation picks it up on its own — but
    /// selecting Apple for the first time must still get the user's Speech
    /// grant, and asking here means the prompt lands while they are looking at
    /// the setting rather than mid-dictation. A no-op once already decided.
    func sttSourceChanged() {
        guard settings.sttSource == .apple else { return }
        Task { _ = await AppleSpeechTranscriber.requestAuthorization() }
    }

    /// Local spawns llama-server; Cloud kills it to reclaim ~17GB of RAM and the GPU.
    func applyMode() async {
        TWLog.app.info("applying mode: \(String(describing: self.mode), privacy: .public)")
        switch mode {
        case .local:
            await engine.start()
        case .cloud:
            await engine.stop()
        }
        engineState = await engine.state
        TWLog.app.info("engine state: \(String(describing: self.engineState), privacy: .public)")
    }
}
