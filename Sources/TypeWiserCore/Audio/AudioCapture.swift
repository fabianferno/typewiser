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

/// Hand-off from the realtime audio thread into an actor-owned buffer, and
/// the reverse: shutting that hand-off down without losing anything already
/// in flight.
///
/// The tap callback runs on CoreAudio's realtime render thread and cannot
/// safely `await` an actor hop itself, so it must hand its converted samples
/// off asynchronously. A naive `Task { await self?.append(ints) }` per
/// callback is *not* safe for that: each call only enqueues a new,
/// independent, unstructured Task, and those Tasks are then picked up by the
/// cooperative thread pool in whatever order threads become free — not
/// necessarily the order they were created in. Two chunks captured
/// back-to-back on the audio thread could reach `append` reordered,
/// corrupting the contiguous PCM buffer.
///
/// `AsyncStream` avoids this: `continuation.yield` is a synchronous, ordered
/// hand-off (safe to call from the audio thread), and exactly one consumer
/// `Task` — `pump` — drains the stream with a single `for await` loop,
/// calling `append` serially in yield order. There is only ever one in-flight
/// hop, so there is nothing left to reorder.
///
/// Kept independent of `AVAudioEngine` on purpose: it lets the drain-vs-cancel
/// race in `finish()` be exercised by a plain unit test, with no real
/// microphone or engine involved (merely *referencing*
/// `AVAudioEngine().inputNode` can hang for minutes in a sandboxed
/// environment with no audio hardware/entitlement — this type never touches
/// either).
actor ChunkPump {
    private(set) var buffer: [Int16] = []
    private var continuation: AsyncStream<[Int16]>.Continuation?
    private var pump: Task<Void, Never>?

    /// Resets the buffer and wires up a fresh stream + drain task, returning
    /// the continuation for the caller (the tap callback) to `yield` into.
    func start() -> AsyncStream<[Int16]>.Continuation {
        buffer.removeAll()
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        self.continuation = continuation
        pump = Task { [weak self] in
            for await chunk in stream {
                await self?.append(chunk)
            }
        }
        return continuation
    }

    private func append(_ s: [Int16]) { buffer.append(contentsOf: s) }

    /// Finishing the stream leaves any chunks already yielded (but not yet
    /// drained by `pump`) sitting in the stream's buffer; `pump`'s `for await`
    /// loop still has to run to actually deliver them to `append`. Awaiting
    /// `pump`'s completion — rather than cancelling it — is what makes that
    /// happen: actor reentrancy means this `await` yields the actor so the
    /// pump's queued `append` calls can land before `finish()` returns, so a
    /// caller doing `await audio.stop(); await audio.currentSamples()`
    /// (`DictationSession.end()`) is guaranteed to see every sample that was
    /// ever captured, including the tail end right up to key-release.
    ///
    /// This cannot hang: `continuation?.finish()` closes the stream, which
    /// guarantees `pump`'s `for await` terminates (there is nothing else in
    /// that loop that can suspend indefinitely), so `pump`'s `Task` always
    /// completes and `await pump?.value` always returns.
    ///
    /// Historical bug this replaced: calling `pump?.cancel()` instead of
    /// awaiting it. `AsyncStream`'s iterator is cancellation-aware and can
    /// return early even when it has buffered content it hasn't yet
    /// delivered, so cancelling — combined with the fact that a non-suspending
    /// `stop()` gave the pump no chance to run at all while `stop()` itself
    /// was executing — silently dropped the last chunk(s) of audio on every
    /// single dictation.
    func finish() async {
        continuation?.finish()
        continuation = nil
        await pump?.value
        pump = nil
    }
}

/// Microphone → 16kHz mono Int16, which is what whisper.cpp wants.
public actor AudioCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private let pump = ChunkPump()
    private var running = false

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

    public func currentSamples() async -> [Int16] { await pump.buffer }

    public func level() async -> Float { Self.rms(Array(await pump.buffer.suffix(1600))) }

    public func start() async throws {
        guard !running else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw AudioError.noInput }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw AudioError.converterFailed }

        let continuation = await pump.start()

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
            await pump.finish()
            throw AudioError.engineFailed
        }
        running = true
    }

    public func stop() async {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await pump.finish()
        running = false
    }
}
