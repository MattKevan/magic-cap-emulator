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

/// Holds `exchange`'s mutable state. `NWConnection`'s receive and
/// state-update handlers below are the only code that ever touches it, and
/// `exchange` gives the connection its own private serial queue (rather than
/// `.global()`, a concurrent queue) so those handlers never run at the same
/// time — that confinement, not `Sendable` conformance, is what makes sharing
/// this plain class across the handlers safe.
private final class ExchangeState: @unchecked Sendable {
    var received = Data()
    var resumed = false
}

/// Sends raw bytes to the proxy and returns everything until it closes.
private func exchange(port: UInt16, _ text: String) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    // A private serial queue — not `.global()` — so the receive and
    // state-update handlers below are never delivered concurrently.
    let queue = DispatchQueue(label: "com.example.datarover.web-proxy-test-exchange")
    return try await withCheckedThrowingContinuation { continuation in
        let state = ExchangeState()
        func resume(_ result: Result<String, Error>) {
            guard !state.resumed else { return }
            state.resumed = true
            continuation.resume(with: result)
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { state.received.append(data) }
                if complete || error != nil {
                    connection.cancel()
                    resume(.success(String(decoding: state.received, as: UTF8.self)))
                } else { read() }
            }
        }
        connection.stateUpdateHandler = { nwState in
            switch nwState {
            case .ready:
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in read() })
            case .failed(let error):
                connection.cancel()
                resume(.failure(error))
            case .waiting(let error):
                // A regression here should fail the test, not hang it.
                connection.cancel()
                resume(.failure(error))
            case .cancelled:
                resume(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: queue)
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

    /// Regression: `stop()` racing a still-in-flight `start()` used to leave
    /// the listener cancelled without ever resuming `start()`'s continuation,
    /// hanging it forever. The `onStartPending` seam runs the stop on the proxy's
    /// queue while start() is provably pending, so start() must throw
    /// CancellationError promptly.
    @Test func stoppingDuringStartDoesNotHang() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        // Force the race: stop while start() is definitely pending, before the
        // listener's .ready/.cancelled update can be processed on the queue.
        proxy.onStartPending = { [unowned proxy] in proxy.stopOnQueue() }
        let startTask = Task { try await proxy.start() }
        defer { startTask.cancel(); proxy.onStartPending = nil; proxy.stop() }
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await startTask.value; return "returned" }
                catch is CancellationError { return "cancelled" }
                catch { return "other: \(error)" }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return "timeout"
            }
            let first = await group.next() ?? "timeout"
            group.cancelAll()
            return first
        }
        #expect(outcome == "cancelled", "start() should throw CancellationError within 2s of a concurrent stop(); got \(outcome)")
    }
}
