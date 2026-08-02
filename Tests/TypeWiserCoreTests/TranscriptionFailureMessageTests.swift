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

    @Test func unknownErrorsFallBackToTheirDescription() {
        struct Odd: Error {}
        let text = TranscriptionFailureMessage.text(for: Odd(), input: builtIn)
        #expect(text.contains("Transcription failed"))
    }
}
