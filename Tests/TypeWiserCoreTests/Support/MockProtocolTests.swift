import Foundation
import Testing
@testable import TypeWiserCore

/// Covers `MockProtocol`'s own unregistered-id path: a request tagged with
/// an id nobody registered a handler for must surface a loud diagnostic
/// (599 + explanatory body) rather than silently returning empty data. A
/// silent fallback would hide exactly the class of bug the per-test
/// registry was built to prevent — a request escaping its test's mock
/// wiring and going unnoticed.
struct MockProtocolTests {
    @Test func unregisteredIdSurfacesLoud599Diagnostic() async throws {
        // Deliberately never registered via MockProtocol.makeSession — we
        // build the session by hand so we can tag it with an id that has
        // no handler behind it.
        let id = UUID().uuidString
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        cfg.httpAdditionalHeaders = [MockProtocol.testIDHeader: id]
        let session = URLSession(configuration: cfg)

        let (data, resp) = try await session.data(from: URL(string: "http://127.0.0.1:1/never-registered")!)

        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 599)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("no handler registered for test id"))
        #expect(body.contains(id))
    }
}
