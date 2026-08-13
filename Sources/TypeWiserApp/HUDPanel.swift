import AppKit
import Observation
import SwiftUI
import TypeWiserCore

/// Floating status panel shown while dictating.
///
/// MUST NOT take focus: if it becomes key, the ⌘V we synthesize on release
/// pastes into the HUD rather than the user's app. Every property below is
/// chosen specifically to prevent that:
///   - `.nonactivatingPanel` in the style mask
///   - `becomesKeyOnlyIfNeeded = true`
///   - `level = .statusBar`
///   - `orderFrontRegardless()` in `show()` — never `makeKeyAndOrderFront`
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private let state = HUDState()
    /// Reads the current microphone RMS. Injected rather than depending on
    /// `AudioCapture` directly so the HUD stays testable and previewable
    /// without a microphone.
    private let level: @Sendable () async -> Float
    private var levelTask: Task<Void, Never>?

    init(level: @escaping @Sendable () async -> Float) {
        self.level = level
    }

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0,
                                    width: HUDMetrics.panelWidth,
                                    height: HUDMetrics.panelHeight),
                // Exactly these two, and no decorating masks. `.hudWindow` and
                // `.utilityWindow` both paint their own chrome — an opaque
                // sheet with square corners — behind the card, and
                // `.utilityWindow` is only valid alongside `.titled`, which
                // pulls in a title bar whose height also throws off the
                // content's position. `.borderless` is literally 0, so it is
                // documentation rather than a flag.
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = false
            // All three are required for the card's rounded corners to show
            // the desktop through them instead of a black box.
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false  // the card draws its own; the panel is transparent
            // The HUD is purely informational and must never intercept a
            // click. This also reinforces the focus rule above: the panel is
            // now incapable of swallowing the ⌘V we synthesize on release,
            // and the transparent margin around the card stays click-through.
            p.ignoresMouseEvents = true

            // A plain hosting view, deliberately NOT an NSHostingController
            // with `.preferredContentSize`: sizing the window to its content
            // is what made the HUD jump between phases (see `HUDMetrics`).
            // The panel is a fixed stage; the card sizes itself within it.
            p.contentView = NSHostingView(rootView: HUDView(state: state))
            panel = p
            reposition()
        }
        panel?.orderFrontRegardless()  // never makeKey — that would steal focus
    }

    /// Bottom-centred on the main screen. Called once, at creation: the panel
    /// is a fixed size, so its position never needs recomputing for content.
    ///
    /// The inset is subtracted because the panel's bottom edge sits that far
    /// below the card's — `bottomMargin` is the gap the user actually sees,
    /// between the screen's visible frame and the card.
    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - HUDMetrics.panelWidth / 2,
                                     y: f.minY + HUDMetrics.bottomMargin - HUDMetrics.shadowInset))
    }

    func hide() {
        stopLevelPolling()
        panel?.orderOut(nil)
    }

    func update(_ phase: SessionPhase, note: String? = nil, handsFree: Bool = false) {
        state.phase = phase
        state.note = note
        state.handsFree = handsFree

        if case .recording = phase {
            startLevelPolling()
        } else {
            // Levels freeze rather than reset: the waveform holds its last
            // shape through transcribing/rewriting instead of collapsing the
            // moment the user lets go of the key.
            stopLevelPolling()
        }
    }

    private func startLevelPolling() {
        guard levelTask == nil else { return }
        state.levels = []
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rms = await self.level()
                self.state.push(Waveform.normalize(rms))
                try? await Task.sleep(for: .seconds(1 / Waveform.pollHZ))
            }
        }
    }

    private func stopLevelPolling() {
        levelTask?.cancel()
        levelTask = nil
    }
}

@Observable
@MainActor
final class HUDState {
    var phase: SessionPhase = .idle
    /// Optional secondary line shown below the phase body — currently only
    /// used to warn that Cloud mode has no credentials, so cleanup silently
    /// isn't running. `nil` renders nothing extra.
    var note: String?
    /// Whether the current recording was latched by a double-tap. Only read
    /// during `.recording`, to distinguish a latch from a hold.
    var handsFree = false
    /// Normalized microphone levels, newest first, capped at the number of
    /// bars the waveform can draw. `WaveformView` puts index 0 on the centre
    /// line, so pushing to the front is what makes new sound bloom outward.
    var levels: [Float] = []

    func push(_ level: Float) {
        levels.insert(level, at: 0)
        if levels.count > Waveform.barsPerSide {
            levels.removeLast(levels.count - Waveform.barsPerSide)
        }
    }
}
