import AppKit
import ApplicationServices
import Foundation

/// Bridges global NSEvent taps into the pure `HotkeyStateMachine`.
///
/// All decision logic lives in the state machine so it can be tested; this class
/// is only plumbing.
public final class HotkeyMonitor: @unchecked Sendable {
    private var machine = HotkeyStateMachine()
    private let onAction: @Sendable (HotkeyAction) -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var otherKeyDown = false

    public init(onAction: @escaping @Sendable (HotkeyAction) -> Void) {
        self.onAction = onAction
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        // `kAXTrustedCheckOptionPrompt` is a C global (`CFStringRef`) the
        // compiler flags as not concurrency-safe to read under Swift 6
        // strict checking. Its value is the documented, stable literal
        // "AXTrustedCheckOptionPrompt" (ApplicationServices never changes
        // this key), so using the literal sidesteps the global entirely.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Deep link into the exact System Settings pane the user needs. Once
    /// macOS has shown the Accessibility prompt once and been denied, it will
    /// NEVER show it again for this process — `requestAccessibilityPermission()`
    /// silently becomes a no-op — so this is the only remaining way to get the
    /// user to the toggle.
    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether the global monitors are currently registered. `false` both
    /// before the first successful `start()` and whenever `start()` has
    /// refused to register because Accessibility isn't trusted yet.
    public var isMonitoring: Bool { flagsMonitor != nil }

    public func start() {
        guard flagsMonitor == nil else { return }

        // DO NOT remove this guard. Established by bisection with a real,
        // Accessibility-denied user: calling
        // `NSEvent.addGlobalMonitorForEvents` at all — for either
        // [.keyDown, .keyUp] or [.flagsChanged], even with a completely
        // empty handler — while Accessibility permission is NOT granted
        // poisons this app's event delivery so that the MenuBarExtra
        // popover silently stops opening. That popover is the only UI the
        // app has to request permission or reach Settings, so registering
        // here while untrusted deadlocks the user out of the app entirely.
        // Every other candidate (dynamic systemImage, a Settings scene,
        // SettingsLink, a 50ms Timer, AVAudioEngine(), the `ps` shell-out,
        // spawning llama-server) was ruled out one at a time; only this
        // registration reproduces the failure. Skipping registration until
        // `AXIsProcessTrusted()` is true is the fix — `AppModel` is
        // responsible for calling `start()` again once permission is
        // granted (it polls for this).
        guard AXIsProcessTrusted() else { return }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyDown = (event.type == .keyDown)
            self?.feed(functionHeld: event.modifierFlags.contains(.function),
                       timestamp: event.timestamp)
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.feed(functionHeld: event.modifierFlags.contains(.function),
                       timestamp: event.timestamp)
        }

        // flagsChanged only fires on transitions, so a hold emits no further
        // events. Poll so the 150ms threshold can actually be crossed.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = NSEvent.modifierFlags.contains(.function)
            self.feed(functionHeld: held, timestamp: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func feed(functionHeld: Bool, timestamp: TimeInterval) {
        let input = HotkeyInput(functionHeld: functionHeld,
                                otherKeyDown: otherKeyDown,
                                timestamp: timestamp)
        if let action = machine.handle(input) { onAction(action) }
    }

    public func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
