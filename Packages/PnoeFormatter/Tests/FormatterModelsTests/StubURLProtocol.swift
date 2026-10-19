import Foundation

/// Answers requests from a closure instead of the network. Routed by host, so tests running in parallel each
/// register their own host and never see each other's handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.url?.host.flatMap { host in Self.lock.withLock { Self.handlers[host] } }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
