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
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: false))  // crossed threshold
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
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: false))
    #expect(m.handle(fn(true, 0.30, other: true)) == .cancel)
    #expect(m.handle(fn(false, 0.40)) == nil, "already cancelled — no stop")
}

@Test func startIsEmittedOnlyOnce() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: false))
    #expect(m.handle(fn(true, 0.30)) == nil)
    #expect(m.handle(fn(true, 0.40)) == nil)
}

@Test func secondHoldWorksAfterFirstCompletes() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(true, 0.2))
    #expect(m.handle(fn(false, 0.5)) == .stop)
    _ = m.handle(fn(true, 1.0))
    #expect(m.handle(fn(true, 1.2)) == .start(handsFree: false), "state machine must reset")
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
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: false))
    #expect(m.handle(fn(true, 0.30, other: true)) == .cancel)
    _ = m.handle(fn(false, 0.40))
    _ = m.handle(fn(true, 1.0))
    #expect(m.handle(fn(true, 1.2)) == .start(handsFree: false), "state machine must reset after a cancel")
}

// MARK: - Hands-free latch (double-tap Fn)

@Test func doubleTapLatches() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(false, 0.05)) == nil, "first tap is still inert on its own")
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true),
            "second press inside the window latches, on press-down")
}

// The second press of the double-tap has to be released like any other key
// press. If that release stopped the recording, the gesture would be useless.
@Test func latchSurvivesReleaseOfTheSecondTap() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true))
    #expect(m.handle(fn(false, 0.25)) == nil, "releasing Fn must not end a latched recording")
    #expect(m.handle(fn(false, 5.0)) == nil, "…nor must any amount of idle polling")
}

@Test func pressStopsALatchedRecording() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true))
    _ = m.handle(fn(false, 0.25))
    #expect(m.handle(fn(true, 3.0)) == .stop, "any Fn press ends hands-free mode")
}

// Holding the stop press must not immediately roll into a fresh hold-to-talk
// recording — the machine has to wait for Fn to come back up first.
@Test func holdingTheStopPressDoesNotRestart() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    _ = m.handle(fn(true, 0.20))
    _ = m.handle(fn(false, 0.25))
    #expect(m.handle(fn(true, 3.0)) == .stop)
    #expect(m.handle(fn(true, 3.5)) == nil, "still held, well past the threshold — must stay inert")
    #expect(m.handle(fn(false, 3.6)) == nil)
    _ = m.handle(fn(true, 4.0))
    #expect(m.handle(fn(true, 4.2)) == .start(handsFree: false), "…and hold-to-talk works again after")
}

// The whole point of hands-free: you are typing, or your hands are elsewhere.
// The Fn+other-key guard that cancels a *held* recording must not apply.
@Test func typingDoesNotCancelALatchedRecording() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true))
    _ = m.handle(fn(false, 0.25))
    #expect(m.handle(fn(false, 1.0, other: true)) == nil, "ordinary typing must not cancel")
    #expect(m.handle(fn(true, 2.0, other: true)) == nil, "nor Fn+key chords like Fn+F5")
    #expect(m.handle(fn(true, 3.0)) == .stop, "…and a bare Fn press still stops it")
}

@Test func lapsedTapDoesNotLatch() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(false, 0.05)) == nil)
    #expect(m.handle(fn(false, 0.60)) == nil, "poll tick past the 400ms window expires the tap")
    #expect(m.handle(fn(true, 1.0)) == nil, "a much later press is a fresh press, not a double-tap")
    #expect(m.handle(fn(true, 1.2)) == .start(handsFree: false), "it becomes a normal hold instead")
}

// Even with no intervening poll tick, a press arriving after the window has
// passed must be treated as a fresh press.
@Test func lateSecondPressDoesNotLatch() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(false, 0.05)) == nil)
    #expect(m.handle(fn(true, 0.80)) == nil, "past the window — a fresh press, no latch")
    #expect(m.handle(fn(true, 1.0)) == .start(handsFree: false))
}

// Chosen deliberately (see the design): a press inside the window latches on
// press-down, so tap-then-hold latches rather than starting hold-to-talk.
@Test func tapThenHoldAlsoLatches() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true))
    #expect(m.handle(fn(true, 0.50)) == nil, "holding past the threshold emits nothing further")
    #expect(m.handle(fn(false, 1.00)) == nil, "and releasing leaves it latched")
}

// A hold-to-talk recording ends on release; that release is not a "tap", so
// it must not arm the double-tap window.
@Test func releaseFromRecordingDoesNotArmTheLatch() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: false))
    #expect(m.handle(fn(false, 0.50)) == .stop)
    #expect(m.handle(fn(true, 0.60)) == nil, "a press soon after must not latch")
    #expect(m.handle(fn(true, 0.80)) == .start(handsFree: false))
}

// An aborted Fn+key chord ends with an Fn release too. Same rule.
@Test func releaseFromAbortedDoesNotArmTheLatch() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0))
    _ = m.handle(fn(true, 0.20, other: true))
    #expect(m.handle(fn(false, 0.30)) == nil)
    #expect(m.handle(fn(true, 0.40)) == nil, "must not latch off an aborted chord")
    #expect(m.handle(fn(true, 0.60)) == .start(handsFree: false))
}

// A press that crossed `minimumHold` without an intermediate tick releases
// from `pending` but is not a tap — it was a real hold that the poll simply
// never sampled. Arming the latch off it would be a false positive.
@Test func longPressWithoutTickDoesNotArmTheLatch() {
    var m = HotkeyStateMachine()
    #expect(m.handle(fn(true, 0.0)) == nil)
    #expect(m.handle(fn(false, 0.50)) == nil, "no tick, so no .start — and no tap either")
    #expect(m.handle(fn(true, 0.60)) == nil, "so the next press must not latch")
}

@Test func latchWorksAgainAfterBeingStopped() {
    var m = HotkeyStateMachine()
    _ = m.handle(fn(true, 0.0)); _ = m.handle(fn(false, 0.05))
    #expect(m.handle(fn(true, 0.20)) == .start(handsFree: true))
    _ = m.handle(fn(false, 0.25))
    #expect(m.handle(fn(true, 3.0)) == .stop)
    _ = m.handle(fn(false, 3.1))
    _ = m.handle(fn(true, 4.0)); _ = m.handle(fn(false, 4.05))
    #expect(m.handle(fn(true, 4.20)) == .start(handsFree: true), "state machine must reset")
}
