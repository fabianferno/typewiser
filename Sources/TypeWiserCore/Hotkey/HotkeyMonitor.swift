import AppKit
import ApplicationServices
import Foundation

/// Feeds the pure `HotkeyStateMachine` from two sources: a 50ms poll of the
/// current modifier flags (the Fn hold itself) and a listen-only `CGEventTap`
/// (whether some *other* key is also down).
///
/// All decision logic lives in the state machine so it can be tested; this class
/// is only plumbing.
public final class HotkeyMonitor: @unchecked Sendable {
    private var machine = HotkeyStateMachine()
    private let onAction: @Sendable (HotkeyAction) -> Void
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Written from the event tap callback and read by the poll timer. Both run
    /// on the main run loop, so there is no race despite the plain `Bool`.
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

    /// Whether the hotkey is currently being observed. `false` both before the
    /// first successful `start()` and whenever `start()` has refused to
    /// register because Accessibility isn't trusted yet.
    public var isMonitoring: Bool { pollTimer != nil }

    /// DO NOT reintroduce `NSEvent.addGlobalMonitorForEvents` here.
    ///
    /// Registering an NSEvent global monitor — for [.keyDown, .keyUp] or
    /// [.flagsChanged], even with an empty handler — silently stops this app's
    /// `MenuBarExtra(.window)` popover from opening. The popover is the app's
    /// only route to Settings or to a permission prompt, so this locks the
    /// user out of the app entirely.
    ///
    /// This was originally diagnosed as an *untrusted-only* problem and
    /// "fixed" by refusing to register while `!AXIsProcessTrusted()`. That
    /// conclusion was wrong, and the bug outlived it: the untrusted path was
    /// the only one ever verified, and it happens to be the path where the
    /// monitors are never registered at all. On the trusted path — the normal
    /// one, for any user who has actually granted Accessibility — the monitors
    /// do register and the popover is just as dead. Trust state is irrelevant;
    /// the monitors are the cause.
    ///
    /// A listen-only `CGEventTap` delivers the same key events through a
    /// CFRunLoop source instead of AppKit's event dispatch, and coexists with
    /// the popover. Verified by hand on macOS 26.5 (trusted): with the tap,
    /// both the popover and Fn-hold dictation work; swapping only the tap back
    /// for global monitors kills the popover again.
    public func start() {
        guard pollTimer == nil else { return }

        // Both an event tap and our synthesized ⌘V require Accessibility;
        // there is nothing useful to register without it. `AppModel` calls
        // `start()` again once permission is granted (it polls for this).
        guard AXIsProcessTrusted() else { return }

        startEventTap()

        // `NSEvent.modifierFlags` is a static read of the *current* modifier
        // state and needs no monitor of any kind. This poll is what lets a
        // bare Fn hold cross `minimumHold`: flag transitions alone emit no
        // events while the key is simply held down.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = NSEvent.modifierFlags.contains(.function)
            self.feed(functionHeld: held, timestamp: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Tracks whether a non-modifier key is down, which is the only thing the
    /// state machine needs key events for: macOS sets the `.function` flag for
    /// Fn+F5 and the arrow keys too, so Fn must be held *alone* to start a
    /// recording.
    ///
    /// Listen-only: the tap never modifies or swallows events, it only
    /// observes them.
    private func startEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                switch type {
                case .keyDown: me.otherKeyDown = true
                case .keyUp: me.otherKeyDown = false
                default: break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Tap creation can fail even when trusted (e.g. the grant was
            // revoked between the check and here). Dictation still works off
            // the poll alone; only the Fn+other-key guard is lost, so this
            // degrades rather than dying.
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = source
    }

    private func feed(functionHeld: Bool, timestamp: TimeInterval) {
        let input = HotkeyInput(functionHeld: functionHeld,
                                otherKeyDown: otherKeyDown,
                                timestamp: timestamp)
        if let action = machine.handle(input) { onAction(action) }
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = tapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            tapSource = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        otherKeyDown = false
    }
}
