import Foundation
import Testing
@testable import TypeWiserCore

// Reuses MockProtocol from WhisperClientTests.

private func makeRewriter(body: String, code: Int = 200) -> LocalLlamaRewriter {
    MockProtocol.handler = { _ in (code, Data(body.utf8)) }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockProtocol.self]
    return LocalLlamaRewriter(baseURL: URL(string: "http://127.0.0.1:8231")!,
                              session: URLSession(configuration: cfg))
}

private let okBody = #"{"choices":[{"message":{"content":"Let's meet at 3."}}]}"#

@Suite(.serialized)
struct LocalLlamaRewriterTests {
    @Test func extractsContentFromOpenAIShape() async throws {
        let r = makeRewriter(body: okBody)
        let out = try await r.rewrite("let's meet at 2 actually 3", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func sanitizesQuotedModelOutput() async throws {
        let r = makeRewriter(body: #"{"choices":[{"message":{"content":"\"Let's meet at 3.\""}}]}"#)
        let out = try await r.rewrite("x", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func emptyModelOutputFallsBackToTranscript() async throws {
        let r = makeRewriter(body: #"{"choices":[{"message":{"content":"  "}}]}"#)
        let out = try await r.rewrite("raw words", options: .default, context: .empty)
        #expect(out == "raw words", "never lose the user's words")
    }

    @Test func noOpOptionsSkipTheNetworkEntirely() async throws {
        MockProtocol.requestCount = 0
        let r = makeRewriter(body: okBody)
        var o = RewriteOptions.default
        o.removeFillers = false; o.fixGrammar = false; o.removeRepetition = false
        o.resolveSelfCorrections = false; o.contextAwareSpelling = false
        let out = try await r.rewrite("untouched", options: o, context: .empty)
        #expect(out == "untouched")
        #expect(MockProtocol.requestCount == 0)
    }

    @Test func throwsHTTPOnServerError() async throws {
        let r = makeRewriter(body: "", code: 500)
        await #expect(throws: RewriteError.http(500)) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func throwsBadPayloadOnGarbage() async throws {
        let r = makeRewriter(body: "not json")
        await #expect(throws: RewriteError.badPayload) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }
}
