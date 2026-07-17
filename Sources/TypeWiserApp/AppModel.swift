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
        self.hasAccessibility = HotkeyMonitor.hasAccessibilityPermission()

        // A previous run that crashed or was force-quit never got to run
        // `stop()`, so its ~17GB llama-server child may still be resident.
        // Reap it before we possibly spawn a fresh one below.
        EngineManager.terminateOrphanedProcessIfPresent()

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
                    // Cloud mode already killed llama-server (see `applyMode()`), so
                    // falling back to `LocalLlamaRewriter()` here would just point at a
                    // dead port: every dictation would silently degrade to the raw
                    // transcript via the `?? trimmed` fallback in `DictationSession.end()`
                    // — HUD still green, zero signal that cleanup stopped happening. Fail
                    // fast instead (no doomed network call), and let the menu bar / HUD
                    // note (see `hasCloudCredentials()` / `observePhases()`) make the
                    // missing configuration visible to the user.
                    guard let c = credentials.load() else { return NoCredentialsRewriter() }
                    return BedrockRewriter(credentials: c)
                }
            },
            context: { AXContextReader(nameDictionary: settings.nameDictionary) },
            injector: TextInjector(),
            options: { settings.options }
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
    func hasCloudCredentials() -> Bool { credentials.load() != nil }

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
            // Cloud-with-no-credentials degrades every dictation to the raw
            // transcript with no rewriter error visible anywhere else (see
            // `NoCredentialsRewriter` above) — surface it here so the HUD
            // itself tells the user cleanup isn't happening, rather than
            // looking identical to a successful cleaned-up paste.
            let note: String? = (p != .idle && mode == .cloud && !hasCloudCredentials())
                ? "Cloud has no credentials — pasting the raw transcript, unedited"
                : nil
            hud.update(p, note: note)

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
