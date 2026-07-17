import Foundation
import Testing
@testable import TypeWiserCore

private let creds = AWSCredentials(
    accessKeyID: "AKIDEXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
)

@Test func hexSHA256MatchesKnownVector() {
    // Well-known: SHA256 of the empty string.
    #expect(SigV4.hexSHA256(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func signingProducesAuthorizationHeader() {
    var req = URLRequest(url: URL(string: "https://bedrock-runtime.ap-south-1.amazonaws.com/model/x/invoke")!)
    req.httpMethod = "POST"
    let signed = SigV4.sign(request: req, body: Data("{}".utf8), service: "bedrock",
                            credentials: creds, date: Date(timeIntervalSince1970: 1_440_938_160))
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""
    #expect(auth.hasPrefix("AWS4-HMAC-SHA256 "))
    #expect(auth.contains("Credential=AKIDEXAMPLE/"))
    #expect(auth.contains("SignedHeaders="))
    #expect(auth.contains("Signature="))
}

@Test func signingSetsRequiredHeaders() {
    var req = URLRequest(url: URL(string: "https://bedrock-runtime.ap-south-1.amazonaws.com/model/x/invoke")!)
    req.httpMethod = "POST"
    let body = Data("{\"a\":1}".utf8)
    let signed = SigV4.sign(request: req, body: body, service: "bedrock",
                            credentials: creds, date: Date(timeIntervalSince1970: 1_440_938_160))
    #expect(signed.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
    #expect(signed.value(forHTTPHeaderField: "X-Amz-Content-Sha256") == SigV4.hexSHA256(body))
    #expect(signed.value(forHTTPHeaderField: "Host") == "bedrock-runtime.ap-south-1.amazonaws.com")
}

@Test func signatureIsDeterministic() {
    var req = URLRequest(url: URL(string: "https://bedrock-runtime.ap-south-1.amazonaws.com/model/x/invoke")!)
    req.httpMethod = "POST"
    let d = Date(timeIntervalSince1970: 1_440_938_160)
    let a = SigV4.sign(request: req, body: Data("{}".utf8), service: "bedrock", credentials: creds, date: d)
    let b = SigV4.sign(request: req, body: Data("{}".utf8), service: "bedrock", credentials: creds, date: d)
    #expect(a.value(forHTTPHeaderField: "Authorization") == b.value(forHTTPHeaderField: "Authorization"))
}

@Test func differentBodiesProduceDifferentSignatures() {
    var req = URLRequest(url: URL(string: "https://bedrock-runtime.ap-south-1.amazonaws.com/model/x/invoke")!)
    req.httpMethod = "POST"
    let d = Date(timeIntervalSince1970: 1_440_938_160)
    let a = SigV4.sign(request: req, body: Data("{\"a\":1}".utf8), service: "bedrock", credentials: creds, date: d)
    let b = SigV4.sign(request: req, body: Data("{\"a\":2}".utf8), service: "bedrock", credentials: creds, date: d)
    #expect(a.value(forHTTPHeaderField: "Authorization") != b.value(forHTTPHeaderField: "Authorization"))
}

// Regression test for a real production 403, root-caused and fixed against live AWS
// (not just mocks — see task-8-fix-report.md). Two things had to be true simultaneously:
//
// 1. `URL.path` returns the percent-*decoded* path, but the wire request carries the
//    percent-*encoded* path (e.g. a Bedrock model ID's `:` encoded as `%3A`). Signing the
//    decoded form is a guaranteed mismatch against the request AWS actually receives.
// 2. AWS's own documented SigV4 rule ("Elements of a canonical request") is that every
//    service except S3 gets its path segments URI-encoded TWICE for the canonical
//    request — the wire path itself stays singly-encoded. Confirmed directly against a
//    live 403 response: AWS's error body named the canonical string it wanted as
//    containing `%253A` (i.e. `%3A`'s `%` re-escaped to `%25`), not the singly-encoded
//    `%3A`. A signer that used the singly-encoded path in its canonical request (as an
//    earlier version of this fix did) still got HTTP 403 for exactly this reason.
//
// This pins that `sign()` builds its canonical request from the DOUBLY-encoded path.
@Test func signUsesDoublyEncodedPathForCanonicalRequest() {
    let url = URL(string:
        "https://bedrock-runtime.ap-south-1.amazonaws.com/model/apac.amazon.nova-lite-v1%3A0/invoke")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    let body = Data("{}".utf8)
    let date = Date(timeIntervalSince1970: 1_440_938_160)
    let signed = SigV4.sign(request: req, body: body, service: "bedrock", credentials: creds, date: date)

    guard let auth = signed.value(forHTTPHeaderField: "Authorization"),
          let sigRange = auth.range(of: "Signature=") else {
        Issue.record("sign() did not set an Authorization header")
        return
    }
    let actualSignature = String(auth[sigRange.upperBound...])

    let bodyHash = SigV4.hexSHA256(body)
    let headers = [
        "host": "bedrock-runtime.ap-south-1.amazonaws.com",
        "x-amz-date": "20150830T123600Z",
        "x-amz-content-sha256": bodyHash,
        "content-type": "application/json",
    ]

    // Reconstruct the canonical request the way `sign()` is required to build it: the wire
    // path's `%3A` re-encoded to `%253A` (its `%` escaped to `%25`).
    let doublyEncodedPathCR = SigV4.canonicalRequest(
        method: "POST", path: "/model/apac.amazon.nova-lite-v1%253A0/invoke", query: "",
        headers: headers, bodyHash: bodyHash
    )
    #expect(doublyEncodedPathCR.contains("%253A"))
    #expect(!doublyEncodedPathCR.contains("v1:0"))

    let scope = "20150830/\(creds.region)/bedrock/aws4_request"
    let expectedStringToSign = [
        "AWS4-HMAC-SHA256", "20150830T123600Z", scope, SigV4.hexSHA256(Data(doublyEncodedPathCR.utf8)),
    ].joined(separator: "\n")
    let expectedSignature = SigV4.signature(
        stringToSign: expectedStringToSign, secretAccessKey: creds.secretAccessKey,
        dateStamp: "20150830", region: creds.region, service: "bedrock"
    )

    // The signature `sign()` actually produced must match the one derived from the
    // DOUBLY-encoded path — proving `sign()` signs `%253A`, matching AWS's own canonicalization.
    #expect(actualSignature == expectedSignature)

    // Sanity check that this test would actually catch a regression to either wrong
    // encoding: both the decoded path and the singly-encoded path produce a different
    // canonical request (and thus a different, non-matching signature) than the
    // doubly-encoded one this test pins.
    let decodedPathCR = SigV4.canonicalRequest(
        method: "POST", path: "/model/apac.amazon.nova-lite-v1:0/invoke", query: "",
        headers: headers, bodyHash: bodyHash
    )
    let singlyEncodedPathCR = SigV4.canonicalRequest(
        method: "POST", path: "/model/apac.amazon.nova-lite-v1%3A0/invoke", query: "",
        headers: headers, bodyHash: bodyHash
    )
    #expect(decodedPathCR != doublyEncodedPathCR)
    #expect(singlyEncodedPathCR != doublyEncodedPathCR)
}

@Test func canonicalRequestHasEightLines() {
    let cr = SigV4.canonicalRequest(
        method: "POST", path: "/model/x/invoke", query: "",
        headers: ["host": "example.com", "x-amz-date": "20150830T123600Z"],
        bodyHash: SigV4.hexSHA256(Data())
    )
    // method, path, query, 2 canonical header lines, a blank line, signed headers, hash = 8 lines.
    // (Verified against AWS's published "get-vanilla" vector below, which has the same
    // host+x-amz-date header pair and is 8 lines long.)
    #expect(cr.components(separatedBy: "\n").count == 8)
    #expect(cr.hasPrefix("POST\n/model/x/invoke\n\n"))
    #expect(cr.contains("host;x-amz-date"))
}

// Real AWS-published test vector ("get-vanilla" from AWS's official SigV4 test suite,
// https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html, mirrored at
// https://github.com/saibotsivad/aws-sig-v4-test-suite). Fetched and confirmed byte-exact
// against a standalone reproduction of the signing algorithm before being added here.
// This uses the same AKIDEXAMPLE / wJalrXUtn... dummy credentials as the rest of this file.
@Test func canonicalRequestMatchesAWSPublishedVanillaVector() {
    let cr = SigV4.canonicalRequest(
        method: "GET", path: "/", query: "",
        headers: ["host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"],
        bodyHash: SigV4.hexSHA256(Data())
    )
    let expected = """
    GET
    /

    host:example.amazonaws.com
    x-amz-date:20150830T123600Z

    host;x-amz-date
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    """
    #expect(cr == expected)

    // The hash of that canonical request must equal the published hash embedded in
    // AWS's "string to sign" fixture for this vector.
    #expect(SigV4.hexSHA256(Data(cr.utf8)) ==
            "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
}

// Full signing-chain coverage against the same AWS-published "get-vanilla" vector
// (AWS SigV4 test suite, https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html,
// mirrored at https://github.com/saibotsivad/aws-sig-v4-test-suite). Unlike the test above
// (which only covers canonicalRequest/hexSHA256), this exercises the HMAC signing-key
// derivation chain (secret -> date -> region -> service -> "aws4_request") and the final
// signature via the same `SigV4.signature` function `sign()` calls internally — not a
// duplicated reimplementation. A refactor that reorders/breaks the key-derivation steps
// would fail this test even though it might still pass the purely-relative determinism
// tests above.
//
// Note: this vector's region ("us-east-1") and service ("service") are AWS's published
// fixture values, not this project's real "bedrock"/"ap-south-1" — intentionally left
// as-is so the assertion matches AWS's ground truth exactly.
//
// The published string-to-sign for this vector embeds the canonical request's hash
// (verified above as bb579772...); we build the string-to-sign from that same
// just-verified hash rather than re-pasting it, so this test can't silently drift out of
// sync with the creq/hash link proven above.
@Test func signatureMatchesAWSPublishedVanillaVector() {
    let cr = SigV4.canonicalRequest(
        method: "GET", path: "/", query: "",
        headers: ["host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"],
        bodyHash: SigV4.hexSHA256(Data())
    )
    let crHash = SigV4.hexSHA256(Data(cr.utf8))
    #expect(crHash == "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")

    let stringToSign = [
        "AWS4-HMAC-SHA256",
        "20150830T123600Z",
        "20150830/us-east-1/service/aws4_request",
        crHash,
    ].joined(separator: "\n")

    let signature = SigV4.signature(
        stringToSign: stringToSign,
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        dateStamp: "20150830",
        region: "us-east-1",
        service: "service"
    )
    #expect(signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
}
