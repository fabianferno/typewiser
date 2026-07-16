import ApplicationServices
import Testing
@testable import TypeWiserCore

@Test func permissionCheckDoesNotCrash() {
    _ = HotkeyMonitor.hasAccessibilityPermission()
}

@Test func monitorStartsAndStopsCleanly() {
    let m = HotkeyMonitor(onAction: { _ in })
    m.start()
    m.stop()
    m.stop()  // idempotent
}

// The CI/dev machine this runs on is expected to be untrusted (no
// Accessibility grant for the `swift test` process). If some environment is
// somehow already trusted, `start()` registering monitors there is correct
// behavior, not a bug — so this test verifies the untrusted precondition
// itself and skips rather than asserting something environment-dependent.
@Test func startDoesNotRegisterMonitorsWhenNotTrusted() {
    guard !AXIsProcessTrusted() else {
        // Environment is trusted; the "refuse while untrusted" behavior
        // being tested here doesn't apply. Skip rather than flake.
        return
    }

    let m = HotkeyMonitor(onAction: { _ in })
    #expect(!m.isMonitoring, "must not be monitoring before start() is ever called")
    m.start()
    #expect(!m.isMonitoring, "start() must refuse to register global monitors while Accessibility is denied")
    m.stop()
}

@Test func startIsIdempotentAndStopIsSafeWhenNothingRegistered() {
    guard !AXIsProcessTrusted() else { return }

    let m = HotkeyMonitor(onAction: { _ in })
    m.start()
    m.start()  // calling again while still untrusted must not crash or change state
    #expect(!m.isMonitoring)

    // stop() with nothing ever registered must be safe (no-op), repeatedly.
    m.stop()
    m.stop()
    #expect(!m.isMonitoring)
}
