import Foundation

public struct HTTPHeader: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// One guest request, normalized for the upstream fetch.
public struct ProxyRequest: Equatable, Sendable {
    public var method: String
    public var host: String
    public var target: String
    public var headers: [HTTPHeader]
    public var body: Data
    public var reader: Bool

    public init(method: String, host: String, target: String, headers: [HTTPHeader] = [],
                body: Data = Data(), reader: Bool = false) {
        self.method = method; self.host = host; self.target = target
        self.headers = headers; self.body = body; self.reader = reader
    }
}

/// An HTTP/1.0 response for the guest browser.
public struct ProxyResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [HTTPHeader]
    public var body: Data

    public init(status: Int, reason: String, headers: [HTTPHeader], body: Data) {
        self.status = status; self.reason = reason; self.headers = headers; self.body = body
    }

    public func serialized(includeBody: Bool) -> Data {
        var head = "HTTP/1.0 \(status) \(reason)\r\n"
        for header in headers { head += "\(header.name): \(header.value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }
}

/// Fixed, ASCII-only status line reasons, shared by the pipeline and the
/// listener. `HTTPURLResponse.localizedString` is localized (and says "No
/// Error" for 200), so it can put non-ASCII text in an HTTP status line.
enum HTTPStatus {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 100..<200: return "Informational"
        case 200..<300: return "OK"
        case 300..<400: return "Redirect"
        case 400..<500: return "Client Error"
        default: return "Server Error"
        }
    }
}
