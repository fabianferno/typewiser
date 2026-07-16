import Foundation
import Testing
@testable import TypeWiserCore

/// `MockProtocol` (see Support/MockProtocol.swift) keys its handler and
/// request counter per test id, generated fresh per test below via `UUID`.
/// That means no state is shared across tests — including tests in other
/// suites (e.g. `LocalLlamaRewriterTests`) that Swift Testing may schedule
/// concurrently with this one — so no `.serialized` trait is needed here.
struct WhisperClientTests {
    private func makeClient(delay: Duration = .zero,
                            body: String = #"{"text":" hello world\n"}"#) -> (client: WhisperClient, id: String) {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in
            if delay != .zero { try? await Task.sleep(for: delay) }
            return (200, Data(body.utf8))
        }
        let client = WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                                   session: session)
        return (client, id)
    }

    @Test func trimsLeadingSpaceAndTrailingNewline() async throws {
        let (c, id) = makeClient()
        defer { MockProtocol.unregister(id: id) }
        let text = try await c.transcribe(pcm16: [0, 1, 2])
        #expect(text == "hello world")
    }

    @Test func tryTranscribeReturnsNilWhileBusy() async throws {
        let (c, id) = makeClient(delay: .milliseconds(400))
        defer { MockProtocol.unregister(id: id) }
        async let first = c.transcribe(pcm16: [0])
        try await Task.sleep(for: .milliseconds(50))
        let second = try await c.tryTranscribe(pcm16: [0])
        #expect(second == nil, "interim must skip, never queue — the server has one slot")
        _ = try await first
        #expect(MockProtocol.requestCount(id: id) == 1)
    }

    @Test func transcribeCancelsInFlightInterim() async throws {
        let (c, id) = makeClient(delay: .milliseconds(400))
        defer { MockProtocol.unregister(id: id) }
        async let interim: String? = c.tryTranscribe(pcm16: [0])
        try await Task.sleep(for: .milliseconds(50))
        let final = try await c.transcribe(pcm16: [1])
        #expect(final == "hello world")
        _ = try? await interim
    }

    @Test func throwsOnNon200() async throws {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in (503, Data()) }
        defer { MockProtocol.unregister(id: id) }
        let c = WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                              session: session)
        await #expect(throws: WhisperError.self) { try await c.transcribe(pcm16: [0]) }
    }

    @Test func bodyIsMultipartWithWavFile() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var seenType = ""
        let session = MockProtocol.makeSession(id: id) { req in
            seenType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            return (200, Data(#"{"text":" ok\n"}"#.utf8))
        }
        defer { MockProtocol.unregister(id: id) }
        let c = WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                              session: session)
        _ = try await c.transcribe(pcm16: [0])
        #expect(seenType.hasPrefix("multipart/form-data; boundary="))
    }

    /// Regression test for a reentrancy race in the naive single-flight design: a
    /// cancelled interim's `run()` call suspends on `await task.value` and, once its
    /// (still in-flight, unaware-of-cancellation) network call eventually resolves,
    /// resumes and runs its own `defer { inFlight = nil }`. If that defer clears
    /// `inFlight` unconditionally, it can wipe out a *newer* request that a later
    /// `transcribe`/`tryTranscribe` call already installed — even though that newer
    /// request is still genuinely in flight. That would let a third request start
    /// against a server with exactly one inference slot, exactly the bug single-flight
    /// exists to prevent.
    @Test func staleCancelledRunMustNotClearNewerInFlight() async throws {
        let (c, id) = makeClient(delay: .milliseconds(300))
        defer { MockProtocol.unregister(id: id) }

        // t=0: interim starts, holds the one slot.
        async let interim: String? = c.tryTranscribe(pcm16: [0])
        try await Task.sleep(for: .milliseconds(50))

        // t=50ms: final cancels the interim and takes the slot itself.
        async let final: String = c.transcribe(pcm16: [1])

        // t=320ms: the cancelled interim's mock response has already landed (its
        // 300ms timer started at t=0), so its `run()` has resumed and — if buggy —
        // already cleared `inFlight`. The final request (timer started at t=50ms,
        // 300ms delay) is still genuinely in flight until ~t=350ms.
        try await Task.sleep(for: .milliseconds(270))
        let duringFinal = try await c.tryTranscribe(pcm16: [2])
        #expect(duringFinal == nil, "a request is still genuinely in flight; a stale cancelled run must not have cleared it")

        #expect(try await final == "hello world")
        _ = try? await interim
        #expect(MockProtocol.requestCount(id: id) == 2, "the probe at t=320ms must have been skipped, not started as a third request")
    }
}
