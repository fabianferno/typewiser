import AVFoundation
import Foundation

public enum AudioError: Error, Equatable {
    case engineFailed
    case noInput
    case converterFailed
}

public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async
    func currentSamples() async -> [Int16]
    func level() async -> Float
}

/// Microphone → 16kHz mono Int16, which is what whisper.cpp wants.
public actor AudioCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var buffer: [Int16] = []
    private var running = false

    /// Hand-off from the realtime audio thread into this actor.
    ///
    /// The tap callback runs on CoreAudio's realtime render thread and cannot
    /// safely `await` an actor hop itself, so it must hand its converted
    /// samples off asynchronously. A naive `Task { await self?.append(ints) }`
    /// per callback is *not* safe for that: each call only enqueues a new,
    /// independent, unstructured Task, and those Tasks are then picked up by
    /// the cooperative thread pool in whatever order threads become free —
    /// not necessarily the order they were created in. Two chunks captured
    /// back-to-back on the audio thread could reach `append` reordered,
    /// corrupting the contiguous PCM buffer.
    ///
    /// `AsyncStream` avoids this: `continuation.yield` is a synchronous,
    /// ordered hand-off (safe to call from the audio thread), and exactly one
    /// consumer `Task` drains the stream with a single `for await` loop,
    /// calling `append` serially in yield order. There is only ever one
    /// in-flight hop, so there is nothing left to reorder.
    private var continuation: AsyncStream<[Int16]>.Continuation?
    private var pump: Task<Void, Never>?

    public init() {}

    // MARK: - Pure helpers (tested)

    nonisolated public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { acc, s in
            let n = Float(s) / Float(Int16.max)
            return acc + n * n
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    nonisolated public static func floatToInt16(_ f: [Float]) -> [Int16] {
        f.map { Int16(max(-1.0, min(1.0, $0)) * Float(Int16.max)) }
    }

    // MARK: - Capture

    public func currentSamples() -> [Int16] { buffer }

    public func level() -> Float { Self.rms(Array(buffer.suffix(1600))) }

    public func start() throws {
        guard !running else { return }
        buffer.removeAll()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw AudioError.noInput }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw AudioError.converterFailed }

        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        self.continuation = continuation
        pump = Task { [weak self] in
            for await chunk in stream {
                await self?.append(chunk)
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buf, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

            var err: NSError?
            // The converter invokes this input block synchronously on this
            // same (realtime audio) thread — never concurrently — so it is
            // safe to hand it `buf` and a one-shot flag despite neither type
            // being `Sendable`. `nonisolated(unsafe)` documents that the
            // compiler's Sendable check doesn't see that guarantee.
            nonisolated(unsafe) var supplied = false
            nonisolated(unsafe) let inputBuffer = buf
            converter.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inputBuffer
            }
            guard err == nil, let ch = out.floatChannelData?[0] else { return }
            let floats = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            let ints = Self.floatToInt16(floats)
            continuation.yield(ints)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            pump?.cancel()
            pump = nil
            self.continuation = nil
            throw AudioError.engineFailed
        }
        running = true
    }

    private func append(_ s: [Int16]) { buffer.append(contentsOf: s) }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        pump?.cancel()
        pump = nil
        running = false
    }
}
