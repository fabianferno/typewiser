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
    case start, stop, cancel
}

/// Decides when a bare Fn hold means "dictate".
///
/// Two guards, both load-bearing:
///  - `minimumHold` — macOS users tap Fn incidentally; a tap must be inert.
///  - `otherKeyDown` — macOS also sets the `.function` flag for Fn+F5 and the
///    arrow keys, so Fn must be held *alone* to start a recording.
public struct HotkeyStateMachine: Sendable {
    private enum State: Sendable { case idle, pending(since: TimeInterval), recording, aborted }

    private var state: State = .idle
    private let minimumHold: TimeInterval

    public init(minimumHold: TimeInterval = 0.15) {
        self.minimumHold = minimumHold
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyAction? {
        guard input.functionHeld else {
            let wasRecording: Bool
            if case .recording = state { wasRecording = true } else { wasRecording = false }
            state = .idle
            return wasRecording ? .stop : nil
        }

        if input.otherKeyDown {
            if case .recording = state {
                state = .aborted
                return .cancel
            }
            state = .aborted
            return nil
        }

        switch state {
        case .idle:
            state = .pending(since: input.timestamp)
            return nil
        case .pending(let since):
            guard input.timestamp - since >= minimumHold else { return nil }
            state = .recording
            return .start
        case .recording, .aborted:
            return nil
        }
    }
}
