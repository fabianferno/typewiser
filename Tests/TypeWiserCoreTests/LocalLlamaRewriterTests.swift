import Foundation
import Testing
@testable import TypeWiserCore

// Reuses MockProtocol from Support/MockProtocol.swift. Each test below gets
// its own UUID-keyed mock id, so state never leaks between tests here or in
// any other suite (e.g. WhisperClientTests) that Swift Testing may schedule
// concurrently with this one — hence no `.serialized` trait is needed.

private func makeRewriter(body: String, code: Int = 200) -> (rewriter: LocalLlamaRewriter, id: String) {
    let id = UUID().uuidString
    let session = MockProtocol.makeSession(id: id) { _ in (code, Data(body.utf8)) }
    let rewriter = LocalLlamaRewriter(baseURL: URL(string: "http://127.0.0.1:8231")!,
                                      session: session)
    return (rewriter, id)
}

private let okBody = #"{"choices":[{"message":{"content":"Let's meet at 3."}}]}"#

struct LocalLlamaRewriterTests {
    @Test func extractsContentFromOpenAIShape() async throws {
        let (r, id) = makeRewriter(body: okBody)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("let's meet at 2 actually 3", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func sanitizesQuotedModelOutput() async throws {
        let (r, id) = makeRewriter(body: #"{"choices":[{"message":{"content":"\"Let's meet at 3.\""}}]}"#)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("x", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func emptyModelOutputFallsBackToTranscript() async throws {
        let (r, id) = makeRewriter(body: #"{"choices":[{"message":{"content":"  "}}]}"#)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("raw words", options: .default, context: .empty)
        #expect(out == "raw words", "never lose the user's words")
    }

    @Test func noOpOptionsSkipTheNetworkEntirely() async throws {
        let (r, id) = makeRewriter(body: okBody)
        defer { MockProtocol.unregister(id: id) }
        var o = RewriteOptions.default
        o.removeFillers = false; o.fixGrammar = false; o.removeRepetition = false
        o.resolveSelfCorrections = false; o.contextAwareSpelling = false
        let out = try await r.rewrite("untouched", options: o, context: .empty)
        #expect(out == "untouched")
        #expect(MockProtocol.requestCount(id: id) == 0)
    }

    @Test func throwsHTTPOnServerError() async throws {
        let (r, id) = makeRewriter(body: "", code: 500)
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.http(500)) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func throwsBadPayloadOnGarbage() async throws {
        let (r, id) = makeRewriter(body: "not json")
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.badPayload) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func timedOutTransportErrorMapsToTimedOut() async throws {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in .failure(URLError(.timedOut)) }
        defer { MockProtocol.unregister(id: id) }
        let r = LocalLlamaRewriter(baseURL: URL(string: "http://127.0.0.1:8231")!, session: session)
        await #expect(throws: RewriteError.timedOut) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func serverUnreachableTransportErrorMapsToUnavailable() async throws {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in .failure(URLError(.cannotConnectToHost)) }
        defer { MockProtocol.unregister(id: id) }
        let r = LocalLlamaRewriter(baseURL: URL(string: "http://127.0.0.1:8231")!, session: session)
        await #expect(throws: RewriteError.unavailable) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }
}
