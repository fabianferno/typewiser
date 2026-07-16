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
