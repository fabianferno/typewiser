import Foundation
import Testing
@testable import TypeWiserCore

@Suite struct TranscriptionFailureMessageTests {
    private let airpods = InputDevice(name: "Fabian's AirPods Pro", isBluetooth: true)
    private let builtIn = InputDevice(name: "MacBook Pro Microphone", isBluetooth: false)

    @Test func bluetoothNoSpeechNamesDeviceAndSuggestsBuiltIn() {
        let text = TranscriptionFailureMessage.text(for: AppleSpeechError.noSpeechDetected,
                                                    input: airpods)
        #expect(text.contains("Fabian's AirPods Pro"))
        #expect(text.contains("Bluetooth"))
        #expect(text.lowercased().contains("built-in"))
    }

    @Test func wiredNoSpeechNamesDeviceWithoutBluetoothAdvice() {
        let text = TranscriptionFailureMessage.text(for: AppleSpeechError.noSpeechDetected,
                                                    input: builtIn)
        #expect(text.contains("MacBook Pro Microphone"))
        #expect(!text.contains("Bluetooth"))
    }

    /// CoreAudio can fail to report a default input; the message must still be
    /// useful rather than naming a device we do not actually know.
    @Test func noSpeechWithUnknownDeviceStaysGeneric() {
        let text = TranscriptionFailureMessage.text(for: AppleSpeechError.noSpeechDetected,
                                                    input: nil)
        #expect(text.lowercased().contains("microphone"))
        #expect(!text.contains("“"))
    }

    /// A permission or availability problem is NOT a microphone problem, so it
    /// must not be dressed up as one — that would send the user to the wrong
    /// place in System Settings.
    @Test func nonSpeechErrorsDoNotBlameTheMicrophone() {
        let notAuthorized = TranscriptionFailureMessage.text(for: AppleSpeechError.notAuthorized,
                                                             input: airpods)
        #expect(notAuthorized.contains("Privacy"))
        #expect(!notAuthorized.contains("AirPods"))

        let unavailable = TranscriptionFailureMessage.text(for: AppleSpeechError.unavailable,
                                                           input: airpods)
        #expect(unavailable.lowercased().contains("unavailable"))
        #expect(!unavailable.contains("AirPods"))
    }

    /// The failure the HUD used to render as a raw nested `NSError` dump
    /// ("Error Domain=kLSRErrorDomain Code=102 … UserInfo={…"). It must name
    /// the accent in words and point at the two things that actually fix it.
    @Test func missingModelNamesTheAccentAndBothFixes() {
        let text = TranscriptionFailureMessage.text(for: AppleSpeechError.modelNotInstalled(locale: "en_GB"),
                                                    input: airpods)
        #expect(text.contains("United Kingdom"), "the user cannot act on a raw locale identifier")
        #expect(text.contains("Dictation"), "should point at where the language is installed")
        #expect(text.lowercased().contains("accent"), "switching accent is the faster fix, and must be offered")
        #expect(!text.contains("AirPods"), "a missing model is not a microphone problem")
        #expect(!text.contains("Domain="), "the raw NSError must not reach the HUD")
    }

    /// An unrecognised locale identifier must still produce a usable message
    /// rather than losing the one detail the user needs.
    @Test func missingModelFallsBackToTheRawLocaleIdentifier() {
        let text = TranscriptionFailureMessage.text(for: AppleSpeechError.modelNotInstalled(locale: "zz_ZZ"),
                                                    input: nil)
        #expect(text.contains("zz_ZZ"))
    }

    @Test func unknownErrorsFallBackToTheirDescription() {
        struct Odd: Error {}
        let text = TranscriptionFailureMessage.text(for: Odd(), input: builtIn)
        #expect(text.contains("Transcription failed"))
    }
}
