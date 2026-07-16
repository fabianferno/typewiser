import Foundation
import Testing
@testable import TypeWiserCore

// Reuses MockProtocol from Support/MockProtocol.swift. Each test below gets its own
// UUID-keyed mock id, so state never leaks between tests here or in any other suite
// (e.g. LocalLlamaRewriterTests, WhisperClientTests) that Swift Testing may schedule
// concurrently with this one — hence no `.serialized` trait is needed.

private let testCreds = AWSCredentials(accessKeyID: "AKIDEXAMPLE",
                                       secretAccessKey: "SECRETEXAMPLE",
                                       region: "ap-south-1")

private func makeBedrock(body: String, code: Int = 200) -> (rewriter: BedrockRewriter, id: String) {
    let id = UUID().uuidString
    let session = MockProtocol.makeSession(id: id) { _ in (code, Data(body.utf8)) }
    let rewriter = BedrockRewriter(credentials: testCreds, session: session)
    return (rewriter, id)
}

private let novaOK = #"{"output":{"message":{"content":[{"text":"Let's meet at 3."}]}}}"#

struct BedrockRewriterTests {
    @Test func parsesNovaResponseShape() async throws {
        let (r, id) = makeBedrock(body: novaOK)
        defer { MockProtocol.unregister(id: id) }
        let out = try await r.rewrite("let's meet at 2 actually 3", options: .default, context: .empty)
        #expect(out == "Let's meet at 3.")
    }

    @Test func requestIsSignedAndTargetsCorrectEndpoint() async throws {
        let id = UUID().uuidString
        nonisolated(unsafe) var seenURL: URL?
        nonisolated(unsafe) var seenAuth: String?
        nonisolated(unsafe) var seenHostHeader: String?
        let session = MockProtocol.makeSession(id: id) { req in
            seenURL = req.url
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            seenHostHeader = req.value(forHTTPHeaderField: "Host")
            return .http(200, Data(novaOK.utf8))
        }
        defer { MockProtocol.unregister(id: id) }
        let r = BedrockRewriter(credentials: testCreds, session: session)
        _ = try await r.rewrite("x", options: .default, context: .empty)

        #expect(seenURL?.host == "bedrock-runtime.ap-south-1.amazonaws.com")
        #expect(seenURL?.path.contains("nova-lite") == true)
        #expect(seenURL?.path.hasSuffix("/invoke") == true)
        #expect(seenAuth?.hasPrefix("AWS4-HMAC-SHA256 ") == true)

        // Exploratory, not asserted: whether the explicitly-signed "Host" header survives
        // URLSession's transport to startLoading(). See task report for what was observed.
        _ = seenHostHeader
    }

    @Test func noOpOptionsSkipTheNetworkEntirely() async throws {
        let (r, id) = makeBedrock(body: novaOK)
        defer { MockProtocol.unregister(id: id) }
        var o = RewriteOptions.default
        o.removeFillers = false; o.fixGrammar = false; o.removeRepetition = false
        o.resolveSelfCorrections = false; o.contextAwareSpelling = false
        #expect(try await r.rewrite("untouched", options: o, context: .empty) == "untouched")
        #expect(MockProtocol.requestCount(id: id) == 0)
    }

    @Test func emptyOutputFallsBackToTranscript() async throws {
        let (r, id) = makeBedrock(body: #"{"output":{"message":{"content":[{"text":"  "}]}}}"#)
        defer { MockProtocol.unregister(id: id) }
        #expect(try await r.rewrite("raw words", options: .default, context: .empty) == "raw words")
    }

    @Test func throwsHTTPOnAccessDenied() async throws {
        let (r, id) = makeBedrock(body: #"{"message":"denied"}"#, code: 403)
        defer { MockProtocol.unregister(id: id) }
        await #expect(throws: RewriteError.http(403)) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func timedOutTransportErrorMapsToTimedOut() async throws {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in .failure(URLError(.timedOut)) }
        defer { MockProtocol.unregister(id: id) }
        let r = BedrockRewriter(credentials: testCreds, session: session)
        await #expect(throws: RewriteError.timedOut) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }

    @Test func serverUnreachableTransportErrorMapsToUnavailable() async throws {
        let id = UUID().uuidString
        let session = MockProtocol.makeSession(id: id) { _ in .failure(URLError(.cannotConnectToHost)) }
        defer { MockProtocol.unregister(id: id) }
        let r = BedrockRewriter(credentials: testCreds, session: session)
        await #expect(throws: RewriteError.unavailable) {
            try await r.rewrite("x", options: .default, context: .empty)
        }
    }
}
