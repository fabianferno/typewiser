import Foundation
import Testing
@testable import TypeWiserCore

private struct GoldenCase: Codable {
    let name: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]
}

private func loadCases() throws -> [GoldenCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden.json")
    return try JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: url))
}

private func check(_ c: GoldenCase, _ output: String) {
    for needle in c.mustContain {
        #expect(output.localizedCaseInsensitiveContains(needle),
                "[\(c.name)] expected \"\(needle)\" in: \(output)")
    }
    for needle in c.mustNotContain {
        #expect(!output.localizedCaseInsensitiveContains(needle),
                "[\(c.name)] did not expect \"\(needle)\" in: \(output)")
    }
}

/// Credentials for `goldenBedrock`: prefer the Keychain (where a real user would
/// store them via Settings → Cloud), falling back to environment variables so this
/// suite is runnable in CI / a fresh checkout without ever writing secrets to disk.
private func bedrockCredentials() -> AWSCredentials? {
    if let fromKeychain = KeychainCredentialStore().load() {
        return fromKeychain
    }
    let env = ProcessInfo.processInfo.environment
    guard let key = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] else {
        return nil
    }
    let region = env["AWS_REGION"] ?? "ap-south-1"
    return AWSCredentials(accessKeyID: key, secretAccessKey: secret, region: region)
}

// Opt-in: hits a real model. Run with TYPEWISER_GOLDEN_LOCAL=1 and llama-server up.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEWISER_GOLDEN_LOCAL"] == "1"))
func goldenLocal() async throws {
    // The local model is a "thinking" variant: harder cases can burn 1000+ reasoning
    // tokens before the final answer, so this needs more headroom than a typical
    // request timeout.
    let r = LocalLlamaRewriter(timeout: 60)
    for c in try loadCases() {
        let out = try await r.rewrite(c.input, options: .default, context: .empty)
        check(c, out)
    }
}

// Opt-in: costs money. Run with TYPEWISER_GOLDEN_BEDROCK=1 and creds in the Keychain
// (Settings → Cloud) or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the environment.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEWISER_GOLDEN_BEDROCK"] == "1"))
func goldenBedrock() async throws {
    guard let creds = bedrockCredentials() else {
        Issue.record("No AWS credentials in Keychain or environment — add them in Settings → Cloud, or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY")
        return
    }
    let r = BedrockRewriter(credentials: creds, timeout: 30)
    for c in try loadCases() {
        let out = try await r.rewrite(c.input, options: .default, context: .empty)
        check(c, out)
    }
}

@Test func namesFromDictionaryReachThePrompt() {
    let ctx = RewriteContext(surroundingText: nil, appName: nil, nameDictionary: ["Crevn", "Fabian Ferno"])
    var o = RewriteOptions.default
    o.contextAwareSpelling = true
    let p = RewritePrompt.system(options: o, context: ctx, transcript: "")
    #expect(p.contains("Crevn") && p.contains("Fabian Ferno"))
}
