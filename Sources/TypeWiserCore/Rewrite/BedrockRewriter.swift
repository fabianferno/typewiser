import Foundation

/// Cloud rewriter: AWS Bedrock InvokeModel against Amazon Nova.
public struct BedrockRewriter: Rewriter {
    private let credentials: AWSCredentials
    private let modelID: String
    private let session: URLSession
    private let timeout: TimeInterval

    /// Characters a Bedrock model ID may contain (letters, digits, `.`, `-`, `_`, `~`, `:`)
    /// that are also legal, unescaped, in a URL path segment (RFC 3986 `pchar`).
    ///
    /// `SigV4.sign` builds its canonical request from `URLRequest.url!.path`, which Foundation
    /// always returns percent-*decoded*. If we percent-encoded any of these characters here
    /// (e.g. via `.alphanumerics`, which would escape the dots, hyphens and colon in
    /// "apac.amazon.nova-lite-v1:0"), the signed path and the actual on-the-wire request path
    /// (which keeps the raw percent-escapes from the URL string) would diverge, and AWS would
    /// reject the signature. Allowing exactly the model-ID characters that don't need escaping
    /// means `addingPercentEncoding` is a no-op for our real model ID, so the signed path and
    /// the wire path are always byte-identical — while still defensively escaping anything
    /// unexpected (e.g. a `/`) if a future model ID ever needed it.
    private static let modelIDAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:")
        return set
    }()

    public init(credentials: AWSCredentials,
                modelID: String = "apac.amazon.nova-lite-v1:0",
                session: URLSession = .shared,
                timeout: TimeInterval = 2.0) {
        self.credentials = credentials
        self.modelID = modelID
        self.session = session
        self.timeout = timeout
    }

    public func rewrite(_ transcript: String,
                        options: RewriteOptions,
                        context: RewriteContext) async throws -> String {
        guard !options.isNoOp else { return transcript }

        let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: Self.modelIDAllowedCharacters) ?? modelID
        let url = URL(string: "https://bedrock-runtime.\(credentials.region).amazonaws.com/model/\(encodedModel)/invoke")!

        let body = try JSONSerialization.data(withJSONObject: [
            "system": [["text": RewritePrompt.system(options: options, context: context)]],
            "messages": [["role": "user", "content": [["text": RewritePrompt.user(transcript)]]]],
            "inferenceConfig": ["maxTokens": 512, "temperature": 0],
        ])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        let signed = SigV4.sign(request: req, body: body, service: "bedrock", credentials: credentials)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: signed)
        } catch let e as URLError where e.code == .timedOut {
            throw RewriteError.timedOut
        } catch {
            throw RewriteError.unavailable
        }

        guard let http = resp as? HTTPURLResponse else { throw RewriteError.badPayload }
        guard http.statusCode == 200 else { throw RewriteError.http(http.statusCode) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { throw RewriteError.badPayload }

        return RewritePrompt.sanitize(text, fallback: transcript)
    }
}
