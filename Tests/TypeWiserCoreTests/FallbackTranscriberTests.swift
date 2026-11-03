import Foundation
import Testing
@testable import TypeWiserCore

@Suite struct FallbackTranscriberTests {
    private func pair(primaryError: Error? = nil, fallbackError: Error? = nil)
        -> (FallbackTranscriber, FakeWhisper, FakeWhisper) {
        let primary = FakeWhisper()
        primary.finalText = "from server"
        primary.finalError = primaryError
        let fallback = FakeWhisper()
        fallback.finalText = "from device"
        fallback.finalError = fallbackError
        return (FallbackTranscriber(primary: primary, fallback: fallback), primary, fallback)
    }

    @Test func healthyServerIsUsedAndDeviceIsNotTouched() async throws {
        let (t, _, fallback) = pair()
        #expect(try await t.transcribe(pcm16: [1]) == "from server")
        #expect(fallback.transcribeCount == 0)
    }

    /// The reported bug: Cloudflare answering 502 for a dead tunnel origin.
    @Test func serverErrorFallsBackToDevice() async throws {
        let (t, _, fallback) = pair(primaryError: WhisperError.http(502))
        #expect(try await t.transcribe(pcm16: [1]) == "from device")
        #expect(fallback.transcribeCount == 1)
    }

    @Test func unreachableServerFallsBackToDevice() async throws {
        let (t, _, _) = pair(primaryError: URLError(.cannotConnectToHost))
        #expect(try await t.transcribe(pcm16: [1]) == "from device")
    }

    /// A cancelled dictation must stay cancelled, not be re-run on-device.
    @Test func cancellationIsNotRetried() async {
        let (t, _, fallback) = pair(primaryError: WhisperError.cancelled)
        await #expect(throws: WhisperError.cancelled) { try await t.transcribe(pcm16: [1]) }
        #expect(fallback.transcribeCount == 0)
    }

    /// If on-device couldn't even run, the user should hear about the server
    /// they configured, not a Speech permission they never needed.
    @Test func fallbackThatCannotRunReportsTheServerError() async {
        let (t, _, _) = pair(primaryError: WhisperError.http(502),
                             fallbackError: AppleSpeechError.notAuthorized)
        await #expect(throws: WhisperError.http(502)) { try await t.transcribe(pcm16: [1]) }
    }

    /// If on-device ran and heard nothing, that is the more actionable error.
    @Test func fallbackThatHeardNothingReportsThat() async {
        let (t, _, _) = pair(primaryError: WhisperError.http(502),
                             fallbackError: AppleSpeechError.noSpeechDetected)
        await #expect(throws: AppleSpeechError.noSpeechDetected) { try await t.transcribe(pcm16: [1]) }
    }

    @Test func cancelReachesBoth() async {
        let (t, primary, fallback) = pair()
        await t.cancelInFlight()
        #expect(primary.cancelCount == 1)
        #expect(fallback.cancelCount == 1)
    }
}
