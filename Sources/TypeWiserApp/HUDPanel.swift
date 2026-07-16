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

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
                styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = false
            p.contentView = NSHostingView(rootView: HUDView(state: state))
            panel = p
        }
        reposition()
        panel?.orderFrontRegardless()  // never makeKey — that would steal focus
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                     y: f.minY + 120))
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func update(_ phase: SessionPhase) {
        state.phase = phase
    }
}

@Observable
@MainActor
final class HUDState {
    var phase: SessionPhase = .idle
}
