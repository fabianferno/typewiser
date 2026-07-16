import Foundation
import Testing
@testable import TypeWiserCore

@Test func defaultConfigPointsAtRealPaths() {
    let c = EngineConfig.gemmaDefault
    #expect(c.binaryPath.hasSuffix("build/bin/llama-server"))
    #expect(c.modelPath.hasSuffix("gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf"))
    #expect(c.draftModelPath.hasSuffix("gemma-4-26B-A4B-it-Q8_0-MTP.gguf"))
}

@Test func portIs8231Not8080() {
    #expect(EngineConfig.gemmaDefault.port == 8231, "8080 is commonly occupied")
}

@Test func contextIsTrimmedTo4096() {
    #expect(EngineConfig.gemmaDefault.contextSize == 4096,
            "prompts are one short utterance; 65536 wastes GBs of KV cache")
}

@Test func argumentsOmitMmprojBecauseWeDoNotDoVision() async {
    let args = await EngineManager().arguments()
    #expect(!args.contains("--mmproj"), "vision projector is unused for text rewriting")
}

@Test func argumentsIncludeModelDraftAndSpecDecoding() async {
    let args = await EngineManager().arguments()
    #expect(args.contains("--model-draft"))
    #expect(args.contains("--spec-type"))
    #expect(args.contains("draft-mtp"))
}

@Test func argumentsBindLocalhostOnConfiguredPort() async {
    let args = await EngineManager().arguments()
    let portIdx = args.firstIndex(of: "--port")!
    #expect(args[portIdx + 1] == "8231")
    let hostIdx = args.firstIndex(of: "--host")!
    #expect(args[hostIdx + 1] == "127.0.0.1")
}

@Test func startsStopped() async {
    #expect(await EngineManager().state == .stopped)
}

/// Regression test for the cross-generation state-corruption race: `stop()`
/// racing an in-flight `waitForHealth()` poll must never let that stale poll
/// overwrite the `.stopped` state with `.failed(...)`.
///
/// This does NOT spawn the real 17GB llama-server. It points `EngineConfig`
/// at a throwaway shell script (`sleep 5`, ignoring the llama-server-shaped
/// arguments passed to it) so `start()` has a real child process to manage
/// without touching the model at all, and a port nothing is listening on so
/// the health poll always fails and falls through to the 1s sleep — giving
/// us a window to race `stop()` against it.
///
/// Without the generation guard, this reproduces the exact bug: `stop()`
/// sets `process = nil`, and the stale poll's `process` read on its next
/// wake would be `nil`, which the fixed `guard let p = process, p.isRunning`
/// check treats as "exited during startup" and overwrites state with
/// `.failed(...)` — unless the generation check (which runs first) has
/// already caused the stale loop to return.
@Test func staleGenerationCannotOverwriteStoppedState() async throws {
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("engine-manager-test-\(UUID().uuidString).sh")
    try "#!/bin/sh\nsleep 5\n".write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let config = EngineConfig(
        binaryPath: scriptURL.path,
        modelPath: scriptURL.path,
        draftModelPath: scriptURL.path,
        port: 18299
    )
    let manager = EngineManager(config: config)

    let startTask = Task { await manager.start() }

    // Let start() spawn the process and enter waitForHealth's poll loop
    // (health check fails fast against the closed port, then sleeps 1s).
    try await Task.sleep(for: .milliseconds(300))

    await manager.stop()
    #expect(await manager.state == .stopped)

    // Give the stale generation-1 poll time to wake from its 1s sleep,
    // notice generation has moved on, and exit without touching state.
    try await Task.sleep(for: .seconds(2))
    #expect(await manager.state == .stopped,
            "a stale health-poll from a stopped generation must not overwrite state")

    await startTask.value
}
