import Foundation
import Testing
@testable import TypeWiserCore

/// Opt-in live test against real AWS Bedrock. Everything else in this test suite mocks the
/// network, so nothing else here can prove SigV4 signing is actually correct against AWS's
/// servers — a mocked request echoes back whatever we send and never validates a signature.
/// This is the only test that can.
///
/// Skipped unless `TYPEWISER_BEDROCK_LIVE=1` is set, and reads credentials from the
/// environment only (never hardcode real AWS credentials in source).
@Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEWISER_BEDROCK_LIVE"] == "1"))
func liveBedrockRewriteAgainstRealAWS() async throws {
    guard let accessKeyID = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
          let secretAccessKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"]
    else {
        Issue.record("AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set in environment")
        return
    }

    let credentials = AWSCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                     region: "ap-south-1")
    let rewriter = BedrockRewriter(credentials: credentials,
                                   modelID: "apac.amazon.nova-lite-v1:0",
                                   timeout: 30)

    let transcript = "so um let's meet at two, uh, actually three tomorrow afternoon you know"
    let result = try await rewriter.rewrite(transcript, options: .default, context: .empty)
    print("[BedrockIntegration] rewritten text: \(result)")

    let lower = result.lowercased()
    #expect(lower.contains("3") || lower.contains("three"))
    #expect(!lower.contains("um"))
}
