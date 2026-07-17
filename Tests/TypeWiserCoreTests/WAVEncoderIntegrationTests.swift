import Foundation
import Testing
@testable import TypeWiserCore

/// Ground-truth round-trip test: proves `WAVEncoder`'s output is accepted by
/// the *real* whisper.cpp server, not just self-consistent with the unit
/// tests' own byte-offset assumptions.
///
/// It generates a known-good WAV via `say` + `ffmpeg`, strips that WAV's own
/// 44-byte header to recover raw Int16 PCM samples, re-encodes those samples
/// with `WAVEncoder.encode`, POSTs the result to the live server, and asserts
/// the transcription is sane. If `WAVEncoder` produced a malformed container,
/// the server would reject it or return garbage.
///
/// Hits the network — opt-in only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEWISER_INTEGRATION"] == "1"))
func wavEncoderRoundTripIsAcceptedByRealServer() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let aiffURL = tmpDir.appendingPathComponent("wav-encoder-integration-\(UUID().uuidString).aiff")
    let wavURL = tmpDir.appendingPathComponent("wav-encoder-integration-\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: aiffURL)
        try? FileManager.default.removeItem(at: wavURL)
    }

    let phrase = "Let's meet at two, actually three, um, tomorrow afternoon"

    guard let sayURL = findExecutable("say") else {
        Issue.record("`say` is not available on this machine; skipping live server round-trip.")
        return
    }
    guard let ffmpegURL = findExecutable("ffmpeg") else {
        Issue.record("`ffmpeg` is not available on this machine; skipping live server round-trip.")
        return
    }

    do {
        try runProcess(sayURL, ["-o", aiffURL.path, phrase])
    } catch {
        Issue.record("`say` failed to synthesize audio: \(error)")
        return
    }

    do {
        try runProcess(
            ffmpegURL,
            ["-y", "-loglevel", "error", "-i", aiffURL.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
        )
    } catch {
        Issue.record("`ffmpeg` failed to transcode to 16kHz mono PCM WAV: \(error)")
        return
    }

    // Recover the raw Int16 PCM samples from the known-good WAV by skipping
    // its 44-byte canonical header, then re-encode them with WAVEncoder.
    let sourceWAV = try Data(contentsOf: wavURL)
    #expect(sourceWAV.count > 44, "source WAV from ffmpeg should have a header plus payload")
    let pcm16 = decodeLittleEndianInt16PCM(sourceWAV.dropFirst(44))

    let reencoded = WAVEncoder.encode(pcm16: pcm16, sampleRate: 16000)

    let transcription = try await transcribe(wavData: reencoded)

    let lowered = transcription.lowercased()
    #expect(lowered.contains("three"), "transcription was: \(transcription)")
    #expect(lowered.contains("tomorrow"), "transcription was: \(transcription)")
}

// MARK: - Helpers

/// Reads little-endian Int16 samples out of raw PCM data (post-header).
/// Kept private to this test file.
private func decodeLittleEndianInt16PCM(_ data: Data) -> [Int16] {
    let bytes = Array(data)
    var samples = [Int16]()
    samples.reserveCapacity(bytes.count / 2)
    var i = 0
    while i + 1 < bytes.count {
        let low = UInt16(bytes[i])
        let high = UInt16(bytes[i + 1])
        let value = low | (high << 8)
        samples.append(Int16(bitPattern: value))
        i += 2
    }
    return samples
}

private func findExecutable(_ name: String) -> URL? {
    for dir in ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
        let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func runProcess(_ executableURL: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(
            domain: "WAVEncoderIntegrationTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executableURL.path) exited with status \(process.terminationStatus)"]
        )
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private func transcribe(wavData: Data) async throws -> String {
    // Point at your own whisper.cpp server. Defaults to a local one so this
    // opt-in test never depends on someone else's infrastructure.
    let endpoint = ProcessInfo.processInfo.environment["TYPEWISER_WHISPER_ENDPOINT"]
        ?? "http://127.0.0.1:8080/inference"
    let url = URL(string: endpoint)!
    let boundary = "Boundary-\(UUID().uuidString)"

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30

    var body = Data()

    func appendField(name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n".data(using: .utf8)!
    )
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wavData)
    body.append("\r\n".data(using: .utf8)!)

    appendField(name: "temperature", value: "0.0")
    appendField(name: "response_format", value: "json")

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body

    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 30
    sessionConfig.timeoutIntervalForResource = 30
    let session = URLSession(configuration: sessionConfig)

    let (data, response) = try await session.data(for: request)

    if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
        let body = String(decoding: data, as: UTF8.self)
        throw NSError(
            domain: "WAVEncoderIntegrationTests",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "server returned \(httpResponse.statusCode): \(body)"]
        )
    }

    let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
}
