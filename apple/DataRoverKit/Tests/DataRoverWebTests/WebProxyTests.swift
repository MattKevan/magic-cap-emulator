import Foundation
import Network
import Testing
@testable import DataRoverWeb

private struct EchoFetcher: UpstreamFetching {
    func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse {
        UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                         body: Data("\(request.method) \(request.host)\(request.target)".utf8),
                         url: URL(string: "https://\(request.host)\(request.target)")!)
    }
}

/// Sends raw bytes to the proxy and returns everything until it closes.
private func exchange(port: UInt16, _ text: String) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    return try await withCheckedThrowingContinuation { continuation in
        var received = Data()
        var resumed = false
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { received.append(data) }
                if complete || error != nil {
                    connection.cancel()
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: String(decoding: received, as: UTF8.self))
                } else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in read() })
            } else if case .failed(let error) = state {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        }
        connection.start(queue: .global())
    }
}

@Suite struct WebProxyTests {
    @Test func servesARequestOverLoopback() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        #expect(port != 0)
        let reply = try await exchange(port: port, "GET /hello HTTP/1.0\r\nHost: example.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 200"))
        #expect(reply.hasSuffix("GET example.com/hello"))
    }

    @Test func omitsBodiesForHead() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        let reply = try await exchange(port: port, "HEAD /x HTTP/1.0\r\nHost: example.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 200") && reply.hasSuffix("\r\n\r\n"))
    }

    @Test func answersMalformedRequestsWithAnErrorPage() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        let reply = try await exchange(port: port, "BREW /pot HTTP/1.0\r\nHost: e.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 405"))
    }
}
