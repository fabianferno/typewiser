import AppKit
import Foundation

/// A short audible cue. Injected everywhere it is used so tests can observe
/// cues without making the test runner beep.
public protocol SoundPlaying: Sendable {
    func play()
}

/// The moments in a dictation cycle that deserve a sound, named by what they
/// mean rather than by which .aiff they map to.
public enum SoundCue: Sendable {
    /// Text just went into the focused app.
    case paste
    /// The hotkey was released before enough audio existed to transcribe.
    case tooShort

    /// One of the built-in macOS alert sounds in /System/Library/Sounds.
    var systemSoundName: String {
        switch self {
        case .paste: "Morse"
        case .tooShort: "Ping"
        }
    }
}

public struct SystemSoundPlayer: SoundPlaying {
    private let name: String
    private let isEnabled: @Sendable () -> Bool

    /// `isEnabled` is read at play time, not at construction: the injector and
    /// session that own these players are built once at launch, so a value
    /// captured here would leave the Settings checkbox needing an app restart.
    public init(_ cue: SoundCue, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.name = cue.systemSoundName
        self.isEnabled = isEnabled
    }

    public func play() {
        guard isEnabled() else { return }
        // A fresh NSSound each time: reusing one instance swallows the cue when
        // two land close together, because the sound is still playing.
        NSSound(named: name)?.play()
    }
}
