import Foundation

/// Intercepts `URLSession` traffic so tests never touch the network.
///
/// Handlers used to live behind a pair of process-global statics
/// (`handler`, `requestCount`). That worked only as long as a single suite
/// ran at a time — but Swift Testing schedules independent top-level
/// suites *concurrently* with each other (`.serialized` only orders tests
/// within one suite), so two suites sharing those globals could corrupt
/// each other's handler and counter.
///
/// Instead, every caller registers its handler under a unique id (a fresh
/// `UUID` per test) via `makeSession(id:handler:)`. The id rides along on
/// every request as the `X-Mock-Test-ID` header (via
/// `URLSessionConfiguration.httpAdditionalHeaders`), and `startLoading()`
/// looks up that id's handler and bumps that id's counter. Because no two
/// tests ever share an id, there is no shared mutable state left to race on
/// — concurrent scheduling, across suites or within one, is safe by
/// construction rather than by requiring serialization.

/// What a mock handler can produce for a given request: either a simulated
/// HTTP response, or a simulated transport failure (e.g. the connection
/// never got established, or timed out) — the two things `URLSession`
/// itself can hand back to a caller.
enum MockResponse: Sendable {
    case http(Int, Data)
    case failure(URLError)
}

final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let testIDHeader = "X-Mock-Test-ID"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) async -> MockResponse] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// Registers `responder` under `id` and returns a `URLSession` that
    /// routes all its traffic through `MockProtocol`, tagging every
    /// outgoing request with `id` so `startLoading()` can find this
    /// responder. Use this form when a test needs to simulate a transport
    /// failure (`.failure`) rather than an HTTP response (`.http`).
    static func makeSession(id: String,
                            responder: @escaping @Sendable (URLRequest) async -> MockResponse) -> URLSession {
        lock.lock()
        handlers[id] = responder
        counts[id] = 0
        lock.unlock()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        cfg.httpAdditionalHeaders = [testIDHeader: id]
        return URLSession(configuration: cfg)
    }

    /// Convenience form for the common case: a handler that only ever
    /// produces an HTTP response. Thin wrapper over `makeSession(id:responder:)`.
    static func makeSession(id: String,
                            handler: @escaping @Sendable (URLRequest) async -> (Int, Data)) -> URLSession {
        makeSession(id: id) { req in
            let (code, data) = await handler(req)
            return .http(code, data)
        }
    }

    static func requestCount(id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[id] ?? 0
    }

    /// Not strictly required for correctness (ids never collide), but keeps
    /// the registry from growing unbounded across a long test run.
    static func unregister(id: String) {
        lock.lock()
        handlers.removeValue(forKey: id)
        counts.removeValue(forKey: id)
        lock.unlock()
    }

    /// Looks up the handler registered for `id` (if any), bumping its
    /// counter atomically in the same critical section as the lookup.
    private static func lookupAndCount(id: String?) -> (@Sendable (URLRequest) async -> MockResponse)? {
        lock.lock()
        defer { lock.unlock() }
        guard let id, let handler = handlers[id] else { return nil }
        counts[id, default: 0] += 1
        return handler
    }

    /// Fail loudly rather than silently returning empty data: a missing
    /// handler means some request escaped its test's mock wiring, which is
    /// exactly the class of bug per-test isolation exists to catch.
    private static func missingHandlerResponse(id: String?) -> MockResponse {
        let body = """
            MockProtocol: no handler registered for test id \
            \(id ?? "<missing \(testIDHeader) header>"). \
            Requests must go through a URLSession returned by \
            MockProtocol.makeSession(id:handler:).
            """
        return .http(599, Data(body.utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}

    override func startLoading() {
        let req = request
        let id = req.value(forHTTPHeaderField: Self.testIDHeader)
        let handler = Self.lookupAndCount(id: id)
        // Computed eagerly, outside the `Task`, purely to work around a
        // Swift 6 SIL diagnostics bug ("pattern that the region based
        // isolation checker does not understand how to check") that fires
        // when a synchronous fallback call appears on the RHS of `??`
        // alongside an `await`-ed optional closure call inside a `Task { }`
        // whose enclosing method captures `self` via `UnsafeBox`. Hoisting
        // the fallback value out sidesteps the bug without changing behavior.
        let missingHandlerFallback = Self.missingHandlerResponse(id: id)

        let box = UnsafeBox(value: self)
        Task {
            let result = await (handler?(req) ?? missingHandlerFallback)
            let this = box.value
            switch result {
            case .http(let code, let data):
                let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                this.client?.urlProtocol(this, didReceive: resp, cacheStoragePolicy: .notAllowed)
                this.client?.urlProtocol(this, didLoad: data)
                this.client?.urlProtocolDidFinishLoading(this)
            case .failure(let err):
                this.client?.urlProtocol(this, didFailWithError: err)
            }
        }
    }
}

/// Swift 6's "sending parameter" checker flags any `Task { self... }` closure
/// inside an overridden `URLProtocol` method — even with `self` declared
/// `@unchecked Sendable` — because it treats the method receiver specially.
/// Boxing the reference sidesteps that specific heuristic without weakening
/// concurrency checking anywhere else.
private struct UnsafeBox<T>: @unchecked Sendable { let value: T }
