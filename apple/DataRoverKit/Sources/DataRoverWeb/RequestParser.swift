import Foundation

/// Parses one HTTP/1.0 request from the guest browser.
public enum RequestParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 2 * 1024 * 1024

    public enum Outcome: Equatable {
        case complete(ProxyRequest)
        case incomplete
        case invalid(status: Int)
    }

    private static let hopByHop: Set<String> = [
        "host", "connection", "proxy-connection", "keep-alive", "proxy-authorization",
        "te", "trailer", "upgrade", "accept-encoding",
    ]

    public static func parse(_ data: Data) -> Outcome {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(status: 431) }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else {
            return .invalid(status: 400)
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        let method = parts[0].uppercased()
        guard ["GET", "HEAD", "POST"].contains(method) else { return .invalid(status: 405) }

        var headers: [HTTPHeader] = []
        var hostHeader: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400) }
            let lower = name.lowercased()
            if lower == "transfer-encoding" { return .invalid(status: 400) }
            if lower == "host" { hostHeader = value; continue }
            if lower == "content-length" {
                guard let length = Int(value), length >= 0 else { return .invalid(status: 400) }
                guard length <= maxBodyBytes else { return .invalid(status: 413) }
                contentLength = length
            }
            if hopByHop.contains(lower) || lower.hasPrefix("proxy-") { continue }
            headers.append(HTTPHeader(name: name, value: value))
        }

        var target = parts[1]
        var host = hostHeader
        if let absolute = URL(string: target), let scheme = absolute.scheme?.lowercased(),
           scheme == "http", let authority = absolute.host {
            host = absolute.port.map { "\(authority):\($0)" } ?? authority
            let path = absolute.path.isEmpty ? "/" : absolute.path
            target = path + (absolute.query.map { "?\($0)" } ?? "")
        }
        guard target.hasPrefix("/"), let rawHost = host, let normalized = normalizeHost(rawHost) else {
            return .invalid(status: 400)
        }

        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        if available < contentLength { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let (cleanTarget, reader) = removeReaderFlag(target)
        return .complete(ProxyRequest(method: method, host: normalized, target: cleanTarget,
                                      headers: headers, body: body, reader: reader))
    }

    static func normalizeHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        var port: String?
        if let colon = host.lastIndex(of: ":"), !host.contains("]") {
            port = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            return nil
        }
        guard let port, port != "80" else { return host }
        guard let number = Int(port), (1...65_535).contains(number) else { return nil }
        return "\(host):\(number)"
    }

    static func removeReaderFlag(_ target: String) -> (String, Bool) {
        guard let question = target.firstIndex(of: "?") else { return (target, false) }
        let path = String(target[..<question])
        let items = target[target.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false)
        let kept = items.filter { $0 != "mcreader=1" }
        let reader = kept.count != items.count
        return (kept.isEmpty ? path : path + "?" + kept.joined(separator: "&"), reader)
    }
}
