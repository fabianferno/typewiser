import Foundation
import Testing
@testable import TypeWiserCore

/// Opt-in live test against the real Apple Intelligence model. The unit tests
/// inject the model call, so only this proves the prompt actually produces a
/// rewrite (rather than a refusal or an answer) on the system model.
///
/// Skipped unless `TYPEWISER_ONDEVICE_LIVE=1` is set; needs a Mac with Apple
/// Intelligence enabled.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEWISER_ONDEVICE_LIVE"] == "1"))
func liveOnDeviceRewrite() async throws {
    #expect(OnDeviceRewriter.modelStatus == .available)

    let generate = OnDeviceRewriter.systemModel
    let transcript = "so um let's meet at two, uh, actually three tomorrow afternoon you know"
    let raw = try await generate(
        RewritePrompt.system(options: .default, context: .empty, transcript: transcript),
        RewritePrompt.user(transcript))
    print("[OnDeviceIntegration] model output: \(raw)")

    let result = try await OnDeviceRewriter(timeout: .seconds(30)).rewrite(transcript, options: .default, context: .empty)
    print("[OnDeviceIntegration] rewritten text: \(result)")
    let lower = result.lowercased()
    #expect(lower.contains("3") || lower.contains("three"))
    #expect(!lower.contains("2") && !lower.contains("two"), "self-correction not resolved")
    #expect(!lower.contains(" um"))
    #expect(result.first?.isUppercase == true)
}
