import Foundation
import Network
import Darwin
import DataRoverWeb

/// A small loopback HTTP-to-HTTPS forward proxy for the guest's fixed proxy
/// configuration. HTTPS remains protected by the host's normal TLS validation.
final class HTTPSProxy {
    static let port: UInt16 = 8765
    private let queue = DispatchQueue(label: "com.example.datarover.https-proxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let maxConnections = 8
    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 2 * 1024 * 1024

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { _ in }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listener = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            respond(connection, status: "503 Service Unavailable", body: Data())
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        if case .setup = connection.state { connection.start(queue: queue) }
        queue.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            connection.cancel()
            self.finish(connection)
        }
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxHeaderBytes + maxBodyBytes - buffer.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard accumulated.count <= self.maxHeaderBytes + self.maxBodyBytes else {
                self.finish(connection); self.respond(connection, status: "413 Payload Too Large", body: Data()); return
            }
            if let boundary = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = accumulated[..<boundary.lowerBound]
                guard boundary.lowerBound <= self.maxHeaderBytes,
                      let text = String(data: head, encoding: .utf8) else {
                    self.finish(connection); self.respond(connection, status: "400 Bad Request", body: Data()); return
                }
                let contentLength = text.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard contentLength >= 0, contentLength <= self.maxBodyBytes else {
                    self.finish(connection); self.respond(connection, status: "413 Payload Too Large", body: Data()); return
                }
                if accumulated.count >= boundary.upperBound + contentLength {
                    guard let request = Self.parse(accumulated, headerLimit: self.maxHeaderBytes, bodyLimit: self.maxBodyBytes) else {
                        self.respond(connection, status: "400 Bad Request", body: Data()); return
                    }
                    self.forward(request, over: connection)
                    return
                }
            }
            guard !complete, error == nil else {
                self.finish(connection); self.respond(connection, status: "400 Bad Request", body: Data()); return
            }
            self.receiveRequest(connection, buffer: accumulated)
        }
    }

    private func finish(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)) }

    private struct Request {
        let method: String
        let url: URL
        let headers: [(String, String)]
        let body: Data
    }

    private static func parse(_ data: Data, headerLimit: Int, bodyLimit: Int) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)), end.lowerBound <= headerLimit,
              let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3, ["GET", "HEAD", "POST"].contains(String(parts[0])),
              let url = URL(string: String(parts[1])), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        if let port = url.port, !(1...65_535).contains(port) { return nil }
        guard !url.isFileURL, DestinationPolicy.allows(host) else { return nil }
        var headers: [(String, String)] = []
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ":" }) else { return nil }
            if name.lowercased() == "transfer-encoding" { return nil }
            if ["proxy-authorization", "connection", "host"].contains(name.lowercased()) { continue }
            if name.lowercased() == "content-length" {
                guard let length = Int(value), length >= 0, length <= bodyLimit else { return nil }
                contentLength = length
            }
            headers.append((name, value))
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart == contentLength else { return nil }
        return Request(method: String(parts[0]), url: url, headers: headers, body: data[bodyStart...])
    }



    private func forward(_ request: Request, over client: NWConnection) {
        let tls = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let host = NWEndpoint.Host.name(request.url.host!, nil)
        guard let rawPort = UInt16(exactly: request.url.port ?? 443), let port = NWEndpoint.Port(rawValue: rawPort) else {
            finish(client); respond(client, status: "400 Bad Request", body: Data()); return
        }
        let upstream = NWConnection(to: .hostPort(host: host, port: port), using: parameters)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { upstream.cancel(); return }
            if case .ready = state {
                var message = "\(request.method) \(request.url.path.isEmpty ? "/" : request.url.path)\(request.url.query.map { "?\($0)" } ?? "") HTTP/1.1\r\nHost: \(request.url.host!)\r\nConnection: close\r\n"
                for (name, value) in request.headers { message += "\(name): \(value)\r\n" }
                message += "\r\n"
                var payload = Data(message.utf8)
                payload.append(request.body)
                upstream.send(content: payload, completion: .contentProcessed { error in
                    if error != nil { self.respond(client, status: "502 Bad Gateway", body: Data()); upstream.cancel(); return }
                    self.readResponse(upstream, client: client, buffer: Data())
                })
            } else if case .failed = state {
                self.respond(client, status: "502 Bad Gateway", body: Data()); upstream.cancel()
            }
        }
        upstream.start(queue: queue)
    }

    private func readResponse(_ upstream: NWConnection, client: NWConnection, buffer: Data) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { upstream.cancel(); client.cancel(); return }
            var combined = buffer
            if let data { combined.append(data) }
            guard combined.count <= 4 * 1024 * 1024 else {
                self.respond(client, status: "502 Bad Gateway", body: Data()); upstream.cancel(); return
            }
            if complete || error != nil {
                client.send(content: combined, completion: .contentProcessed { [weak self] _ in
                    self?.finish(client)
                    client.cancel()
                    upstream.cancel()
                })
            } else {
                self.readResponse(upstream, client: client, buffer: combined)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data) {
        let header = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        var response = header
        response.append(body)
        if case .setup = connection.state { connection.start(queue: queue) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
            connection.cancel()
        })
    }
}
