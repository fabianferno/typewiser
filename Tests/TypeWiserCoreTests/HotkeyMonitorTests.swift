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
// somehow already trusted, `start()` registering there is correct behavior,
// not a bug — so this test verifies the untrusted precondition itself and
// skips rather than asserting something environment-dependent.
@Test func startRegistersNothingWhenNotTrusted() {
    guard !AXIsProcessTrusted() else {
        // Environment is trusted; the "refuse while untrusted" behavior
        // being tested here doesn't apply. Skip rather than flake.
        return
    }

    let m = HotkeyMonitor(onAction: { _ in })
    #expect(!m.isMonitoring, "must not be monitoring before start() is ever called")
    m.start()
    #expect(!m.isMonitoring, "start() must register nothing while Accessibility is denied")
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

/// Guards the fix for the bug that locked the user out of the app: an NSEvent
/// global monitor anywhere in `HotkeyMonitor` silently stops the
/// `MenuBarExtra(.window)` popover from opening, on the trusted path as much
/// as the untrusted one. Key events must come from the `CGEventTap` instead.
///
/// This is a source check because the failure is only observable in a real GUI
/// with a real permission grant — no unit test can see the popover not open,
/// which is exactly how this shipped twice.
@Test func hotkeyMonitorNeverUsesNSEventGlobalMonitors() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TypeWiserCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/TypeWiserCore/Hotkey/HotkeyMonitor.swift"),
        encoding: .utf8
    )

    let code = source
        .split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        .joined(separator: "\n")

    #expect(!code.contains("addGlobalMonitorForEvents"),
            "NSEvent global monitors kill the MenuBarExtra popover — use the CGEventTap")
}
