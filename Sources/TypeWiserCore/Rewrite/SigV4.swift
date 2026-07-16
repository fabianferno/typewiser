import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let region: String

    public init(accessKeyID: String, secretAccessKey: String, region: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
    }
}

/// Minimal AWS Signature V4 signer.
///
/// Hand-rolled instead of depending on the AWS SDK: this is the only AWS surface
/// the app touches, and the SDK is a large dependency for one signed POST.
public enum SigV4 {
    public static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: SymmetricKey, _ data: String) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: key)))
    }

    private static func hmacHex(_ key: SymmetricKey, _ data: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986 unreserved characters — the set AWS's SigV4 URI-encoding step leaves
    /// literal. Everything else (including `%` itself) gets percent-encoded.
    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Re-encodes an already percent-encoded path for use in the canonical request.
    ///
    /// AWS's documented SigV4 rule ("Elements of a canonical request"): "Each path segment
    /// must be URI-encoded twice (except for Amazon S3, which only gets URI-encoded once)."
    /// So for Bedrock (not S3), the canonical URI is the wire path's percent-encoding
    /// applied a SECOND time: an existing `%3A` has its `%` re-escaped to `%25`, becoming
    /// `%253A`. Confirmed directly against AWS: a live signed request built with only a
    /// single-encoded path (`%3A`) still got HTTP 403, and AWS's error body named the
    /// canonical string it wanted as containing `%253A`.
    ///
    /// Splits on `/` and encodes each segment independently so the slash separators
    /// themselves are never re-escaped.
    private static func doubleEncode(path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? String($0) }
            .joined(separator: "/")
    }

    // NOTE: this does no URI percent-encoding of `path` and no canonical query-string
    // key/value sorting of `query` — callers are expected to pass an already-encoded
    // path and an already-canonicalized query string. That's fine for Bedrock's
    // `InvokeModel` POST (no query string, path is just a model ID segment), but a
    // signer for other AWS services (S3, anything with query params) would need to
    // add that encoding step here.
    static func canonicalRequest(method: String, path: String, query: String,
                                 headers: [String: String], bodyHash: String) -> String {
        let sorted = headers.map { ($0.key.lowercased(), $0.value) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
        let signedHeaders = sorted.map(\.0).joined(separator: ";")
        return [method, path, query, canonicalHeaders + "\n", signedHeaders, bodyHash]
            .joined(separator: "\n")
    }

    /// Derives the AWS4 signing key (`"AWS4" + secret` → date → region → service →
    /// `"aws4_request"`, each step an HMAC-SHA256) and uses it to HMAC the given
    /// string-to-sign, returning the hex-encoded signature.
    ///
    /// Extracted as its own testable function so the signing-key derivation chain and
    /// final signature can be pinned against AWS's published test vectors independently
    /// of `sign()`'s header handling. `sign()` below calls this directly — it is not a
    /// parallel/duplicated implementation.
    static func signature(stringToSign: String, secretAccessKey: String, dateStamp: String,
                          region: String, service: String) -> String {
        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        key = hmac(key, dateStamp)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        return hmacHex(key, stringToSign)
    }

    public static func sign(request: URLRequest, body: Data, service: String,
                            credentials: AWSCredentials, date: Date = Date()) -> URLRequest {
        var req = request
        guard let url = req.url, let host = url.host else { return req }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: date)
        fmt.dateFormat = "yyyyMMdd"
        let dateStamp = fmt.string(from: date)

        let bodyHash = hexSHA256(body)
        var headers = [
            "host": host,
            "x-amz-date": amzDate,
            "x-amz-content-sha256": bodyHash,
            "content-type": "application/json",
        ]

        // `URL.path` returns the percent-*decoded* path, but the wire request carries the
        // percent-*encoded* path (e.g. a Bedrock model ID's `:` encoded as `%3A`).
        // `URLComponents.percentEncodedPath` preserves that encoding as built into the URL.
        //
        // The canonical request AWS computes on its side is a SECOND encoding on top of
        // that (see `doubleEncode` above) — the wire path itself stays singly-encoded.
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        let wirePath = (encodedPath?.isEmpty ?? true) ? "/" : encodedPath!
        let path = doubleEncode(path: wirePath)
        let query = url.query ?? ""
        let cr = canonicalRequest(method: req.httpMethod ?? "POST", path: path,
                                  query: query, headers: headers, bodyHash: bodyHash)

        let scope = "\(dateStamp)/\(credentials.region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hexSHA256(Data(cr.utf8))]
            .joined(separator: "\n")

        let sig = signature(stringToSign: stringToSign, secretAccessKey: credentials.secretAccessKey,
                            dateStamp: dateStamp, region: credentials.region, service: service)

        let signedHeaders = headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
        headers["authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(sig)"

        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }
}
