import Foundation

/// Cloud rewriter: Anthropic Messages API (`POST /v1/messages`).
///
/// Swift has no official Anthropic SDK, so this talks to the REST endpoint
/// directly — the same shape as `BedrockRewriter`. Defaults to Haiku 4.5:
/// transcript cleanup is a short, mechanical edit, so the smallest fast model
/// is the right default for latency and cost (mirroring the Nova Lite default
/// on Bedrock). The model is user-configurable in Settings.
public struct AnthropicRewriter: Rewriter {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let endpoint: URL

    public init(apiKey: String,
                model: String = SettingsStore.defaultAnthropicModel,
                session: URLSession = .shared,
                timeout: TimeInterval = 5.0,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
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

        // No `temperature` and no `thinking`: the sampling params were removed on
        // the newest models (a 400 there), and thinking would only add latency to
        // a mechanical edit. Omitting both keeps this valid across every model the
        // user might select, from Haiku 4.5 to Opus 4.8.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": RewritePrompt.system(options: options, context: context),
            "messages": [["role": "user", "content": RewritePrompt.user(transcript)]],
        ])

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RewriteError.badPayload
        }
        // A safety refusal (HTTP 200, `stop_reason: "refusal"`, empty/partial
        // content) is not a rewrite — surface it as unavailable so the session's
        // `?? trimmed` fallback pastes the raw transcript rather than nothing.
        if obj["stop_reason"] as? String == "refusal" { throw RewriteError.unavailable }

        guard let content = obj["content"] as? [[String: Any]] else { throw RewriteError.badPayload }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw RewriteError.badPayload }

        return RewritePrompt.sanitize(text, fallback: transcript)
    }
}
