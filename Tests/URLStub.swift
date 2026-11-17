import Foundation

/// Answers every request of a session built with `URLStub.session()` from `handler`,
/// so the API clients run end to end without touching the network.
final class URLStub: URLProtocol {
    enum Reply {
        case http(status: Int, body: Data, headers: [String: String] = [:])
        case error(Error)
    }

    /// Set by each test; tests run serially.
    nonisolated(unsafe) static var handler: (URLRequest) -> Reply = { _ in .error(URLError(.notConnectedToInternet)) }
    /// Every request the stub answered, in order.
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(_ handler: @escaping (URLRequest) -> Reply) {
        self.handler = handler
        requests = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLStub.requests.append(request)
        switch URLStub.handler(request) {
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
