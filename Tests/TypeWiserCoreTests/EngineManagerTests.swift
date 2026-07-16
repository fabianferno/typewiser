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

/// Regression test for the Task 13 orphaned-process leak: if the app
/// crashes or is force-quit, `stop()` never runs and the 17GB `llama-server`
/// child leaks forever. The fix records the spawned pid in a pidfile keyed
/// by port; `terminateOrphanedProcessIfPresent` is what a fresh launch (or a
/// termination-notification handler) calls to reap it.
///
/// Uses a throwaway *compiled* binary literally named `llama-server` (not
/// the real 17GB one) on a port nothing else uses, so this never touches
/// the real model or the real app's pidfile. It must be a real executable
/// rather than a `#!/bin/sh` script: a shebang script actually runs under
/// `/bin/sh`, so `ps -o comm=` would report "sh", not "llama-server" —
/// which would defeat the exact check `terminateOrphanedProcessIfPresent`
/// performs. The real llama-server is a native binary with no interpreter,
/// so this fixture has to be one too for the test to mean anything.
@Test func terminateOrphanedProcessKillsOnlyAConfirmedLlamaServer() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("engine-manager-orphan-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let binaryURL = try compileLlamaServerFixture(in: dir)

    let config = EngineConfig(
        binaryPath: binaryURL.path,
        modelPath: binaryURL.path,
        draftModelPath: binaryURL.path,
        port: 18377
    )
    let manager = EngineManager(config: config)
    let startTask = Task { await manager.start() }

    // Give start() time to spawn the child and write its pidfile before we
    // simulate "a previous run crashed" by reaping via the static helper
    // instead of calling manager.stop().
    try await Task.sleep(for: .milliseconds(300))

    let pid = await manager.processIdentifierForTesting()
    #expect(pid != nil, "start() should have a live child by now")

    EngineManager.terminateOrphanedProcessIfPresent(config: config)

    // SIGTERM is asynchronous; poll briefly for the process to actually exit.
    var stillAlive = true
    for _ in 0..<20 {
        if let pid, kill(pid, 0) != 0 { stillAlive = false; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!stillAlive, "orphaned llama-server should have been terminated")

    await manager.stop()
    await startTask.value
}

/// Compiles the throwaway native `llama-server` fixture used by the tests
/// below into `dir`, returning its path. Shared helper so each safety test
/// doesn't repeat the compile boilerplate.
private func compileLlamaServerFixture(in dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sourceURL = dir.appendingPathComponent("sleeper.c")
    let binaryURL = dir.appendingPathComponent("llama-server")
    try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
        .write(to: sourceURL, atomically: true, encoding: .utf8)

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-o", binaryURL.path, sourceURL.path]
    try cc.run()
    cc.waitUntilExit()
    #expect(cc.terminationStatus == 0, "test fixture failed to compile")
    return binaryURL
}

/// THE CRITICAL SAFETY TEST. Reproduces the exact bug this task exists to
/// fix: our `llama-server` dies without `stop()` running, leaving a stale
/// pidfile, and the OS recycles that pid to a *different* process (in
/// reality: a `llama-server` the user launched by hand for their own local
/// work). A name-only identity check (the pre-fix behavior) would pass and
/// SIGTERM the wrong process — silently destroying someone else's 17GB.
///
/// This test doesn't need to wait for an actual pid-recycling race (which
/// would be slow and flaky to engineer); it simulates the observable
/// consequence directly by writing a pidfile whose recorded `lstart` does
/// NOT match the live process's real start time — exactly what a recycled
/// pid would look like, since the "new" process at that pid necessarily
/// started at a different (later) time than the one we originally recorded.
///
/// Asserts the process survives and the stale pidfile is cleaned up so it's
/// never consulted again.
@Test func mismatchedStartTimeMeansDoNotKill() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("engine-manager-orphan-mismatch-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let binaryURL = try compileLlamaServerFixture(in: dir)

    let config = EngineConfig(
        binaryPath: binaryURL.path,
        modelPath: binaryURL.path,
        draftModelPath: binaryURL.path,
        port: 18378
    )
    let manager = EngineManager(config: config)
    let startTask = Task { await manager.start() }

    // Safety net: if an assertion throws before we reach the normal
    // `manager.stop()` below, make sure the fixture process (which sleeps
    // 30s) doesn't outlive this test.
    var capturedPid: Int32?
    defer { if let capturedPid { kill(capturedPid, SIGKILL) } }

    try await Task.sleep(for: .milliseconds(300))
    let pid = try #require(await manager.processIdentifierForTesting(),
                            "start() should have a live child by now")
    capturedPid = pid

    // Overwrite the pidfile start() just wrote with one recording a bogus,
    // definitely-wrong start time for the SAME live pid — simulating "this
    // pid now belongs to a process that started at a different time than
    // the one we remember", i.e. pid recycling.
    let record = EngineManager.OrphanPidRecord(pid: pid, lstart: "Thu Jan  1 00:00:00 1970", port: config.port)
    let data = try JSONEncoder().encode(record)
    try data.write(to: EngineManager.pidFileURL(port: config.port), options: .atomic)

    EngineManager.terminateOrphanedProcessIfPresent(config: config)

    // Give a real SIGTERM (if wrongly sent) time to land before we check.
    try await Task.sleep(for: .milliseconds(500))
    #expect(kill(pid, 0) == 0,
            "a start-time mismatch must NEVER result in the live process being killed")

    let pidFileStillPresent = FileManager.default.fileExists(
        atPath: EngineManager.pidFileURL(port: config.port).path)
    #expect(!pidFileStillPresent, "the stale/unverifiable pidfile should be removed so it is never reconsulted")

    // Clean shutdown (mirrors the other orphan test): stop() before awaiting
    // startTask so waitForHealth's generation guard exits immediately instead
    // of polling until the fixture's sleep(30) finishes on its own.
    await manager.stop()
    await startTask.value
}

/// A malformed or legacy-format pidfile (e.g. the old bare-pid text file
/// this project used before the JSON format) must never be trusted enough
/// to kill anything, and must not crash the decode path.
@Test func malformedPidFileIsDiscardedWithoutKillingAnything() throws {
    let port = 18379
    let url = EngineManager.pidFileURL(port: port)
    try "12345".write(to: url, atomically: true, encoding: .utf8)

    let config = EngineConfig(binaryPath: "/bin/sh", modelPath: "/bin/sh", draftModelPath: "/bin/sh", port: port)
    EngineManager.terminateOrphanedProcessIfPresent(config: config) // must not crash

    #expect(!FileManager.default.fileExists(atPath: url.path),
            "a malformed pidfile should be discarded, not left behind")
}

/// A pidfile that correctly points at a pid which no longer exists (the
/// process already exited on its own) must be handled gracefully: no crash,
/// and the stale reference is cleaned up.
@Test func pidFileForDeadProcessIsCleanedUpWithoutCrashing() async throws {
    // Spawn and wait out a genuinely short-lived process to get a pid that
    // is very unlikely to still be running (or freshly recycled) afterward.
    let shortLived = Process()
    shortLived.executableURL = URL(fileURLWithPath: "/bin/sh")
    shortLived.arguments = ["-c", "exit 0"]
    try shortLived.run()
    shortLived.waitUntilExit()
    let deadPid = shortLived.processIdentifier

    let port = 18380
    let record = EngineManager.OrphanPidRecord(pid: deadPid, lstart: "Thu Jan  1 00:00:00 1970", port: port)
    let data = try JSONEncoder().encode(record)
    let url = EngineManager.pidFileURL(port: port)
    try data.write(to: url, options: .atomic)

    let config = EngineConfig(binaryPath: "/bin/sh", modelPath: "/bin/sh", draftModelPath: "/bin/sh", port: port)
    EngineManager.terminateOrphanedProcessIfPresent(config: config) // must not crash

    #expect(!FileManager.default.fileExists(atPath: url.path),
            "a pidfile pointing at a dead pid should be removed")
}
