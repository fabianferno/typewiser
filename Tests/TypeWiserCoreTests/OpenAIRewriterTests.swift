import Foundation
import Testing
@testable import TypeWiserCore

private let chatOK = #"{"choices":[{"message":{"role":"assistant","content":"Let's meet at 3."}}]}"#

private func makeOpenAI(body: String, code: Int = 200) -> (rewriter: OpenAIRewriter, id: String) {
    let id = UUID().uuidString
    let session = MockProtocol.makeSession(id: id) { _ in (code, Data(body.utf8)) }
    return (OpenAIRewriter(apiKey: "sk-test", session: session), id)
}

struct OpenAIRewriterTests {
    @Test func parsesChatCompletionsResponseShape() async throws {
        let (r, id) = makeOpenAI(body: chatOK)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("let's meet at 2 actually 3", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func httpErrorSurfacesStatusCode() async throws {
        let (r, id) = makeOpenAI(body: #"{"error":{"message":"invalid key"}}"#, code: 401)
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.http(401)) {
            _ = try await r.rewrite("x y z words", options: .default, context: .empty)
        }
    }

    @Test func sendsBearerAuthAndTargetsChatCompletions() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var seenURL: URL?
        nonisolated(unsafe) var seenAuth: String?
        let session = MockProtocol.makeSession(id: id) { req in
            seenURL = req.url
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            return .http(200, Data(chatOK.utf8))
        }
        defer { MockProtocol.unregister(id: id) }
        _ = try await OpenAIRewriter(apiKey: "sk-secret", session: session)
            .rewrite("x", options: .default, context: .empty)
        #expect(seenURL?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(seenAuth == "Bearer sk-secret")
    }

    @Test func noOpOptionsSkipTheNetworkEntirely() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var called = false
        let session = MockProtocol.makeSession(id: id) { _ in called = true; return .http(200, Data(chatOK.utf8)) }
        defer { MockProtocol.unregister(id: id) }
        let off = RewriteOptions(removeFillers: false, fixGrammar: false, removeRepetition: false,
                                 resolveSelfCorrections: false, contextAwareSpelling: false)
        let out = try await OpenAIRewriter(apiKey: "k", session: session)
            .rewrite("verbatim", options: off, context: .empty)
        #expect(out == "verbatim")
        #expect(called == false)
    }
}
