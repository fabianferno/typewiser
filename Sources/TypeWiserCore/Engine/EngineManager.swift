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
    }
}
