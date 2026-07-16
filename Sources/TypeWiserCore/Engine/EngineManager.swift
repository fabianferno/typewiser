import Foundation

public struct EngineConfig: Sendable, Equatable {
    public var binaryPath: String
    public var modelPath: String
    public var draftModelPath: String
    public var port: Int
    public var contextSize: Int

    public init(binaryPath: String, modelPath: String, draftModelPath: String,
                port: Int = 8231, contextSize: Int = 4096) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.draftModelPath = draftModelPath
        self.port = port
        self.contextSize = contextSize
    }

    private static let base = "\(NSHomeDirectory())/Models/Local"

    public static let gemmaDefault = EngineConfig(
        binaryPath: "\(base)/repos/llama.cpp/build/bin/llama-server",
        modelPath: "\(base)/models/unsloth-gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf",
        draftModelPath: "\(base)/models/unsloth-gemma-4-26B-A4B-it-GGUF/MTP/gemma-4-26B-A4B-it-Q8_0-MTP.gguf"
    )
}

public enum EngineState: Sendable, Equatable {
    case stopped, starting, ready
    case failed(String)
}

/// Owns the local llama-server child process.
///
/// This is the user's compute on/off switch: switching to Cloud kills the process
/// and reclaims ~17GB of RAM plus the GPU.
public actor EngineManager {
    private let config: EngineConfig
    private let session: URLSession
    private var process: Process?
    public private(set) var state: EngineState = .stopped

    /// Bumped on every `start()`/`stop()` so a suspended `waitForHealth()` from
    /// a previous generation can detect it is stale and never write `state`
    /// on behalf of a generation that is no longer current. Without this, a
    /// `stop()` that races a `start()`'s health-poll loop can let the stale
    /// loop overwrite state that a later `start()` (or the `stop()` itself)
    /// already set correctly.
    private var generation = 0

    public init(config: EngineConfig = .gemmaDefault, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Deliberately omits `--mmproj` (vision projector — unused here) and uses
    /// `-c 4096` rather than 65536: our prompt is one short utterance.
    public func arguments() -> [String] {
        [
            "-m", config.modelPath,
            "--model-draft", config.draftModelPath,
            "--spec-type", "draft-mtp",
            "--spec-draft-n-max", "3",
            "-ngl", "999",
            "-fa", "on",
            "-c", String(config.contextSize),
            "--parallel", "1",
            "--host", "127.0.0.1",
            "--port", String(config.port),
        ]
    }

    public func start() async {
        guard state == .stopped || isFailed else { return }
        guard FileManager.default.isExecutableFile(atPath: config.binaryPath) else {
            state = .failed("llama-server not found at \(config.binaryPath)")
            return
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            state = .failed("model not found at \(config.modelPath)")
            return
        }

        generation += 1
        let myGeneration = generation

        state = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.binaryPath)
        p.arguments = arguments()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            state = .failed("failed to launch: \(error.localizedDescription)")
            return
        }
        process = p
        Self.writePidFile(pid: p.processIdentifier, port: config.port)
        await waitForHealth(generation: myGeneration)
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// A 17GB GGUF takes 10–30s to load, so poll rather than assume.
    ///
    /// `myGeneration` pins this call to the `start()` that spawned it. If
    /// `stop()` (or a subsequent `start()`) runs while this loop is suspended
    /// between polls, `generation` will have moved on by the time we resume,
    /// and every state write below is guarded on it — the loop exits instead
    /// of reporting on behalf of a generation that is no longer current. This
    /// also means a `nil` `process` here (set by `stop()`) is always caught
    /// by the generation guard, never misreported as "exited during startup".
    private func waitForHealth(generation myGeneration: Int) async {
        let url = URL(string: "http://127.0.0.1:\(config.port)/health")!
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            guard generation == myGeneration else { return }
            guard let p = process, p.isRunning else {
                state = .failed("llama-server exited during startup")
                return
            }
            if let (_, resp) = try? await session.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                guard generation == myGeneration else { return }
                state = .ready
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard generation == myGeneration else { return }
        state = .failed("llama-server did not become healthy within 90s")
    }

    public func stop() {
        generation += 1
        process?.terminate()
        process = nil
        state = .stopped
        Self.removePidFile(port: config.port)
    }

    /// Test-only seam: lets tests confirm a child was actually spawned and
    /// poll for its exit without reaching into `process` directly.
    func processIdentifierForTesting() -> Int32? {
        process?.processIdentifier
    }

    // MARK: - Orphan recovery
    //
    // `Process.terminate()` above only runs while this app process is alive to
    // call it. If the app crashes or is force-quit, the child `llama-server`
    // (holding ~17GB of RAM) is never signaled and leaks indefinitely. To fix
    // that without an OS-level process group/launchd dependency, every spawn
    // records its pid in a small pidfile named after the port it bound (so a
    // background test instance on a throwaway port never collides with the
    // real app's port 8231). `terminateOrphanedProcessIfPresent` reads that
    // file and, if the recorded pid still resolves to a process actually named
    // `llama-server` (never trusting a bare pid, which the OS can recycle to
    // an unrelated process), kills it and removes the file. Calling this once
    // at app launch cleans up anything a previous crashed run left behind;
    // calling it again from a `NSApplication.willTerminateNotification`
    // observer kills the still-live child on a normal quit, since the
    // pidfile is present either way — one mechanism serves both cases.

    private static func pidFileURL(port: Int) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xyz.crevn.typewiser.llama-server-\(port).pid")
    }

    private static func writePidFile(pid: Int32, port: Int) {
        try? "\(pid)".write(to: pidFileURL(port: port), atomically: true, encoding: .utf8)
    }

    private static func removePidFile(port: Int) {
        try? FileManager.default.removeItem(at: pidFileURL(port: port))
    }

    /// Only ever signals a pid we can confirm is a `llama-server` process,
    /// and always removes the pidfile afterward so a dead reference is never
    /// consulted again.
    public static func terminateOrphanedProcessIfPresent(config: EngineConfig = .gemmaDefault) {
        let url = pidFileURL(port: config.port)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        guard processCommandName(pid: pid)?.hasSuffix("llama-server") == true else { return }
        kill(pid, SIGTERM)
    }

    private static func processCommandName(pid: pid_t) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return nil
        }
        ps.waitUntilExit()
        guard ps.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }
}
