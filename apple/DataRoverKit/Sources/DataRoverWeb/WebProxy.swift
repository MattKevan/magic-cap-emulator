import Foundation
import Network

/// The loopback HTTP server the patched libslirp sends guest port 80 to.
public final class WebProxy: @unchecked Sendable {
    public static let maxConnections = 8
    private let pipeline: ProxyPipeline
    private let queue = DispatchQueue(label: "com.example.datarover.web-proxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(pipeline: ProxyPipeline) { self.pipeline = pipeline }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // Mutating `listener` here (rather than after `withCheckedThrowingContinuation`
        // returns) races a concurrent `stop()` on another thread; confine the write to
        // the serial queue, same as every other touch of this proxy's mutable state.
        queue.sync { self.listener = listener }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        // `stop()` is called from the app's own threads, so every touch of
        // `listener`/`connections` is confined to the serial queue.
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard connections.count < Self.maxConnections else {
            send(ProxyPipeline.errorPage(status: 503, reason: "Service Unavailable", title: "Too many requests",
                                         detail: "Wait a moment and try again."), includeBody: true, on: connection)
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        queue.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            self.close(connection)
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch RequestParser.parse(accumulated) {
            case .complete(let request):
                Task {
                    let response = await self.pipeline.respond(to: request)
                    self.queue.async { self.send(response, includeBody: request.method != "HEAD", on: connection) }
                }
            case .invalid(let status):
                self.send(ProxyPipeline.errorPage(status: status, reason: Self.reason(forStatus: status),
                                                  title: "Request not understood",
                                                  detail: "The browser sent a request the proxy can't handle."),
                          includeBody: true, on: connection)
            case .incomplete:
                if complete || error != nil { self.close(connection) } else { self.receive(on: connection, buffer: accumulated) }
            }
        }
    }

    private func send(_ response: ProxyResponse, includeBody: Bool, on connection: NWConnection) {
        connection.send(content: response.serialized(includeBody: includeBody), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    /// A fixed, ASCII-only status line reason. `HTTPURLResponse.localizedString`
    /// is localized and can return non-ASCII text, which doesn't belong in an
    /// HTTP status line.
    private static func reason(forStatus status: Int) -> String {
        switch status {
        case 400: return "Bad Request"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Bad Request"
        }
    }
}
