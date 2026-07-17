import Foundation
import Testing
@testable import TypeWiserCore

// Reuses MockProtocol (Support/MockProtocol.swift); each test gets its own
// UUID-keyed mock id, so no state leaks across concurrently-scheduled suites.

private let messagesOK = #"{"content":[{"type":"text","text":"Let's meet at 3."}],"stop_reason":"end_turn"}"#

private func makeAnthropic(body: String, code: Int = 200) -> (rewriter: AnthropicRewriter, id: String) {
    let id = UUID().uuidString
    let session = MockProtocol.makeSession(id: id) { _ in (code, Data(body.utf8)) }
    return (AnthropicRewriter(apiKey: "sk-ant-test", session: session), id)
}

struct AnthropicRewriterTests {
    @Test func parsesMessagesResponseShape() async throws {
        let (r, id) = makeAnthropic(body: messagesOK)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("let's meet at 2 actually 3", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func concatenatesMultipleTextBlocksAndIgnoresNonText() async throws {
        let body = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello "},{"type":"text","text":"world."}]}"#
        let (r, id) = makeAnthropic(body: body)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("hello world", options: .default, context: .empty)
        #expect(out == "Hello world.")
    }

    // A safety refusal is HTTP 200 with stop_reason "refusal" — it must NOT be
    // treated as a rewrite, so the session pastes the raw transcript instead.
    @Test func refusalStopReasonThrowsSoRawTranscriptSurvives() async throws {
        let (r, id) = makeAnthropic(body: #"{"content":[],"stop_reason":"refusal"}"#)
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.self) {
            _ = try await r.rewrite("some words to clean up here", options: .default, context: .empty)
        }
    }

    @Test func httpErrorSurfacesStatusCode() async throws {
        let (r, id) = makeAnthropic(body: #"{"error":{"type":"authentication_error"}}"#, code: 401)
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.http(401)) {
            _ = try await r.rewrite("x y z words", options: .default, context: .empty)
        }
    }

    @Test func sendsRequiredHeadersAndTargetsMessagesEndpoint() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var seenURL: URL?
        nonisolated(unsafe) var seenKey: String?
        nonisolated(unsafe) var seenVersion: String?
        let session = MockProtocol.makeSession(id: id) { req in
            seenURL = req.url
            seenKey = req.value(forHTTPHeaderField: "x-api-key")
            seenVersion = req.value(forHTTPHeaderField: "anthropic-version")
            return .http(200, Data(messagesOK.utf8))
        }
        defer { MockProtocol.unregister(id: id) }
        _ = try await AnthropicRewriter(apiKey: "sk-ant-secret", session: session)
            .rewrite("x", options: .default, context: .empty)
        #expect(seenURL?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(seenKey == "sk-ant-secret")
        #expect(seenVersion == "2023-06-01")
    }

    @Test func noOpOptionsSkipTheNetworkEntirely() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var called = false
        let session = MockProtocol.makeSession(id: id) { _ in called = true; return .http(200, Data(messagesOK.utf8)) }
        defer { MockProtocol.unregister(id: id) }
        let off = RewriteOptions(removeFillers: false, fixGrammar: false, removeRepetition: false,
                                 resolveSelfCorrections: false, contextAwareSpelling: false)
        let out = try await AnthropicRewriter(apiKey: "k", session: session)
            .rewrite("verbatim", options: off, context: .empty)
        #expect(out == "verbatim")
        #expect(called == false)
    }
}
