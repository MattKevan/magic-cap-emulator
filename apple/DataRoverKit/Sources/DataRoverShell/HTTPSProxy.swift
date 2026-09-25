import Foundation
import Network
import Darwin

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
        guard !url.isFileURL, !isForbiddenHost(host), resolvesOnlyPublicAddresses(host) else { return nil }
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

    private static func isForbiddenHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") { return true }
        let pieces = lower.split(separator: ".").compactMap { UInt8($0) }
        if pieces.count == 4 {
            let b = pieces
            return b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 169 && b[1] == 254)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 192 && b[1] == 0)
                || (b[0] == 198 && (18...19).contains(b[1])) || (b[0] == 240)
        }
        // Literal IPv6 is not needed by the legacy browser proxy. Reject all
        // IPv6 literals rather than risk accepting an unusual local range.
        if lower.contains(":") { return true }
        return false
    }

    private static func resolvesOnlyPublicAddresses(_ host: String) -> Bool {
        // Reject alternate integer/hex encodings of IPv4 addresses before DNS.
        if host.range(of: #"^[0-9a-fA-FxX.]+$"#, options: .regularExpression) != nil,
           host.contains(where: { $0.isNumber }) { return false }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        let resolution = host.withCString { getaddrinfo($0, nil, &hints, &head) }
        guard resolution == 0, let first = head else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let item = current {
            let entry = item.pointee
            if let address = entry.ai_addr {
                if entry.ai_family == AF_INET {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    let octets = withUnsafeBytes(of: ipv4) { Array($0) }
                    if octets.count == 4 {
                        found = true
                        let ip = octets.map(Int.init)
                        if ip[0] == 0 || ip[0] == 10 || ip[0] == 127 || ip[0] >= 224
                            || (ip[0] == 169 && ip[1] == 254) || (ip[0] == 172 && (16...31).contains(ip[1]))
                            || (ip[0] == 192 && (ip[1] == 168 || ip[1] == 0))
                            || (ip[0] == 100 && (64...127).contains(ip[1]))
                            || (ip[0] == 198 && (18...19).contains(ip[1])) || ip[0] == 240 { return false }
                    }
                } else if entry.ai_family == AF_INET6 {
                    let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                    if bytes.count == 16 {
                        found = true
                        let unspecified = bytes.allSatisfy { $0 == 0 }
                        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                        let mappedV4 = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                        if unspecified || loopback || bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc
                            || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || mappedV4 { return false }
                    }
                }
            }
            current = entry.ai_next
        }
        return found
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
