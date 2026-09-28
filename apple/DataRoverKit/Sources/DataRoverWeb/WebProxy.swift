import Foundation
import Network

/// A listener transitioned to `.ready` without ever assigning a port — should
/// not happen for a TCP listener, but `start()` has to resolve to something.
enum WebProxyError: Error { case noPort }

/// The loopback HTTP server the patched libslirp sends guest port 80 to.
public final class WebProxy: @unchecked Sendable {
    public static let maxConnections = 8
    private let pipeline: ProxyPipeline
    private let queue = DispatchQueue(label: "com.example.datarover.web-proxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The in-flight `start()` continuation, confined to `queue` like every
    /// other piece of mutable state here — resolved exactly once, either by
    /// the listener reaching `.ready`/`.failed`/`.cancelled`, or by a
    /// concurrent `stop()`/`start()` pre-empting it.
    private var pendingStart: CheckedContinuation<UInt16, Error>?

    /// Test-only seam (reach it via `@testable`). Invoked on `queue`, inside
    /// `start()`'s queue work, right after `pendingStart` is set and the
    /// listener started, so a test can deterministically run `stopOnQueue()`
    /// while `start()` is still pending. Never set in production.
    var onStartPending: (() -> Void)?

    public init(pipeline: ProxyPipeline) { self.pipeline = pipeline }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in self?.handleListenerState(state, listener: listener) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                // A listener (or start() call) already in flight is superseded
                // by this one; fail it rather than leaving it to hang.
                self.listener?.cancel()
                self.failPendingStart(with: CancellationError())
                self.pendingStart = continuation
                self.listener = listener
                listener.start(queue: queue)
                self.onStartPending?()
            }
        }
    }

    /// Delivered on `queue` — the queue `listener.start` was given — so every
    /// touch of `pendingStart`/`listener` here is already queue-confined.
    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        // A state update from a listener this proxy has since moved past
        // (superseded by a newer `start()`, or already stopped) is stale.
        guard self.listener === listener else { return }
        switch state {
        case .ready:
            if let port = listener.port {
                resolvePendingStart(.success(port.rawValue))
            } else {
                resolvePendingStart(.failure(WebProxyError.noPort))
            }
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            resolvePendingStart(.failure(error))
        case .cancelled:
            resolvePendingStart(.failure(CancellationError()))
        default:
            break
        }
    }

    /// Resolves `pendingStart` at most once; a state update or `stop()`
    /// arriving after it's already been resolved is a no-op.
    private func resolvePendingStart(_ result: Result<UInt16, Error>) {
        guard let continuation = pendingStart else { return }
        pendingStart = nil
        continuation.resume(with: result)
    }

    private func failPendingStart(with error: Error) {
        resolvePendingStart(.failure(error))
    }

    /// Must not be called on the proxy's own queue (it uses `queue.sync`).
    public func stop() {
        // `stop()` is called from the app's own threads, so every touch of
        // `listener`/`pendingStart`/`connections` is confined to the serial
        // queue — including failing a `start()` still waiting on this
        // listener, so it throws instead of hanging forever.
        queue.sync { stopOnQueue() }
    }

    /// The body of `stop()`; must run on `queue`.
    func stopOnQueue() {
        listener?.cancel()
        listener = nil
        failPendingStart(with: CancellationError())
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
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
