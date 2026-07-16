import Foundation
import Testing
@testable import TypeWiserCore

private func fn(_ held: Bool, _ t: TimeInterval, other: Bool = false) -> HotkeyInput {
    HotkeyInput(functionHeld: held, otherKeyDown: other, timestamp: t)
}

@Test func holdPastThresholdStartsThenReleaseStops() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)      // pressed, not yet past threshold
    #expect(m.handle(fn(true, 0.10)) == nil)     // still under 150ms
    #expect(m.handle(fn(true, 0.20)) == .start)  // crossed threshold
    #expect(m.handle(fn(false, 1.00)) == .stop)
}

@Test func quickTapDoesNothing() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(false, 0.05)) == nil, "a tap under 150ms must be inert")
}

@Test func otherKeyPreventsStart() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(true, 0.20, other: true)) == nil, "Fn+F5 must never dictate")
    #expect(m.handle(fn(false, 0.30)) == nil)
}

@Test func otherKeyAfterStartCancels() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(true, 0.20)) == .start)
    #expect(m.handle(fn(true, 0.30, other: true)) == .cancel)
    #expect(m.handle(fn(false, 0.40)) == nil, "already cancelled — no stop")
}

@Test func startIsEmittedOnlyOnce() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(true, 0.20)) == .start)
    #expect(m.handle(fn(true, 0.30)) == nil)
    #expect(m.handle(fn(true, 0.40)) == nil)
}

@Test func secondHoldWorksAfterFirstCompletes() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(true, 0.2))
    #expect(m.handle(fn(false, 0.5)) == .stop)
    _ = m.handle(fn(true, 1.0))
    #expect(m.handle(fn(true, 1.2)) == .start, "state machine must reset")
}

// Pins a cross-component contract: the state machine only crosses
// `minimumHold` when it receives an intermediate "still held" input while
// Fn is down. macOS `flagsChanged` events fire only on transitions, so a
// bare press-then-release with no tick in between must be inert here even
// though the hold is well past the threshold — `HotkeyMonitor` (Task 15)
// is the component responsible for supplying those ticks, via a 50ms
// polling `Timer` that samples `NSEvent.modifierFlags` while Fn is held.
// If that polling timer is ever removed, this test still passes but
// dictation stops working entirely — it is guarding a contract between
// this state machine and `HotkeyMonitor`, not documenting a bug.
@Test func holdWithoutIntermediateTickIsInertByDesign() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(false, 0.5)) == nil, "no intermediate tick means no .start, so no .stop either")
}

// From `aborted` (Fn+other-key, never started), releasing the OTHER key
// while Fn stays held must not retroactively start dictating — the Fn+F5
// guard has to hold until Fn itself comes up.
@Test func abortedStaysInertAfterOtherKeyReleases() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(true, 0.20, other: true)) == nil, "Fn+F5 aborts")
    #expect(m.handle(fn(true, 0.30)) == nil, "other key released, Fn still held — must not start")
    #expect(m.handle(fn(true, 0.50)) == nil, "still inert even well past the threshold")
    #expect(m.handle(fn(false, 0.60)) == nil, "Fn released — never started, so no stop")
}

@Test func secondHoldWorksAfterCancel() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(true, 0.20)) == .start)
    #expect(m.handle(fn(true, 0.30, other: true)) == .cancel)
    _ = m.handle(fn(false, 0.40))
    _ = m.handle(fn(true, 1.0))
    #expect(m.handle(fn(true, 1.2)) == .start, "state machine must reset after a cancel")
}
