import Foundation

/// Answers HTTP requests from a closure so download tests never touch the network. One handler at a time: XCTest
/// runs these tests one after another.
final class StubDownloadServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func serve(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            requests = []
        }
    }

    static func stop() {
        lock.withLock { handler = nil }
    }

    static var receivedRequests: [URLRequest] { lock.withLock { requests } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadServer.self]
        return configuration
    }

    /// Serves `content` the way a file host does: 206 with `Content-Range` for a Range request.
    static func rangeHonouringReply(for request: URLRequest, content: Data) -> Reply {
        guard let range = request.value(forHTTPHeaderField: "Range"),
            let offset = Int(range.replacingOccurrences(of: "bytes=", with: "").replacingOccurrences(of: "-", with: ""))
        else {
            return Reply(status: 200, body: content)
        }
        return Reply(
            status: 206,
            headers: ["Content-Range": "bytes \(offset)-\(content.count - 1)/\(content.count)"],
            body: content.suffix(from: offset)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
