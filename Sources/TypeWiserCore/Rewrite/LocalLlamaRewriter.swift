import Foundation

/// Talks to a locally-spawned llama-server over its OpenAI-compatible API.
///
/// Port 8231 by default — 8080 is commonly occupied by other dev servers.
public struct LocalLlamaRewriter: Rewriter {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8231")!,
                session: URLSession = .shared,
                timeout: TimeInterval = 2.0) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func rewrite(_ transcript: String,
                        options: RewriteOptions,
                        context: RewriteContext) async throws -> String {
        guard !options.isNoOp else { return transcript }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [
                ["role": "system", "content": RewritePrompt.system(options: options, context: context, transcript: transcript)],
                ["role": "user", "content": RewritePrompt.user(transcript)],
            ],
            "temperature": 0,
            // This server may run a "thinking" model (e.g. Gemma reasoning variants) whose
            // chain-of-thought is billed against this same token budget before any final
            // `content` is emitted. 512 was observed to be too small: harder inputs (e.g. a
            // double negative needing grammar repair) can consume 1000+ reasoning tokens
            // before converging, leaving `content` empty and silently falling back to the
            // raw, uncleaned transcript. 2560 leaves comfortable headroom above the ~1700
            // tokens seen in practice for the hardest case tested.
            "max_tokens": 2560,
            "stream": false,
        ])

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw RewriteError.timedOut
        } catch {
            throw RewriteError.unavailable
        }

        guard let http = resp as? HTTPURLResponse else { throw RewriteError.badPayload }
        guard http.statusCode == 200 else { throw RewriteError.http(http.statusCode) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw RewriteError.badPayload }

        return RewritePrompt.sanitize(content, fallback: transcript)
    }
}
