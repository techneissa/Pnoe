import Foundation

/// Answers requests from a per-host handler, so tests run in parallel without sharing state. A handler that
/// returns `nil` never answers (a hung server); the request ends when the client cancels or times out.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (status: Int, body: Data)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [(URLRequest, Data)]] = [:]

    /// A session whose requests all go to the stub, and the host to use in the endpoint URL.
    static func makeSession(_ handler: @escaping Handler) -> (session: URLSession, host: String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URLSession(configuration: configuration), host)
    }

    /// Requests received for `host`, with their bodies.
    static func requests(for host: String) -> [(request: URLRequest, body: Data)] {
        lock.withLock { seen[host] ?? [] }.map { (request: $0.0, body: $0.1) }
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = Self.readBody(request)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[host, default: []].append((request, body))
            return Self.handlers[host]
        }
        do {
            guard let handler, let answer = try handler(request, body) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
