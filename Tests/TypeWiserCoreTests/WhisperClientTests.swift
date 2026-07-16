import Foundation
import Testing
@testable import TypeWiserCore

/// Swift 6's "sending parameter" checker flags any `Task { self... }` closure
/// inside an overridden `URLProtocol` method — even with `self` declared
/// `@unchecked Sendable` — because it treats the method receiver specially.
/// Boxing the reference sidesteps that specific heuristic without weakening
/// concurrency checking anywhere else.
private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

/// Intercepts URLSession traffic so tests never touch the network.
final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}

    override func startLoading() {
        MockProtocol.requestCount += 1
        let req = request
        let box = UnsafeBox(value: self)
        Task {
            let (code, data) = await (MockProtocol.handler?(req) ?? (200, Data()))
            let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            let this = box.value
            this.client?.urlProtocol(this, didReceive: resp, cacheStoragePolicy: .notAllowed)
            this.client?.urlProtocol(this, didLoad: data)
            this.client?.urlProtocolDidFinishLoading(this)
        }
    }
}

/// `MockProtocol.handler` / `.requestCount` are process-global mutable state
/// shared by every test below. Swift Testing runs `@Test` functions in a suite
/// concurrently by default, which would let tests stomp on each other's
/// handler/counter; `.serialized` forces them to run one at a time so each
/// test's `makeClient` setup is observed only by that test.
@Suite(.serialized)
struct WhisperClientTests {
    private func makeClient(delay: Duration = .zero, body: String = #"{"text":" hello world\n"}"#) -> WhisperClient {
        MockProtocol.requestCount = 0
        MockProtocol.handler = { _ in
            if delay != .zero { try? await Task.sleep(for: delay) }
            return (200, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        return WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                             session: URLSession(configuration: cfg))
    }

    @Test func trimsLeadingSpaceAndTrailingNewline() async throws {
        let c = makeClient()
        let text = try await c.transcribe(pcm16: [0, 1, 2])
        #expect(text == "hello world")
    }

    @Test func tryTranscribeReturnsNilWhileBusy() async throws {
        let c = makeClient(delay: .milliseconds(400))
        async let first = c.transcribe(pcm16: [0])
        try await Task.sleep(for: .milliseconds(50))
        let second = try await c.tryTranscribe(pcm16: [0])
        #expect(second == nil, "interim must skip, never queue — the server has one slot")
        _ = try await first
        #expect(MockProtocol.requestCount == 1)
    }

    @Test func transcribeCancelsInFlightInterim() async throws {
        let c = makeClient(delay: .milliseconds(400))
        async let interim: String? = c.tryTranscribe(pcm16: [0])
        try await Task.sleep(for: .milliseconds(50))
        let final = try await c.transcribe(pcm16: [1])
        #expect(final == "hello world")
        _ = try? await interim
    }

    @Test func throwsOnNon200() async throws {
        MockProtocol.handler = { _ in (503, Data()) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        let c = WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                              session: URLSession(configuration: cfg))
        await #expect(throws: WhisperError.self) { try await c.transcribe(pcm16: [0]) }
    }

    @Test func bodyIsMultipartWithWavFile() async throws {
        nonisolated(unsafe) var seenType = ""
        MockProtocol.handler = { req in
            seenType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            return (200, Data(#"{"text":" ok\n"}"#.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        let c = WhisperClient(endpoint: URL(string: "https://example.test/inference")!,
                              session: URLSession(configuration: cfg))
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
        let c = makeClient(delay: .milliseconds(300))

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
        #expect(MockProtocol.requestCount == 2, "the probe at t=320ms must have been skipped, not started as a third request")
    }
}
