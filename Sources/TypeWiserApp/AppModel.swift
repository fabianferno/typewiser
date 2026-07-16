import AppKit
import Foundation
import Observation
import TypeWiserCore

@MainActor
@Observable
final class AppModel {
    var phase: SessionPhase = .idle
    var mode: EngineMode {
        didSet {
            settings.mode = mode
            Task { await applyMode() }
        }
    }
    var engineState: EngineState = .stopped

    let settings = SettingsStore()
    private let credentials = KeychainCredentialStore()
    private let engine = EngineManager()
    private let audio = AudioCapture()
    private let whisper = WhisperClient(endpoint: URL(string: "https://whisper.crevn.xyz/inference")!)
    private var session: DictationSession!
    private var monitor: HotkeyMonitor!
    private let hud = HUDController()
    /// Pending auto-hide scheduled after `.inserted`/`.error`. Cancelled the
    /// instant another phase arrives so a new dictation started inside the
    /// 1.5s window can't have this stale timer yank the HUD back down.
    private var hudHideTask: Task<Void, Never>?

    init() {
        // A previous run that crashed or was force-quit never got to run
        // `stop()`, so its ~17GB llama-server child may still be resident.
        // Reap it before we possibly spawn a fresh one below.
        EngineManager.terminateOrphanedProcessIfPresent()

        // Belt-and-suspenders for the *normal* quit path: `stop()` (called
        // from `applyMode()`/deinit-adjacent paths) already terminates our
        // child, but if that ever doesn't run in time, this notification
        // fires as part of app termination and reaps the same pidfile-
        // recorded process directly — no MainActor/actor hop required, so
        // it can't be skipped by the app exiting before an async Task runs.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            EngineManager.terminateOrphanedProcessIfPresent()
        }

        self.mode = settings.mode
        let settings = self.settings
        let credentials = self.credentials

        session = DictationSession(
            audio: audio,
            whisper: whisper,
            rewriter: {
                switch settings.mode {
                case .local:
                    return LocalLlamaRewriter()
                case .cloud:
                    guard let c = credentials.load() else { return LocalLlamaRewriter() }
                    return BedrockRewriter(credentials: c)
                }
            },
            context: AXContextReader(nameDictionary: settings.nameDictionary),
            injector: TextInjector(),
            options: { settings.options }
        )

        monitor = HotkeyMonitor { [weak self] action in
            Task { @MainActor in await self?.handle(action) }
        }

        Task { await observePhases() }
        Task { await applyMode() }
        monitor.start()
    }

    private func handle(_ action: HotkeyAction) async {
        switch action {
        case .start: await session.begin()
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
            hud.update(p)

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

    /// Local spawns llama-server; Cloud kills it to reclaim ~17GB of RAM and the GPU.
    func applyMode() async {
        switch mode {
        case .local:
            await engine.start()
        case .cloud:
            await engine.stop()
        }
        engineState = await engine.state
    }
}
