import Foundation

/// Cloud rewriter: AWS Bedrock InvokeModel against Amazon Nova.
public struct BedrockRewriter: Rewriter {
    private let credentials: AWSCredentials
    private let modelID: String
    private let session: URLSession
    private let timeout: TimeInterval

    /// RFC 3986 "unreserved" characters (letters, digits, `-`, `.`, `_`, `~`) — the exact
    /// set that AWS SigV4 canonical-URI-encoding leaves literal. Everything else, including
    /// `:`, must be percent-encoded (e.g. `apac.amazon.nova-lite-v1:0` -> `...v1%3A0`).
    ///
    /// `SigV4.sign` signs the URL's percent-*encoded* path (see `SigV4.swift`), so the encoded
    /// model ID used to build the URL here and the path SigV4 signs must agree byte-for-byte
    /// with what AWS's canonicalization expects. Previously this set also allowed `:` literal,
    /// which produced a request path with a raw colon — AWS's servers still canonicalize that
    /// colon to `%3A` when checking the signature, so a signer that also left it un-encoded
    /// (as this one used to, reading `URL.path`) happened to "agree" with the URL, but neither
    /// agreed with AWS, causing HTTP 403 on every real Bedrock request that hit an
    /// InvokeModel model ID containing a colon (i.e. every model ID that carries a version,
    /// which is effectively all of them).
    private static let modelIDAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
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
