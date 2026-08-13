import AppKit
import CoreGraphics
import Foundation

public protocol Pasteboarding: Sendable {
    func snapshot() -> [[String: Data]]
    func set(string: String)
    func restore(_ snapshot: [[String: Data]])
}

public struct SystemPasteboard: Pasteboarding {
    public init() {}

    public func snapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type.rawValue] = d }
            }
            return dict
        }
    }

    public func set(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    public func restore(_ snapshot: [[String: Data]]) {
        NSPasteboard.general.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (raw, data) in dict { item.setData(data, forType: .init(raw)) }
            return item
        }
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }
}

public protocol KeystrokeSending: Sendable {
    func sendCommandV()
}

public struct SystemKeystrokeSender: KeystrokeSending {
    public init() {}

    public func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9  // ANSI 'V'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Inserts text into whatever app has focus by borrowing the clipboard.
public struct TextInjector: Sendable {
    private let pasteboard: Pasteboarding
    private let keys: KeystrokeSending
    private let restoreDelay: Duration
    private let sound: SoundPlaying?

    public init(pasteboard: Pasteboarding = SystemPasteboard(),
                keys: KeystrokeSending = SystemKeystrokeSender(),
                restoreDelay: Duration = .milliseconds(200),
                sound: SoundPlaying? = SystemSoundPlayer(.paste)) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.restoreDelay = restoreDelay
        self.sound = sound
    }

    public func insert(_ text: String) async {
        guard !text.isEmpty else { return }
        let saved = pasteboard.snapshot()
        pasteboard.set(string: text)
        keys.sendCommandV()
        sound?.play()
        // The paste is asynchronous in the target app. Restoring immediately
        // races it and pastes the *old* clipboard contents instead.
        try? await Task.sleep(for: restoreDelay)
        pasteboard.restore(saved)
    }
}
