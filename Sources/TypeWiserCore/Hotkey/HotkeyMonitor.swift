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

    public func start() {
        guard flagsMonitor == nil else { return }

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
