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
