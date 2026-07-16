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

    static func canonicalRequest(method: String, path: String, query: String,
                                 headers: [String: String], bodyHash: String) -> String {
        let sorted = headers.map { ($0.key.lowercased(), $0.value) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
        let signedHeaders = sorted.map(\.0).joined(separator: ";")
        return [method, path, query, canonicalHeaders + "\n", signedHeaders, bodyHash]
            .joined(separator: "\n")
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

        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query ?? ""
        let cr = canonicalRequest(method: req.httpMethod ?? "POST", path: path,
                                  query: query, headers: headers, bodyHash: bodyHash)

        let scope = "\(dateStamp)/\(credentials.region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hexSHA256(Data(cr.utf8))]
            .joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        key = hmac(key, dateStamp)
        key = hmac(key, credentials.region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hmacHex(key, stringToSign)

        let signedHeaders = headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
        headers["authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }
}
