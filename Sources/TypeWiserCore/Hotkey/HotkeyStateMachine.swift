import Foundation

public struct HotkeyInput: Sendable, Equatable {
    public let functionHeld: Bool
    public let otherKeyDown: Bool
    public let timestamp: TimeInterval

    public init(functionHeld: Bool, otherKeyDown: Bool, timestamp: TimeInterval) {
        self.functionHeld = functionHeld
        self.otherKeyDown = otherKeyDown
        self.timestamp = timestamp
    }
}

public enum HotkeyAction: Sendable, Equatable {
    /// `handsFree` distinguishes a latched recording (double-tap) from a held
    /// one. Nothing in the recording pipeline cares; it exists so the HUD can
    /// say which gesture the user is in, because a latch they didn't notice
    /// would otherwise record indefinitely and look identical to a hold.
    case start(handsFree: Bool)
    case stop, cancel
}

/// Decides when a bare Fn hold means "dictate", and when a double-tap means
/// "dictate hands-free until I say stop".
///
/// Two gestures share the key:
///  - **Hold** — Fn held alone past `minimumHold` records; releasing stops.
///  - **Double-tap** — a tap (press+release under `minimumHold`) arms a
///    `doubleTapWindow`; a press inside that window latches. Latched
///    recording ignores Fn releases and other keys entirely, and ends on the
///    next Fn press.
///
/// Two guards, both load-bearing:
///  - `minimumHold` — macOS users tap Fn incidentally; a lone tap must be inert.
///  - `otherKeyDown` — macOS also sets the `.function` flag for Fn+F5 and the
///    arrow keys, so Fn must be held *alone* to start a held recording.
///
/// IMPORTANT — callers MUST feed periodic "still held" inputs while the key
/// is down: macOS `flagsChanged` events only fire on transitions, so a bare
/// hold with no intermediate input never crosses `minimumHold` and `.start`
/// will never fire. `HotkeyMonitor` supplies these ticks via a 50ms polling
/// `Timer`. This is not optional plumbing — without it, dictation cannot
/// start no matter how long Fn is held.
public struct HotkeyStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        case pending(since: TimeInterval)
        /// A completed tap, waiting to see whether a second press turns it
        /// into a double-tap. Expires after `doubleTapWindow`.
        case tapped(at: TimeInterval)
        case recording
        /// Latched, but Fn is still down from the press that latched it. Held
        /// separately from `.latched` because the poll keeps reporting that
        /// press for as long as the user holds it, and a latch that treated
        /// its own press as the stop press would end instantly.
        case latching
        case latched
        /// Inert until Fn comes back up. Reached by the Fn+other-key guard,
        /// and by the press that stops a latched recording — otherwise
        /// *holding* that stop press would roll straight into a new
        /// hold-to-talk recording.
        case awaitingRelease
    }

    private var state: State = .idle
    private let minimumHold: TimeInterval
    private let doubleTapWindow: TimeInterval

    public init(minimumHold: TimeInterval = 0.15, doubleTapWindow: TimeInterval = 0.4) {
        self.minimumHold = minimumHold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyAction? {
        guard input.functionHeld else { return handleRelease(input) }

        // Hands-free means the user's hands are on the keyboard doing other
        // things. The Fn+other-key guard, which exists to keep chords like
        // Fn+F5 from dictating, must not reach a latched recording.
        switch state {
        case .latching: return nil
        case .latched: return input.otherKeyDown ? nil : stopLatch()
        default: break
        }

        if input.otherKeyDown {
            if case .recording = state {
                state = .awaitingRelease
                return .cancel
            }
            state = .awaitingRelease
            return nil
        }

        switch state {
        case .idle:
            state = .pending(since: input.timestamp)
            return nil
        case .pending(let since):
            guard input.timestamp - since >= minimumHold else { return nil }
            state = .recording
            return .start(handsFree: false)
        case .tapped(let at):
            // Deliberately latches on press-down, so tap-then-hold latches
            // rather than starting a hold-to-talk recording.
            guard input.timestamp - at <= doubleTapWindow else {
                state = .pending(since: input.timestamp)
                return nil
            }
            state = .latching
            return .start(handsFree: true)
        case .recording, .awaitingRelease, .latching, .latched:
            return nil
        }
    }

    private mutating func stopLatch() -> HotkeyAction {
        state = .awaitingRelease
        return .stop
    }

    private mutating func handleRelease(_ input: HotkeyInput) -> HotkeyAction? {
        switch state {
        case .recording:
            state = .idle
            return .stop
        case .latching:
            // The double-tap's own second press has come back up. From here
            // on, an Fn press means stop.
            state = .latched
            return nil
        case .latched:
            // Releasing Fn never ends a latch — that is what hands-free means.
            return nil
        case .pending(let since):
            // Only a *short* press is a tap. A press that ran past the
            // threshold was a real hold the poll never sampled (see
            // `holdWithoutIntermediateTickIsInertByDesign`); arming the
            // double-tap window off it would be a false positive.
            state = input.timestamp - since < minimumHold ? .tapped(at: input.timestamp) : .idle
            return nil
        case .tapped(let at):
            if input.timestamp - at > doubleTapWindow { state = .idle }
            return nil
        case .idle, .awaitingRelease:
            state = .idle
            return nil
        }
    }
}
