import Foundation
import Testing

/// Parent suite for every test that uses `StubURLProtocol`. Its state is
/// process-wide and Swift Testing runs separate suites in parallel, so all such
/// suites nest here; `.serialized` on the parent serializes the nested ones too.
@Suite(.serialized) struct StubbedNetworkTests {}

/// Serves canned responses by URL for URLSession tests. Tests using it must
/// live in a suite nested in `StubbedNetworkTests`: the handler is process-wide.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case response(Int, [String: String], Data), failure(URLError.Code) }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            recorded.httpBody = data
        }
        Self.seen.append(recorded)
        switch Self.replies[request.url!.absoluteString] ?? .failure(.cannotFindHost) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
