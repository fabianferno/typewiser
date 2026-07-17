import Foundation

public enum WhisperError: Error, Equatable {
    case http(Int)
    case badPayload
    case cancelled
}

public protocol Transcribing: Sendable {
    /// Final path. Cancels any in-flight interim so the final result is not queued behind it.
    func transcribe(pcm16: [Int16]) async throws -> String
    /// Interim path. Returns nil immediately if the single server slot is busy.
    func tryTranscribe(pcm16: [Int16]) async throws -> String?
    func cancelInFlight() async
}

/// Client for whisper.cpp's `/inference`.
///
/// The server exposes exactly one inference slot: measured, three parallel
/// requests serialized at ~3.2s each. This actor enforces one request in flight
/// so interim polling can never queue up behind itself.
public actor WhisperClient: Transcribing {
    private let endpoint: URL
    private let session: URLSession
    private var inFlight: Task<String, Error>?

    /// Bumped every time `run` installs a new task. A `run` call's `defer` only
    /// clears `inFlight` if this hasn't changed since — otherwise a cancelled,
    /// stale call (whose underlying network request hasn't noticed the
    /// cancellation yet and is still resolving) could resume *after* a newer
    /// call has already installed its own task, and wipe out that genuinely
    /// in-flight task. Without this guard, `tryTranscribe` could observe
    /// `inFlight == nil` while a request is still actually running against the
    /// server's one inference slot, and wrongly start a second one.
    private var generation = 0

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }

    public func transcribe(pcm16: [Int16]) async throws -> String {
        cancelInFlight()
        return try await run(pcm16)
    }

    public func tryTranscribe(pcm16: [Int16]) async throws -> String? {
        guard inFlight == nil else { return nil }
        return try await run(pcm16)
    }

    private func run(_ pcm16: [Int16]) async throws -> String {
        generation += 1
        let myGeneration = generation
        let task = Task { [endpoint, session] in
            let wav = WAVEncoder.encode(pcm16: pcm16)
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            let boundary = "tw-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.multipartBody(wav: wav, boundary: boundary)

            let (data, resp) = try await session.data(for: req)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse else { throw WhisperError.badPayload }
            guard http.statusCode == 200 else { throw WhisperError.http(http.statusCode) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else { throw WhisperError.badPayload }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        inFlight = task
        defer {
            if generation == myGeneration { inFlight = nil }
        }
        do {
            return try await task.value
        } catch is CancellationError {
            throw WhisperError.cancelled
        }
    }

    private static func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("temperature", "0.0")
        field("response_format", "json")
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
