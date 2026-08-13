import Foundation

/// Cloud rewriter: OpenAI Chat Completions API (`POST /v1/chat/completions`).
///
/// Same OpenAI-compatible shape `LocalLlamaRewriter` uses, pointed at OpenAI
/// with a bearer key. Defaults to a small, fast model — transcript cleanup is a
/// mechanical edit, not a reasoning task. The model is user-configurable.
public struct OpenAIRewriter: Rewriter {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let endpoint: URL

    public init(apiKey: String,
                model: String = SettingsStore.defaultOpenAIModel,
                session: URLSession = .shared,
                timeout: TimeInterval = 5.0,
                endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.timeout = timeout
        self.endpoint = endpoint
    }

    public func rewrite(_ transcript: String,
                        options: RewriteOptions,
                        context: RewriteContext) async throws -> String {
        guard !options.isNoOp else { return transcript }

        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": RewritePrompt.system(options: options, context: context, transcript: transcript)],
                ["role": "user", "content": RewritePrompt.user(transcript)],
            ],
            "temperature": 0,
        ])

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

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
